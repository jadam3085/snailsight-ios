import Foundation

// SnailSight 12.26: the quantised + predictive Layer B transport `ssq1+zlib` (server wireq.py, live 0.14+, API §6b.7;
// requirement docs/SNAILSIGHT-APP-SURFACE-REQUIREMENT-2026-11-13.md R4). Asked for with `"surface_enc": "ssq1"` in the
// subscribe (and `enc=ssq1` on REST refetches) when GET /v1 lists `live_surface_ssq1`; ~7x less downlink than f32 json.
// A json frame carries `enc: "ssq1+zlib"`, `bt` = base64 zlib(JSON of the old `blocks` list) and `q` = base64 zlib(all
// block meshes), `q_m` (1 mm) and `cq` (colour bin). Decoded positions / colours equal the f32 frames' 1 mm / colour-bin
// values exactly. Port of wireq.unpack / portal xr/layerb.js unpackQ. Pure (Linux-tested, WireQTests).

public enum WireQ {
    public static let enc = "ssq1+zlib"
    public static let name = "ssq1"

    public struct Record: Equatable {
        public var mesh: FlatMesh
        public var rgb: [UInt8]?
    }

    public enum Failure: Error, Equatable { case truncated, records, reference }

    /// The `bt` blob (zlib JSON) → the `blocks` list as raw JSON objects.
    public static func table(_ bt: Data) throws -> [[String: Any]] {
        let raw = try Inflate.zlib(bt)
        guard let a = try JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else { throw Failure.records }
        return a
    }

    /// The `q` blob (zlib) + the origins (metres, `b * block_m`) of the blocks with `nv > 0` in `blocks` order →
    /// one mesh per such block (map frame), colour when the record has it.
    public static func unpack(_ q: Data, origins: [[Double]], qm: Double = 0.001, cq: Int = 4) throws -> [Record] {
        let raw = [UInt8](try Inflate.zlib(q))
        var i = 0
        func rd() throws -> Int {
            var x = 0, s = 0
            while true {
                guard i < raw.count else { throw Failure.truncated }
                let c = Int(raw[i]); i += 1
                x |= (c & 0x7F) << s
                if c < 0x80 { return x }
                s += 7
                if s > 56 { throw Failure.truncated }
            }
        }
        @inline(__always) func unzz(_ x: Int) -> Int { (x >> 1) ^ -(x & 1) }
        let n = try rd()
        guard n >= 0, n <= origins.count else { throw Failure.records }
        var hdr: [(nv: Int, nq: Int, nr: Int, fl: Int)] = []
        for _ in 0..<n { hdr.append((try rd(), try rd(), try rd(), try rd())) }
        var codes: [[Int]] = []
        for h in hdr {
            var a = [Int](repeating: 0, count: 4 * h.nq + 3 * h.nr)
            for j in 0..<a.count { a[j] = try rd() }
            codes.append(a)
        }
        struct Dec { var U: [Int]; var nb: [Int]; var idx: [UInt32]; var nv: Int; var fl: Int; var o: [Double] }
        var decs: [Dec] = []
        for (r, h) in hdr.enumerated() {
            let cd = codes[r]
            var U = [Int](repeating: 0, count: h.nv * 3), nb = [Int](repeating: -1, count: h.nv * 3)
            var idx = [UInt32]()
            idx.reserveCapacity(6 * h.nq + 3 * h.nr)
            var cnt = 0, ci = 0, l0 = 0, l1 = 0, l2 = 0
            for qi in 0..<(h.nq + h.nr) {
                let isq = qi < h.nq, kn = isq ? 4 : 3
                var slots = [-1, -1, -1, -1]
                for k in 0..<kn {
                    let code = cd[ci]; ci += 1
                    if code != 0 {
                        let v = cnt - code
                        guard v >= 0, v < cnt else { throw Failure.reference }
                        slots[k] = v
                        continue
                    }
                    guard cnt < h.nv else { throw Failure.records }
                    var p0 = l0, p1 = l1, p2 = l2
                    if isq {
                        func corner(_ j: Int) -> Int {
                            if j < k { return slots[j] }
                            let cj = cd[ci - 1 + (j - k)]
                            if cj == 0 { return -1 }
                            var nz = 1
                            var t = k + 1
                            while t < j { if cd[ci - 1 + (t - k)] == 0 { nz += 1 }; t += 1 }
                            let v = cnt + nz - cj
                            return v >= 0 && v < cnt ? v : -1
                        }
                        let a = corner((k + 1) % 4), b = corner((k + 2) % 4), d = corner((k + 3) % 4)
                        if a >= 0 && b >= 0 && d >= 0 {
                            p0 = U[a * 3] + U[d * 3] - U[b * 3]
                            p1 = U[a * 3 + 1] + U[d * 3 + 1] - U[b * 3 + 1]
                            p2 = U[a * 3 + 2] + U[d * 3 + 2] - U[b * 3 + 2]
                        } else if d >= 0 {
                            p0 = U[d * 3]; p1 = U[d * 3 + 1]; p2 = U[d * 3 + 2]
                        } else if a >= 0 {
                            p0 = U[a * 3]; p1 = U[a * 3 + 1]; p2 = U[a * 3 + 2]
                        }
                        nb[cnt * 3] = a; nb[cnt * 3 + 1] = b; nb[cnt * 3 + 2] = d
                    }
                    U[cnt * 3] = p0 + unzz(try rd())
                    U[cnt * 3 + 1] = p1 + unzz(try rd())
                    U[cnt * 3 + 2] = p2 + unzz(try rd())
                    l0 = U[cnt * 3]; l1 = U[cnt * 3 + 1]; l2 = U[cnt * 3 + 2]
                    slots[k] = cnt
                    cnt += 1
                }
                if isq {
                    idx += [slots[0], slots[1], slots[2], slots[0], slots[2], slots[3]].map { UInt32($0) }
                } else {
                    idx += [slots[0], slots[1], slots[2]].map { UInt32($0) }
                }
            }
            guard cnt == h.nv else { throw Failure.records }
            decs.append(Dec(U: U, nb: nb, idx: idx, nv: h.nv, fl: h.fl, o: origins[r]))
        }
        var out: [Record] = []
        for d in decs {
            var pos = [Float](repeating: 0, count: d.nv * 3)
            for v in 0..<d.nv {
                for c in 0..<3 { pos[v * 3 + c] = Float(d.o[c] + Double(d.U[v * 3 + c]) * qm) }
            }
            var rgb: [UInt8]?
            if d.fl & 1 == 1 {
                guard i + 3 * d.nv <= raw.count else { throw Failure.truncated }
                let base = i
                i += 3 * d.nv
                var C = [Int](repeating: 0, count: d.nv * 3)
                var last = (0, 0, 0)
                for v in 0..<d.nv {
                    var s0 = 0, s1 = 0, s2 = 0, ns = 0
                    for t in 0..<3 {
                        let y = d.nb[v * 3 + t]
                        if y >= 0 && y < v { s0 += C[y * 3]; s1 += C[y * 3 + 1]; s2 += C[y * 3 + 2]; ns += 1 }
                    }
                    let pr: (Int, Int, Int) = ns > 0 ? ((s0 + ns / 2) / ns, (s1 + ns / 2) / ns, (s2 + ns / 2) / ns) : last
                    C[v * 3] = (pr.0 + Int(raw[base + v])) & 255
                    C[v * 3 + 1] = (pr.1 + Int(raw[base + d.nv + v])) & 255
                    C[v * 3 + 2] = (pr.2 + Int(raw[base + 2 * d.nv + v])) & 255
                    last = (C[v * 3], C[v * 3 + 1], C[v * 3 + 2])
                }
                rgb = C.map { UInt8(min($0 * cq + cq / 2, 255)) }
            }
            out.append(Record(mesh: FlatMesh(positions: pos, indices: d.idx), rgb: rgb))
        }
        return out
    }
}
