import Foundation

// SnailSight 12.26: a small, pure-Swift zlib (RFC 1950) / raw deflate (RFC 1951) decoder for the ssq1 Layer B wire
// (WireQ.swift). Pure so the Linux CI runs it; frames are small (a 4 m tile's block table + block meshes, tens of kB),
// so a table-driven decoder is fast enough on the phone. No compression side (the app never sends zlib).

public enum Inflate {
    public enum Failure: Error, Equatable { case header, truncated, badBlock, badCode, badDistance, checksum }

    /// zlib stream (2-byte header, deflate, Adler-32 trailer) → bytes. The checksum is verified when present.
    public static func zlib(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 2 else { throw Failure.header }
        let cmf = b[0], flg = b[1]
        guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0, flg & 0x20 == 0 else { throw Failure.header }
        var r = BitReader(b, offset: 2)
        let out = try inflate(&r)
        let end = r.byteAligned()
        if end + 4 <= b.count {
            let want = UInt32(b[end]) << 24 | UInt32(b[end + 1]) << 16 | UInt32(b[end + 2]) << 8 | UInt32(b[end + 3])
            guard adler32(out) == want else { throw Failure.checksum }
        }
        return Data(out)
    }

    /// Raw deflate (no header) → bytes.
    public static func raw(_ data: Data) throws -> Data {
        var r = BitReader([UInt8](data), offset: 0)
        return Data(try inflate(&r))
    }

    public static func adler32(_ b: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, s: UInt32 = 0
        var i = 0
        while i < b.count {
            let n = min(5552, b.count - i)
            for j in i..<(i + n) { a &+= UInt32(b[j]); s &+= a }
            a %= 65521; s %= 65521
            i += n
        }
        return s << 16 | a
    }

    // MARK: - decoder

    struct BitReader {
        let b: [UInt8]
        var pos: Int
        var bit: UInt32 = 0
        var nbits = 0
        init(_ b: [UInt8], offset: Int) { self.b = b; self.pos = offset }

        @inline(__always) mutating func need(_ n: Int) throws {
            while nbits < n {
                guard pos < b.count else { throw Failure.truncated }
                bit |= UInt32(b[pos]) << UInt32(nbits)
                pos += 1
                nbits += 8
            }
        }
        @inline(__always) mutating func bits(_ n: Int) throws -> Int {
            if n == 0 { return 0 }
            try need(n)
            let v = Int(bit & ((1 << UInt32(n)) - 1))
            bit >>= UInt32(n)
            nbits -= n
            return v
        }
        /// Drop to a byte boundary; returns the byte offset of the next unread byte.
        mutating func byteAligned() -> Int {
            let drop = nbits % 8
            bit >>= UInt32(drop)
            nbits -= drop
            pos -= nbits / 8                 // whole bytes still buffered go back
            bit = 0
            nbits = 0
            return pos
        }
    }

    /// Canonical Huffman table: counts per length + symbols sorted by code.
    struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]
        init(lengths: [Int]) throws {
            symbol = [Int](repeating: 0, count: lengths.count)
            for l in lengths { count[l] += 1 }
            count[0] = 0
            var left = 1
            for len in 1..<16 {
                left <<= 1
                left -= count[len]
                guard left >= 0 else { throw Failure.badCode }     // over-subscribed
            }
            var offs = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offs[len + 1] = offs[len] + count[len] }
            for (s, l) in lengths.enumerated() where l != 0 { symbol[offs[l]] = s; offs[l] += 1 }
        }
        @inline(__always) func decode(_ r: inout BitReader) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try r.bits(1)
                let c = count[len]
                if code - c < first { return symbol[index + (code - first)] }
                index += c
                first += c
                first <<= 1
                code <<= 1
            }
            throw Failure.badCode
        }
    }

    static let lbase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
                        163, 195, 227, 258]
    static let lext = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let dbase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049,
                        3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let dext = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let fixed: (Huffman, Huffman) = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        // swiftlint:disable:next force_try
        return (try! Huffman(lengths: l), try! Huffman(lengths: [Int](repeating: 5, count: 30)))
    }()
    static let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static func inflate(_ r: inout BitReader) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(r.b.count * 4)
        var last = 0
        repeat {
            last = try r.bits(1)
            switch try r.bits(2) {
            case 0:
                let p = r.byteAligned()
                guard p + 4 <= r.b.count else { throw Failure.truncated }
                let len = Int(r.b[p]) | Int(r.b[p + 1]) << 8
                let nlen = Int(r.b[p + 2]) | Int(r.b[p + 3]) << 8
                guard len == (~nlen & 0xFFFF), p + 4 + len <= r.b.count else { throw Failure.badBlock }
                out.append(contentsOf: r.b[(p + 4)..<(p + 4 + len)])
                r.pos = p + 4 + len
            case 1:
                try codes(&r, &out, fixed.0, fixed.1)
            case 2:
                let nlen = try r.bits(5) + 257, ndist = try r.bits(5) + 1, ncode = try r.bits(4) + 4
                guard nlen <= 286, ndist <= 30 else { throw Failure.badBlock }
                var cl = [Int](repeating: 0, count: 19)
                for i in 0..<ncode { cl[order[i]] = try r.bits(3) }
                let ch = try Huffman(lengths: cl)
                var lengths = [Int]()
                lengths.reserveCapacity(nlen + ndist)
                while lengths.count < nlen + ndist {
                    let sym = try ch.decode(&r)
                    if sym < 16 { lengths.append(sym); continue }
                    var rep = 0, val = 0
                    if sym == 16 {
                        guard let p = lengths.last else { throw Failure.badBlock }
                        val = p; rep = 3 + (try r.bits(2))
                    } else if sym == 17 { rep = 3 + (try r.bits(3)) } else { rep = 11 + (try r.bits(7)) }
                    guard lengths.count + rep <= nlen + ndist else { throw Failure.badBlock }
                    lengths += [Int](repeating: val, count: rep)
                }
                guard lengths[256] != 0 else { throw Failure.badBlock }
                try codes(&r, &out, try Huffman(lengths: Array(lengths[0..<nlen])),
                          try Huffman(lengths: Array(lengths[nlen...])))
            default:
                throw Failure.badBlock
            }
        } while last == 0
        return out
    }

    static func codes(_ r: inout BitReader, _ out: inout [UInt8], _ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let sym = try lit.decode(&r)
            if sym < 256 { out.append(UInt8(sym)); continue }
            if sym == 256 { return }
            let s = sym - 257
            guard s < 29 else { throw Failure.badCode }
            let len = lbase[s] + (try r.bits(lext[s]))
            let ds = try dist.decode(&r)
            guard ds < 30 else { throw Failure.badDistance }
            let d = dbase[ds] + (try r.bits(dext[ds]))
            guard d <= out.count else { throw Failure.badDistance }
            let start = out.count - d
            for i in 0..<len { out.append(out[start + i]) }
        }
    }
}
