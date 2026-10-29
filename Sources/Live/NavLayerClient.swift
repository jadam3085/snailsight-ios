// SnailSight 12.18: Layer A on the Map, in Map ▸ 3D and in AR (live world build 2026-10-28 item 4; server
// livenav.py, API §6b.6; SnailSightCore NavLayer.swift).
//  - Layers ▸ Robot obstacles (off by default): while the AR map is drawn, the Map or Map ▸ 3D is open, poll
//    GET /v1/live/nav?map_id=<live map>&since=<rev> every 1.5 s (first call = every tile; then only changed ones).
//  - Each 4 m tile → an 80 × 80 picture of the robot body band (floor + 0.10 … 1.00 m): red = blocked, faint green =
//    seen free, clear = unknown (unknown is no-go for ground robots).
//  - AR: the picture lies flat 4 cm above that storey's floor (under MapARLayer.navNode, so it moves with the map).
//    Map: drawn under the live mesh on the shown storey. Map ▸ 3D: clones of the AR quads.
//  - A server without the layer (404) is retried every 60 s.
// Logs: nav_layer_first, nav_layer_stats (every 30 s while on), nav_layer_error.
import Combine
import CoreGraphics
import Foundation
import Metal
import RealityKit
import UIKit
import SnailSightCore

final class NavLayerClient: ObservableObject {
    struct Picture {
        let key: String
        let level: Int
        let square: [Double]
        let floorZ: Double
        let image: CGImage
        let blocked: Int
        let free: Int
    }

    private unowned let model: AppModel
    @Published private(set) var rev = 0
    private(set) var pictures: [String: Picture] = [:]
    private var state = LiveNavState()
    private var entities: [String: ModelEntity] = [:]
    private var timer: Timer?
    private var polling = false
    private var retryAt: TimeInterval = 0
    private var missing = false
    private var mapID: String?
    private var stats = (polls: 0, tiles: 0, bytes: 0, ms: 0.0)
    private var lastStats: TimeInterval = 0
    private var firstLogged = false

    static let everyS = 1.5

    init(model: AppModel) { self.model = model }

    private var now: TimeInterval { Date().timeIntervalSince1970 }
    private var layer: MapARLayer { model.controller.mapLayer }

    /// Someone looks: AR with the map drawn, the Map or Map ▸ 3D.
    var wanted: Bool {
        model.showNav && model.serverBase != nil && !model.showScans
            && (model.showMap || model.showMap3D || layer.isAligned)
    }

    var summary: String {
        guard model.showNav else { return "Off: what the robots plan around (live nav layer)" }
        if missing { return "This map server has no live nav layer yet" }
        let b = pictures.values.reduce(0) { $0 + $1.blocked }
        return state.summary(now: now, blocked: b)
    }

    /// Start the 1.5 s timer (idempotent; AppModel calls it at launch).
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.everyS, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        layer.navNode.isEnabled = model.showNav && model.worldOn
        if model.liveMapID != mapID {                               // another live map: start over
            mapID = model.liveMapID
            clearAll()
        }
        guard wanted, !polling, now >= retryAt, let link = model.link else { return }
        polling = true
        let since = state.rev ?? 0
        let map = model.liveMapID
        let t0 = now
        Task { [weak self] in
            var doc: LiveNavDoc?
            var status = 0
            var bytes = 0
            var err: String?
            do {
                let (d, s) = try await link.request("GET", "/v1/live/nav",
                                                    query: [URLQueryItem(name: "map_id", value: map),
                                                            URLQueryItem(name: "since", value: String(since))],
                                                    timeout: 20)
                status = s
                bytes = d.count
                if s == 200 {
                    doc = await Task.detached(priority: .utility) { try? JSONDecoder().decode(LiveNavDoc.self, from: d) }.value
                    if doc == nil { err = "parse" }
                } else { err = "HTTP \(s)" }
            } catch { err = error.localizedDescription }
            let docF = doc, statusF = status, bytesF = bytes, errF = err
            let built: [Picture] = await Task.detached(priority: .utility) { () -> [Picture] in
                (docF?.tiles ?? []).compactMap(Self.picture)
            }.value
            await MainActor.run {
                guard let self else { return }
                self.polling = false
                self.stats.polls += 1
                self.stats.bytes += bytesF
                self.stats.ms += (self.now - t0) * 1000
                guard let d = docF else {
                    self.missing = statusF == 404
                    self.retryAt = self.now + (statusF == 404 ? 60 : 10)
                    self.model.log.event("nav_layer_error", ["status": .int(statusF), "error": .string(errF ?? "?")])
                    return
                }
                self.missing = false
                if let r = d.rev, let mine = self.state.rev, r < mine {     // the live unit restarted: start over
                    self.clearAll()
                    return
                }
                let changed = Set(self.state.apply(d, now: self.now))
                for p in built where changed.contains(p.key) { self.show(p) }
                if !changed.isEmpty {
                    self.stats.tiles += changed.count
                    self.rev &+= 1
                    if !self.firstLogged {
                        self.firstLogged = true
                        self.model.log.event("nav_layer_first", ["tiles": .int(changed.count), "rev": .int(d.rev ?? -1),
                                                                 "bytes": .int(bytesF)])
                    }
                }
                self.maybeLog()
            }
        }
    }

    private func clearAll() {
        state.reset()
        pictures.removeAll()
        for e in entities.values { e.removeFromParent() }
        entities.removeAll()
        rev &+= 1
    }

    private static func picture(_ t: LiveNavTile) -> Picture? {
        let cls = NavBand.classes(t)
        let px = NavBand.rgba(cls, n: t.nc)
        guard let img = rgbaImage(px, n: t.nc) else { return nil }
        let c = NavBand.counts(cls)
        return Picture(key: t.key, level: t.level, square: t.square, floorZ: t.floorZ, image: img, blocked: c.blocked, free: c.free)
    }

    private static func rgbaImage(_ px: [UInt8], n: Int) -> CGImage? {
        guard n > 0, px.count == n * n * 4, let prov = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static let nearest: MaterialParameters.Texture.Sampler = {
        let d = MTLSamplerDescriptor()
        d.minFilter = .nearest
        d.magFilter = .nearest
        d.mipFilter = .notMipmapped
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        return MaterialParameters.Texture.Sampler(d)
    }()

    /// The AR quad of one tile (map frame: XY plane, facing up), replaced in place.
    private func show(_ p: Picture) {
        pictures[p.key] = p
        guard let tex = try? TextureResource.generate(from: p.image, options: .init(semantic: .color, mipmapsMode: .none)) else { return }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(tex, sampler: Self.nearest))
        m.blending = .transparent(opacity: 0.9)
        let s = Float(p.square[2] - p.square[0])
        if let e = entities[p.key] {
            e.model?.materials = [m]
            return
        }
        let e = ModelEntity(mesh: .generatePlane(width: s, height: s), materials: [m])
        e.name = "nav.\(p.key)"
        e.position = SIMD3<Float>(Float((p.square[0] + p.square[2]) / 2), Float((p.square[1] + p.square[3]) / 2),
                                  Float(p.floorZ + 0.04))
        layer.navNode.addChild(e)
        entities[p.key] = e
    }

    private func maybeLog() {
        guard now - lastStats >= 30 else { return }
        lastStats = now
        let b = pictures.values.reduce(0) { $0 + $1.blocked }, f = pictures.values.reduce(0) { $0 + $1.free }
        model.log.event("nav_layer_stats", ["polls": .int(stats.polls), "tiles_changed": .int(stats.tiles),
                                            "bytes": .int(stats.bytes),
                                            "ms_mean": .double(stats.polls > 0 ? (stats.ms / Double(stats.polls)).rounded() : -1),
                                            "held": .int(pictures.count), "blocked_cells": .int(b), "free_cells": .int(f),
                                            "rev": .int(state.rev ?? -1)])
        stats = (0, 0, 0, 0)
    }
}
