// SnailSight 12.0 Map (owner-approved concept A2; outdoor = O1): a full-screen plan view.
// - Storey switcher B / 1 / 2 / Yd; the floor plan of the shown house version (MapPlanData), north up, pinch + drag.
// - Mesh (live): the shared live mesh tiles of EVERY agent drawn top-down as they arrive (floor light, raised mid,
//   walls dark), fresh / changed tiles outlined bright and fading; base tiles swapped by the M4 sync flash the same way.
//   The plan keeps updating while it is open (the downlink widens its tile box to ±40 m while the Map is up).
// - You (arrow), sim bodies (shared + local), the robot / drones and their routes, other agents, cameras.
// - Tap the plan: the selected body goes there (tap a body to select it first).
// - Yard (O1): measured terrain slope shading + robot no-go, surveyed vs estimated (hatched, public lidar 2015 ±2 m),
//   lidar trees as ghosts, corrected trees as a line from the estimate to where our sensors saw them, estimated-slope
//   no-go, "Explore gaps" (drone / rover goal at the biggest unsurveyed area).
import SwiftUI
import SnailSightCore

struct MapPlanView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var data: MapPlanData
    @ObservedObject var mesh: LiveMeshStore
    @ObservedObject var serverUI: ServerSimUI
    @Environment(\.dismiss) private var dismiss

    @State private var t = PlanTransform(center: .zero, ppm: 30, size: V2(390, 700))
    @State private var levelID: String?
    @State private var dragStart: PlanTransform?
    @State private var zoomStart: PlanTransform?
    @State private var placed = false
    @State private var size: CGSize = .zero
    @State private var layersOpen = false

    private var layer: MapARLayer { model.controller.mapLayer }
    private var level: PlanLevel? { data.levels.first { $0.id == levelID } }
    private var yard: Bool { levelID == "yard" }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.07, green: 0.09, blue: 0.11).ignoresSafeArea()
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    Canvas { g, sz in draw(&g, size: sz, now: ctx.date.timeIntervalSince1970) }
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(panZoom)
                .onTapGesture(coordinateSpace: .local) { p in tap(p) }
                .accessibilityLabel("House map, \(level?.title ?? "")")
                .accessibilityHint("Tap to send the selected body there")
                VStack(spacing: 8) {
                    topBar
                    if yard { YardLegend(data: data) }
                    Spacer()
                    bottomBar
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onAppear { size = geo.size; setup(size: geo.size) }
            .onChange(of: geo.size) { _, s in size = s; t.size = V2(Double(s.width), Double(s.height)) }
        }
        .onChange(of: data.levels) { _, _ in if levelID == nil || level == nil { pickInitialLevel() } }
        .onChange(of: levelID) { _, _ in data.refresh(level: level) }
        .onDisappear { model.mapFocus = nil }
        .sheet(isPresented: $layersOpen) { LayersSheet().environmentObject(model).presentationDetents([.medium, .large]) }
    }

    // MARK: setup

    private func setup(size: CGSize) {
        t.size = V2(Double(size.width), Double(size.height))
        data.refresh(level: level)
        pickInitialLevel()
        if let f = model.mapFocus, f.count >= 2 { t.center = V2(f[0], f[1]); t.ppm = 40 }
        else if let c = layer.cameraMap { t.center = V2(c[0], c[1]); t.ppm = 32 }
        else if let b = data.sceneBounds { t = PlanTransform.fit(b, size: t.size) }
        placed = true
    }

    private func pickInitialLevel() {
        guard !data.levels.isEmpty else { return }
        let z = model.mapFocus.flatMap { $0.count > 2 ? $0[2] : nil } ?? layer.cameraMap?[2]
        levelID = (z.flatMap { PlanLevels.level(ofZ: $0, in: data.levels) } ?? PlanLevels.entry(data.levels))?.id
        data.refresh(level: level)
    }

    // MARK: gestures

    private var panZoom: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                if dragStart == nil { dragStart = t }
                if let s = dragStart {
                    var n = s.panned(by: V2(Double(v.translation.width), Double(v.translation.height)))
                    n.ppm = t.ppm
                    t = n
                }
            }
            .onEnded { _ in dragStart = nil }
            .simultaneously(with: MagnifyGesture()
                .onChanged { v in
                    if zoomStart == nil { zoomStart = t }
                    if let s = zoomStart {
                        let a = V2(Double(v.startLocation.x), Double(v.startLocation.y))
                        let z = s.zoomed(by: Double(v.magnification), anchor: a)
                        t.ppm = z.ppm
                        t.center = z.center
                    }
                }
                .onEnded { _ in zoomStart = nil })
    }

    private func tap(_ p: CGPoint) {
        let v = V2(Double(p.x), Double(p.y))
        // a body under the finger: select it
        for b in model.serverSim.bodyInfos() where onLevel(b.pose[2], level: b.level) {
            if dist(t.toView(V2(b.pose[0], b.pose[1])), v) < 24 {
                model.serverSim.select(id: b.id)
                return
            }
        }
        for b in model.controller.sim.bodyInfos() {
            guard let m = layer.toMap(world: b.world), onLevel(m[2], level: nil) else { continue }
            if dist(t.toView(V2(m[0], m[1])), v) < 24 { model.controller.sim.select(id: b.id); return }
        }
        let g = t.toMap(v)
        let z = groundZ(g)
        if serverUI.active, serverUI.selection != nil {
            model.serverSim.goTo(mapPoint: [g.x, g.y, z])
        } else if !serverUI.active, model.controller.sim.ui.selection != nil {
            guard let w = layer.toWorld(map: [g.x, g.y, z]) else {
                model.flash("The house map has not placed you yet: the local sim needs that to go by the map", seconds: 3)
                return
            }
            model.controller.sim.goTo(world: w)
        } else {
            model.flash("Tap a body first (on the map or in AR), then tap where it should go", seconds: 2.5)
        }
    }

    private func dist(_ a: V2, _ b: V2) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private func groundZ(_ g: V2) -> Double {
        if let l = level, let f = l.floorZ { return f }
        if let z = data.groundZ(x: g.x, y: g.y) { return z }
        return PlanLevels.entry(data.levels)?.floorZ ?? 0
    }

    /// On the shown storey (Yard shows everything outdoors + the entry storey).
    private func onLevel(_ z: Double, level lv: Int?) -> Bool {
        guard let L = level else { return true }
        if let lv, let ll = L.level { return lv == ll || lv == -1 }
        return PlanLevels.level(ofZ: z, in: data.levels)?.id == L.id
    }

    // MARK: drawing

    private func rect(_ b: [Double]) -> CGRect {
        let a = t.toView(V2(b[0], b[3])), c = t.toView(V2(b[2], b[1]))
        return CGRect(x: a.x, y: a.y, width: c.x - a.x, height: c.y - a.y)
    }

    private func pt(_ x: Double, _ y: Double) -> CGPoint { let v = t.toView(V2(x, y)); return CGPoint(x: v.x, y: v.y) }

    private func draw(_ g: inout GraphicsContext, size: CGSize, now: Double) {
        let entry = PlanLevels.entry(data.levels)
        let shownLevel = yard ? entry : level
        // grid (1 m when zoomed in, else 5 m)
        drawGrid(&g, size: size)
        if yard {
            if let ti = data.terrainImage { g.draw(Image(decorative: ti.image, scale: 1), in: rect(ti.bounds)) }
            if let ci = data.coverageImage { g.draw(Image(decorative: ci.image, scale: 1).interpolation(.none), in: rect(ci.bounds)) }
            if let ni = data.noGoImage { g.draw(Image(decorative: ni.image, scale: 1).interpolation(.none), in: rect(ni.bounds)) }
        }
        if let l = shownLevel?.level, let img = data.planImages[l], let fp = data.floorplans[l] {
            var gg = g
            gg.opacity = yard ? 0.55 : 1
            gg.draw(Image(decorative: img, scale: 1), in: rect(fp.bounds))
        }
        if model.meshLive, let l = shownLevel?.level { drawLiveMesh(&g, level: l, now: now) }
        if yard { drawTrees(&g) }
        drawRooms(&g, level: shownLevel)
        if model.showCameras { drawCameras(&g, level: shownLevel) }
        if model.arAgents { drawAgents(&g) }
        drawBodies(&g)
        drawMe(&g)
        drawScaleBar(&g, size: size)
    }

    private func drawGrid(_ g: inout GraphicsContext, size: CGSize) {
        let step = t.ppm > 25 ? 1.0 : 5.0
        let tl = t.toMap(V2(0, 0)), br = t.toMap(V2(Double(size.width), Double(size.height)))
        var p = Path()
        var x = (tl.x / step).rounded(.down) * step
        while x <= br.x { p.move(to: pt(x, tl.y)); p.addLine(to: pt(x, br.y)); x += step }
        var y = (br.y / step).rounded(.down) * step
        while y <= tl.y { p.move(to: pt(tl.x, y)); p.addLine(to: pt(br.x, y)); y += step }
        g.stroke(p, with: .color(.white.opacity(0.05)), lineWidth: 0.5)
    }

    private func drawLiveMesh(_ g: inout GraphicsContext, level: Int, now: Double) {
        for r in mesh.rasters.values where r.level == level {
            let img = model.meshColour == .photo ? (r.photo ?? r.image) : r.image          // 12.1 photo colour
            if let img { g.draw(Image(decorative: img, scale: 1).interpolation(.none), in: rect(r.square)) }
        }
        for info in mesh.feed.fresh(now: now) where info.level == level {
            guard let sq = info.square else { continue }
            let st = mesh.feed.step(info, now: now)
            g.stroke(Path(rect(sq)), with: .color(Color(red: 0.45, green: 1, blue: 0.75).opacity(st >= 2 ? 0.95 : 0.45)),
                     lineWidth: st >= 2 ? 2.5 : 1.5)
        }
    }

    private func drawRooms(_ g: inout GraphicsContext, level: PlanLevel?) {
        guard t.ppm > 12 else { return }
        for r in model.roomChips {
            if let l = level, !yard, PlanLevels.level(ofZ: r.center[2], in: data.levels)?.id != l.id { continue }
            g.draw(Text(r.title).font(.caption2.weight(.semibold)).foregroundColor(.white.opacity(0.8)), at: pt(r.center[0], r.center[1]))
        }
    }

    private func drawCameras(_ g: inout GraphicsContext, level: PlanLevel?) {
        for c in data.cameras {
            if let l = level?.level, !yard, let cl = c.record?.level, cl != l { continue }
            let p = pt(c.pose.x, c.pose.y)
            if let yaw = c.pose.yaw, c.kind == "camera" {
                let fov = (c.record?.hfov ?? 90) * .pi / 180, far = min(c.record?.far ?? 8, 12)
                var w = Path()
                w.move(to: p)
                w.addLine(to: pt(c.pose.x + far * cos(yaw - fov / 2), c.pose.y + far * sin(yaw - fov / 2)))
                w.addLine(to: pt(c.pose.x + far * cos(yaw + fov / 2), c.pose.y + far * sin(yaw + fov / 2)))
                w.closeSubpath()
                g.fill(w, with: .color(.white.opacity(0.06)))
            }
            g.fill(Path(roundedRect: CGRect(x: p.x - 9, y: p.y - 7, width: 18, height: 14), cornerRadius: 3),
                   with: .color(Color(white: 0.25)))
            g.draw(Image(systemName: c.kind == "camera" ? "video.fill" : "sensor.fill"), in: CGRect(x: p.x - 6, y: p.y - 5, width: 12, height: 10))
        }
    }

    private func drawAgents(_ g: inout GraphicsContext) {
        for a in model.liveAgents where a.position.count >= 2 {
            var trail = Path()
            for (i, q) in a.trail.enumerated() where q.count >= 2 {
                if i == 0 { trail.move(to: pt(q[0], q[1])) } else { trail.addLine(to: pt(q[0], q[1])) }
            }
            g.stroke(trail, with: .color(.purple.opacity(0.6)), lineWidth: 1.5)
            let p = pt(a.position[0], a.position[1])
            g.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(a.live ? .purple : .gray))
            g.draw(Text(a.label).font(.caption2).foregroundColor(.purple), at: CGPoint(x: p.x, y: p.y - 14))
        }
    }

    private func drawBodies(_ g: inout GraphicsContext) {
        for b in model.serverSim.bodyInfos() where yard || onLevel(b.pose[2], level: b.level) {
            if model.showPaths, let path = b.path, path.count >= 2 {
                var r = Path()
                r.move(to: pt(b.pose[0], b.pose[1]))
                for q in path where q.count >= 2 { r.addLine(to: pt(q[0], q[1])) }
                g.stroke(r, with: .color(.cyan.opacity(b.selected ? 0.95 : 0.4)),
                         style: StrokeStyle(lineWidth: b.selected ? 2.5 : 1.5, dash: b.selected ? [] : [5, 4]))
            }
            let p = pt(b.pose[0], b.pose[1])
            let col: Color = b.drone ? .teal : b.rover || b.role == .robot ? .blue : b.role == .object ? .brown : .orange
            let r: CGFloat = b.selected ? 10 : 7
            g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(col))
            if b.selected {
                g.stroke(Path(ellipseIn: CGRect(x: p.x - r - 4, y: p.y - r - 4, width: 2 * r + 8, height: 2 * r + 8)),
                         with: .color(.cyan), lineWidth: 2)
            }
            if t.ppm > 15 || b.selected {
                g.draw(Text(b.title).font(.caption2.weight(.semibold)).foregroundColor(.white), at: CGPoint(x: p.x, y: p.y + r + 8))
            }
        }
        for b in model.controller.sim.bodyInfos() {
            guard let m = layer.toMap(world: b.world), yard || onLevel(m[2], level: nil) else { continue }
            let p = pt(m[0], m[1])
            let r: CGFloat = b.selected ? 9 : 6
            g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(b.role == .robot ? .blue : .orange.opacity(0.8)))
        }
    }

    private func drawMe(_ g: inout GraphicsContext) {
        guard let c = layer.cameraMap else { return }
        let p = pt(c[0], c[1])
        let f = layer.camForwardWorld
        let ahead = layer.toMap(world: layer.camWorld + f) ?? c
        let yaw = atan2(ahead[1] - c[1], ahead[0] - c[0])
        var arrow = Path()
        let s: Double = 11
        arrow.move(to: CGPoint(x: p.x + CGFloat(s * cos(yaw)), y: p.y - CGFloat(s * sin(yaw))))
        arrow.addLine(to: CGPoint(x: p.x + CGFloat(s * 0.7 * cos(yaw + 2.5)), y: p.y - CGFloat(s * 0.7 * sin(yaw + 2.5))))
        arrow.addLine(to: CGPoint(x: p.x + CGFloat(s * 0.7 * cos(yaw - 2.5)), y: p.y - CGFloat(s * 0.7 * sin(yaw - 2.5))))
        arrow.closeSubpath()
        g.fill(Path(ellipseIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)), with: .color(.blue.opacity(0.25)))
        g.fill(arrow, with: .color(.blue))
        g.stroke(arrow, with: .color(.white), lineWidth: 1.5)
    }

    private func drawTrees(_ g: inout GraphicsContext) {
        guard let e = data.estimated else { return }
        for tr in e.trees {
            let r = CGFloat(max(4, (tr.crownR ?? 2) * t.ppm * 0.6))
            let p = pt(tr.x, tr.y)
            switch tr.look {
            case .hidden: continue
            case .ghost:
                g.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(Color(red: 0.66, green: 0.82, blue: 0.56).opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            case .solid:
                g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(Color(red: 0.18, green: 0.35, blue: 0.16)))
                g.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(Color(red: 0.66, green: 0.82, blue: 0.56)), lineWidth: 2)
            case .corrected:
                if let est = tr.est {
                    let q = pt(est.x, est.y)
                    g.stroke(Path(ellipseIn: CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    var l = Path(); l.move(to: q); l.addLine(to: p)
                    g.stroke(l, with: .color(.yellow), lineWidth: 1.5)
                }
                g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(Color(red: 0.18, green: 0.35, blue: 0.16)))
                g.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(.yellow), lineWidth: 2)
                if let d = tr.offsetDistance, t.ppm > 6 {
                    g.draw(Text(String(format: "seen %.1f m off", d)).font(.caption2).foregroundColor(.yellow),
                           at: CGPoint(x: p.x, y: p.y - r - 8))
                }
            }
        }
    }

    private func drawScaleBar(_ g: inout GraphicsContext, size: CGSize) {
        let m = t.scaleBarMetres
        let w = CGFloat(m * t.ppm)
        let y = size.height - 150, x: CGFloat = 20
        var p = Path()
        p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + w, y: y))
        p.move(to: CGPoint(x: x, y: y - 4)); p.addLine(to: CGPoint(x: x, y: y + 4))
        p.move(to: CGPoint(x: x + w, y: y - 4)); p.addLine(to: CGPoint(x: x + w, y: y + 4))
        g.stroke(p, with: .color(.white.opacity(0.8)), lineWidth: 1.5)
        g.draw(Text(m >= 1 ? String(format: "%.0f m", m) : String(format: "%.0f cm", m * 100)).font(.caption2)
            .foregroundColor(.white.opacity(0.8)), at: CGPoint(x: x + w / 2, y: y - 10))
    }

    // MARK: chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close the map")
            VStack(alignment: .leading, spacing: 0) {
                Text(yard ? "Back yard + woods" : (level?.title ?? "Map")).font(.headline).foregroundStyle(.white)
                Text(subtitle).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(data.levels) { l in
                    Button { levelID = l.id } label: {
                        Text(l.label).font(.subheadline.weight(.semibold)).frame(width: 40, height: 40)
                            .foregroundStyle(levelID == l.id ? Color.black : Color.white)
                            .background(levelID == l.id ? Color.cyan : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(l.title)
                    .accessibilityAddTraits(levelID == l.id ? .isSelected : [])
                }
            }
            .padding(2)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var subtitle: String {
        var parts = [data.scene ?? "no house map yet"]
        if model.meshLive { parts.append("mesh live \(mesh.feed.liveCount)") }
        if yard { parts.append("2.5D terrain · slope shading") }
        return parts.joined(separator: " · ")
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            Text(serverUI.selection.map { "Tap the map to send \($0.title) there · pinch to zoom" }
                 ?? "Tap a body to select it · pinch to zoom, drag to pan")
                .font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
            HStack(spacing: 6) {
                chip("Mesh", "cube.transparent", $model.meshLive)
                chip("Terrain", "square.grid.3x3.topleft.filled", $model.arTerrain)
                chip("Cameras", "video", $model.showCameras)
                chip("Paths", "point.topleft.down.to.point.bottomright.curvepath", $model.showPaths)
                chip("Agents", "person.2.wave.2", $model.arAgents)
            }
            HStack(spacing: 8) {
                Button { recenter() } label: {
                    Label("Me", systemImage: "location.fill").frame(minWidth: 70, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(layer.cameraMap == nil)
                if yard {
                    Button { exploreGaps() } label: {
                        Label("Explore gaps", systemImage: "scope").frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                }
                Spacer()
                Button { layersOpen = true } label: {
                    Label("Layers", systemImage: "square.3.layers.3d").frame(minHeight: 44)
                }
                .buttonStyle(.bordered).tint(.white)
            }
        }
        .padding(.bottom, 8)
    }

    private func chip(_ title: String, _ icon: String, _ b: Binding<Bool>) -> some View {
        Button { b.wrappedValue.toggle() } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(b.wrappedValue ? Color.black : Color.white)
            .background(b.wrappedValue ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(.ultraThinMaterial),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(b.wrappedValue ? "on" : "off")
    }

    private func recenter() {
        guard let c = layer.cameraMap else { return }
        t.center = V2(c[0], c[1])
        if let l = PlanLevels.level(ofZ: c[2], in: data.levels) { levelID = l.id }
    }

    private func exploreGaps() {
        guard let gap = data.gapGoal() else {
            model.flash("No unsurveyed gap next to surveyed ground found yet", seconds: 2.5)
            return
        }
        model.log.event("explore_gaps", ["cells": .int(gap.cells), "goal": .doubles(gap.approach)])
        t.center = V2(gap.center[0], gap.center[1])
        if serverUI.active, let s = serverUI.selection, s.rover || s.drone {
            model.serverSim.explore(goal: [gap.approach[0], gap.approach[1], groundZ(V2(gap.approach[0], gap.approach[1]))])
        } else {
            model.flash(String(format: "Biggest unsurveyed gap: %.0f m² · select a sim drone or rover to send it",
                               Double(gap.cells) * 0.25), seconds: 3)
        }
    }
}

/// O1 legend: what is surveyed vs estimated, and how much.
private struct YardLegend: View {
    @ObservedObject var data: MapPlanData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(Color(red: 0.31, green: 0.51, blue: 0.24), "Surveyed by our sensors", dashed: false)
            row(Color(red: 0.66, green: 0.82, blue: 0.56).opacity(0.5),
                "Estimated · \(data.estimated?.sourceLabel ?? "public lidar")", dashed: true)
            row(.yellow, "Estimate corrected", dashed: false)
            row(Color(red: 0.9, green: 0.63, blue: 0.24), "Slope · robot no-go", dashed: false)
            HStack(spacing: 14) {
                stat("Surveyed", data.coverage.map { String(format: "%.0f%%", $0.surveyedFrac * 100) }
                     ?? data.terrainStats.map { String(format: "%.0f%%", $0.surveyedFrac * 100) } ?? "–")
                stat("Trees corrected", data.estimated.map { "\($0.correctedCount)" } ?? "–")
                stat("Canopy top", data.dem.flatMap { d in d.canopy.filter(\.isFinite).max().map { String(format: "%.0f m", $0) } } ?? "–")
            }
            if let n = data.estimatedNote { Text(n).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func row(_ c: Color, _ text: String, dashed: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(dashed ? Color.clear : c).frame(width: 18, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(c, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : [])))
            Text(text).font(.caption2).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
            Text(k).font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
    }
}
