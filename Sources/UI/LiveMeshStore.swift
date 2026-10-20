// SnailSight 12.0 "Mesh (live)": the ONE place the mesh-as-it-is-built lives for the UI. LiveMapClient feeds it every
// accepted live tile (this phone's walk and every other agent's), TileStreamer every base tile the M4 sync swapped in
// place. AR draws the tiles itself (LiveMapClient, fresh highlight); the Map reads the top-down rasters from here.
// Publishes at most 4 times a second (a burst of tiles is one SwiftUI update).
import Foundation
import UIKit
import SnailSightCore

final class LiveMeshStore: ObservableObject {
    struct Raster {
        let key: String
        let square: [Double]
        let level: Int
        let image: CGImage?
        let photo: CGImage?                                // 12.1: the same plan in the tile's photo colours
    }

    @Published private(set) var rev = 0
    private(set) var feed = LiveMeshFeed()
    private(set) var rasters: [String: Raster] = [:]       // live tile key → top-down image
    private var publishPending = false

    var now: Double { Date().timeIntervalSince1970 }

    /// A live mesh tile accepted + drawn in AR. Rasterised here (≤ ~1000 triangles a tile after server decimation).
    @discardableResult
    func applyLive(_ h: LiveTileHeader, mesh: FlatMesh, rgb: [UInt8]? = nil, floorZ: Double?, me: String) -> LiveMeshFeed.Applied {
        let a = feed.apply(h, triangles: mesh.triangleCount, floorZ: floorZ, me: me, now: now)
        if let sq = h.square {
            let r = TilePlanRaster.raster(mesh, square: sq, floorZ: floorZ)
            var photo: CGImage?
            if let rgb {
                let px = TilePlanRaster.rasterRGBA(mesh, faceRGB: LiveMeshTile.faceColours(mesh, rgb: rgb), square: sq,
                                                   floorZ: floorZ, n: 40)
                photo = Self.flipRows(px, n: 40).flatMap { Self.rgbaImage($0, w: 40, h: 40) }
            }
            rasters[h.key] = Raster(key: h.key, square: sq, level: h.levelIndex, image: Self.image(r, n: 40), photo: photo)
        }
        schedulePublish()
        return a
    }

    func noteBase(key: String, square: [Double]?, level: Int, box: [Double]) {
        feed.noteBase(key: key, square: square, level: level, now: now)
        schedulePublish()
    }

    func step(key: String, source: LiveMeshTileInfo.Source = .live) -> Int { feed.step(key: key, source: source, now: now) }

    func summary(me: String) -> String { feed.summary(now: now, me: me) }

    private func schedulePublish() {
        guard !publishPending else { return }
        publishPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.publishPending = false
            self.rev &+= 1
        }
    }

    /// Floor = light, raised = mid, wall = dark (the A2 plan palette), empty = transparent. Row 0 of the raster = min y,
    /// image row 0 = top = max y.
    static func image(_ r: [UInt8], n: Int) -> CGImage? {
        guard r.count == n * n else { return nil }
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for j in 0..<n {
            for i in 0..<n {
                let v = r[j * n + i]
                guard v != 0 else { continue }
                let o = ((n - 1 - j) * n + i) * 4
                let (c, a): (UInt8, UInt8) = v == TilePlanRaster.wall ? (40, 255) : v == TilePlanRaster.raised ? (120, 230) : (205, 200)
                px[o] = c; px[o + 1] = c; px[o + 2] = c; px[o + 3] = a
            }
        }
        return rgbaImage(px, w: n, h: n)
    }

    /// Raster row 0 = min y -> image row 0 = top = max y.
    static func flipRows(_ px: [UInt8], n: Int) -> [UInt8]? {
        guard px.count == n * n * 4 else { return nil }
        var out = [UInt8](repeating: 0, count: px.count)
        for j in 0..<n {
            let src = j * n * 4, dst = (n - 1 - j) * n * 4
            out[dst..<(dst + n * 4)] = px[src..<(src + n * 4)]
        }
        return out
    }

    static func rgbaImage(_ px: [UInt8], w: Int, h: Int) -> CGImage? {
        guard w > 0, h > 0, px.count == w * h * 4 else { return nil }
        let data = Data(px) as CFData
        guard let prov = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
