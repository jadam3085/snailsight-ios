// SnailSight 12.0 selection (concept B2) + agent ops (concept O2) + the layers button (B1's rail as a compact sheet).
// - CommandRingOverlay: tap a body → a ring of its commands around it on screen (Drive, Go to, Follow, Flee, Stay, Stop, Roam,
//   Delete — whatever that body offers, SnailSightCore.RingCommand), 52 pt buttons kept on screen. The details card
//   below stays the full command bar (every command, scale, extras), so the ring only adds reach; drag-to-trash and
//   Spawn mode are unchanged.
// - AgentOpsPanel: a selected sim drone / rover: obstacle-takeover banner, route length + the layer it is on
//   (surveyed / estimated), the altitude / canopy strip, Hold · Climb above · Return · Land now (disabled with the
//   reason where the map server cannot do it yet; API §5.16 `drone_missions` turns them on).
// - LayersSheet: Mesh (live) · Structure · X-ray · Objects · Terrain · Cameras · Paths · Other agents.
import SwiftUI
import RealityKit
import simd
import SnailSightCore

struct CommandRingOverlay: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var server: ServerSimUI
    @ObservedObject var local: SimUI
    /// 12.3 Map ▸ 3D: projects a map-frame point into the 3D viewer (nil = the AR view, the default).
    var projector: (([Double]) -> CGPoint?)? = nil

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
                if let ring = ring(size: geo.size) {
                    ZStack {
                        Circle().stroke(Color.cyan.opacity(0.55), lineWidth: 2)
                            .frame(width: CGFloat(CommandRing.radius * 2), height: CGFloat(CommandRing.radius * 2))
                            .position(x: CGFloat(ring.center.x), y: CGFloat(ring.center.y))
                            .allowsHitTesting(false)
                        ForEach(Array(ring.commands.enumerated()), id: \.offset) { i, c in
                            Button { run(c, offered: ring.offered) } label: {
                                VStack(spacing: 1) {
                                    Image(systemName: c.symbol).font(.system(size: 17, weight: .semibold))
                                    Text(c.title).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                                }
                                .frame(width: CGFloat(CommandRing.buttonSize), height: CGFloat(CommandRing.buttonSize))
                                .foregroundStyle(c == .delete ? Color.white : Color.primary)
                                .background(c == .delete ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.regularMaterial),
                                            in: Circle())
                                .overlay(Circle().stroke(Color.cyan.opacity(0.5)))
                            }
                            .buttonStyle(.plain)
                            .position(x: CGFloat(ring.points[i].x), y: CGFloat(ring.points[i].y))
                            .accessibilityLabel("\(c.title) \(ring.title)")
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
    }

    private struct Ring {
        var title: String
        var center: V2
        var points: [V2]
        var commands: [RingCommand]
        var offered: [SimCommand]
        var serverMode: Bool
    }

    private func ring(size: CGSize) -> Ring? {
        if let projector { return ring3D(size: size, projector: projector) }
        guard !model.recording, model.sheetDetent == .collapsed, !model.showMap, !model.spawnMode else { return nil }
        let layer = model.controller.mapLayer
        var world: SIMD3<Float>?
        var offered: [SimCommand] = []
        var title = ""
        var serverMode = false
        if server.active, let s = server.selection, server.pending == nil, !server.droneAssistPending {
            guard let p = model.serverSim.selectedPose else { return nil }
            world = layer.toWorld(map: [p[0], p[1], p[2] + 0.15])
            offered = SimCommand.offered(role: s.role, drone: s.drone, server: true, drivable: s.drivable)
            title = s.title
            serverMode = true
        } else if !server.active, let s = local.selection, local.pending == nil {
            world = model.controller.sim.selectedWorld
            offered = SimCommand.offered(role: s.kind.role, server: false)
            title = s.title
        }
        guard let w = world, let pt = model.controller.arView.project(w) else { return nil }
        // behind the camera: project() still returns a point; skip it
        let cam = layer.camWorld, fw = layer.camForwardWorld
        guard simd_dot(w - cam, fw) > 0.1 else { return nil }
        let cmds = RingCommand.ring(offered: offered)
        guard !cmds.isEmpty else { return nil }
        let bottomReserve = SheetDetent.collapsed.height(container: 800) + 210.0                   // the collapsed sheet + the details card above it
        let l = CommandRing.layout(center: V2(Double(pt.x), Double(pt.y)), count: cmds.count,
                                   bounds: [0, 110, Double(size.width), max(240, Double(size.height) - bottomReserve)])
        return Ring(title: title, center: l.center, points: l.points, commands: cmds, offered: offered, serverMode: serverMode)
    }

    /// The ring in the 3D map viewer: the same commands, around the body as the 3D camera sees it.
    private func ring3D(size: CGSize, projector: ([Double]) -> CGPoint?) -> Ring? {
        var at: [Double]?
        var offered: [SimCommand] = []
        var title = ""
        var serverMode = false
        if server.active, let s = server.selection, server.pending == nil, !server.droneAssistPending,
           let p = model.serverSim.selectedPose {
            at = [p[0], p[1], p[2] + 0.15]
            offered = SimCommand.offered(role: s.role, drone: s.drone, server: true, drivable: s.drivable)
            title = s.title
            serverMode = true
        } else if !server.active, let s = local.selection, local.pending == nil, let w = model.controller.sim.selectedWorld {
            at = model.controller.mapLayer.toMap(world: w)
            offered = SimCommand.offered(role: s.kind.role, server: false)
            title = s.title
        }
        guard let m = at, let pt = projector(m) else { return nil }
        let cmds = RingCommand.ring(offered: offered)
        guard !cmds.isEmpty else { return nil }
        let l = CommandRing.layout(center: V2(Double(pt.x), Double(pt.y)), count: cmds.count,
                                   bounds: [0, 110, Double(size.width), max(240, Double(size.height) - 230)])
        return Ring(title: title, center: l.center, points: l.points, commands: cmds, offered: offered, serverMode: serverMode)
    }

    private func run(_ r: RingCommand, offered: [SimCommand]) {
        let c = RingCommand.command(r, offered: offered)
        model.log.event("ring_cmd", ["cmd": .string(c.rawValue), "server": .bool(server.active)])
        if c == .drive { model.openDrive(); return }
        if server.active { model.serverSim.command(c) } else { model.controller.sim.command(c) }
    }
}

// MARK: - O2 agent ops

struct AgentOpsPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ui: ServerSimUI

    var body: some View {
        if ui.active, let s = ui.selection, s.rover || s.drone {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                content(s, now: ctx.date.timeIntervalSince1970)
            }
        }
    }

    @ViewBuilder private func content(_ s: ServerSimSelection, now t: Double) -> some View {
        let sim = model.serverSim
        let features = model.serverFeatures.list
        let home = sim.selectedHome
        let route = sim.selectedRoute ?? []
        VStack(alignment: .leading, spacing: 6) {
            if let b = sim.opsBanner(now: t), b.visible(now: t) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.black)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.title).font(.caption.weight(.bold))
                        Text(b.detail).font(.caption2).lineLimit(2)
                    }
                    .foregroundStyle(.black)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(Color.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 8) {
                Image(systemName: s.drone ? "airplane" : "car.side").foregroundStyle(.cyan)
                Text(s.title).font(.caption.weight(.bold)).lineLimit(1)
                Text(routeText(route, pose: sim.selectedPose)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button { model.openMap(focus: sim.selectedPose) } label: { Image(systemName: "map").frame(width: 44, height: 32) }
                    .accessibilityLabel("Show the route on the map")
            }
            if let m = sim.selectedMission {
                Text(m.text + (m.reason.map { " · \($0)" } ?? "")).font(.caption2.weight(.semibold)).foregroundStyle(.cyan)
                    .lineLimit(2)
            }
            if s.drone { AltitudeStrip(samples: samples(route, pose: sim.selectedPose)).frame(height: 44) }
            HStack(spacing: 6) {
                ForEach(AgentOpsControl.offered(drone: s.drone), id: \.self) { c in
                    let a = c.availability(drone: s.drone, features: features, home: home, serverSim: true)
                    Button { model.serverSim.ops(c) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: c.symbol).font(.system(size: 16, weight: .semibold))
                            Text(c.title).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(c == .landNow ? Color.red.opacity(a.enabled ? 0.25 : 0.08) : Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!a.enabled)
                    .opacity(a.enabled ? 1 : 0.4)
                    .accessibilityLabel(c.title)
                    .accessibilityHint(a.reason ?? "")
                }
            }
            let reasons = AgentOpsControl.offered(drone: s.drone).compactMap { c -> String? in
                let a = c.availability(drone: s.drone, features: features, home: home, serverSim: true)
                return a.enabled ? nil : "\(c.title): \(a.reason ?? "not available")"
            }
            if let r = reasons.first {
                Text(reasons.count > 1 ? r + " (+\(reasons.count - 1) more)" : r).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: 440)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.cyan.opacity(0.35)))
    }

    /// "route 12.4 m · over estimated ground" / "no route · surveyed".
    private func routeText(_ route: [[Double]], pose: [Double]?) -> String {
        var parts: [String] = []
        let len = AltitudeProfile.length(route)
        parts.append(route.count >= 2 ? String(format: "route %.1f m", len) : "no route")
        if let p = pose, let g = model.planData.coverage?.grid {
            switch g.cls(x: p[0], y: p[1]) {
            case .surveyed: parts.append("surveyed")
            case .estimated: parts.append("estimated zone")
            case .unknown: parts.append("unknown ground")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func samples(_ route: [[Double]], pose: [Double]?) -> [AltitudeSample] {
        var r = route.map { Array($0.prefix(3)) }
        if let p = pose { r.insert(p, at: 0) }
        let data = model.planData
        let floor = (model.controller.mapLayer.cameraMap?[2] ?? 1.4) - 1.4
        return AltitudeProfile.sample(route: r, step: max(0.5, AltitudeProfile.length(r) / 60),
                                      ground: { x, y in data.groundZ(x: x, y: y) ?? floor },
                                      canopy: { x, y in data.canopyZ(x: x, y: y) })
    }
}

/// O2's altitude / canopy strip: ground (filled), canopy (estimated, dashed), the planned altitude (cyan).
struct AltitudeStrip: View {
    let samples: [AltitudeSample]

    var body: some View {
        Canvas { ctx, size in
            guard samples.count >= 1 else { return }
            let zs = samples.flatMap { [$0.body, $0.ground ?? $0.body, $0.canopy ?? $0.body] }
            let lo = (zs.min() ?? 0) - 0.5, hi = (zs.max() ?? 1) + 0.5
            let sMax = max(samples.last?.s ?? 1, 1)
            func pt(_ s: Double, _ z: Double) -> CGPoint {
                CGPoint(x: CGFloat(s / sMax) * size.width, y: size.height * CGFloat(1 - (z - lo) / max(hi - lo, 0.1)))
            }
            var ground = Path()
            ground.move(to: CGPoint(x: 0, y: size.height))
            for s in samples { ground.addLine(to: pt(s.s, s.ground ?? lo)) }
            ground.addLine(to: CGPoint(x: size.width, y: size.height))
            ctx.fill(ground, with: .color(Color(red: 0.42, green: 0.55, blue: 0.32).opacity(0.7)))
            var canopy = Path()
            var started = false
            for s in samples {
                guard let c = s.canopy else { started = false; continue }
                if started { canopy.addLine(to: pt(s.s, c)) } else { canopy.move(to: pt(s.s, c)); started = true }
            }
            ctx.stroke(canopy, with: .color(.green.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            var alt = Path()
            for (i, s) in samples.enumerated() { if i == 0 { alt.move(to: pt(s.s, s.body)) } else { alt.addLine(to: pt(s.s, s.body)) } }
            ctx.stroke(alt, with: .color(.cyan), lineWidth: 2)
        }
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            Text("ALTITUDE · CANOPY FROM LIDAR (ESTIMATE)").font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary).padding(3)
        }
        .accessibilityLabel(AltitudeProfile.minClearance(samples).map { String(format: "Lowest clearance %.1f metres", $0) }
                            ?? "Altitude profile")
    }
}

// MARK: - layers

struct LayersSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                List {
                    Section {
                        Toggle(isOn: model.worldBinding) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("3D world", systemImage: "cube.transparent.fill")
                                Text(model.worldOn ? "House, live mesh, terrain, objects and doors draw in AR"
                                                   : "Hidden: nothing of the generated world draws or downloads. Your layer settings are kept")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 44)
                    } footer: {
                        Text("One switch for all rendered world geometry. Sim bodies, paths, cameras and other agents have their own toggles.")
                    }
                    Section("View") {
                        Picker("View", selection: Binding(get: { model.viewPresets.preset }, set: { model.selectPreset($0) })) {
                            ForEach(ViewPreset.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(model.viewPresets.preset.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach(MapLayerKey.allCases, id: \.self) { k in
                            Toggle(isOn: binding(k)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Label(k.title, systemImage: k.symbol)
                                        if k == .meshLive && model.meshLive {
                                            Text("LIVE").font(.caption2.weight(.heavy)).padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Color.green.opacity(0.85), in: Capsule()).foregroundStyle(.black)
                                        }
                                    }
                                    Text(k == .meshLive ? model.meshStore.summary(me: model.agentID) : k.detail)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: 44)
                            if k == .structure {
                                Picker(selection: $model.houseStyle) {
                                    ForEach(HouseStyle.allCases) { Text($0.rawValue).tag($0) }
                                } label: { Label("House overlay", systemImage: "house") }
                                .frame(minHeight: 44)
                            }
                        }
                    } footer: {
                        Text("Layers show in AR and on the Map. Mesh (live) needs the house map to place you; turn on Live map to add your own walk to it. Any change here sets the view to Custom.")
                    }
                    Section {
                        Picker(selection: $model.meshColour) {
                            ForEach(MeshColour.allCases) { Text($0.rawValue).tag($0) }
                        } label: { Label("Mesh colour", systemImage: "paintpalette") }
                        .pickerStyle(.segmented)
                    } header: { Text("Mesh colour") } footer: {
                        Text("Photo paints the live mesh with the colours its walkers' cameras saw. Depth-only agents (Kinect, lidar) stay wireframe.")
                    }
                }
            }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func binding(_ k: MapLayerKey) -> Binding<Bool> {
        switch k {
        case .meshLive: return $model.meshLive
        case .structure: return Binding(get: { !model.rawScan }, set: { model.rawScan = !$0 })
        case .xray: return $model.simXRay
        case .objects: return $model.arObjects
        case .doors: return $model.arDoors
        case .terrain: return $model.arTerrain
        case .cameras: return $model.showCameras
        case .paths: return $model.showPaths
        case .agents: return $model.arAgents
        }
    }
}
