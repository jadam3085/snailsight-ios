// 9.8 Scans rooms: the floor plan of each level, made on the phone from the mesh (SnailSightCore.ScanLevels +
// FloorPlan: floors light, furniture grey, walls white), and the room editor on it — tap corners to draw a room (tap
// the first corner to close), drag a corner, tap an edge to add one, delete a corner; then name it from the Home
// Assistant areas or free text. Saved through the server's versioned rooms doc (API §8.4), the one the web viewer
// edits, so both stay in sync. The same plans feed the drone minimap.
import SwiftUI
import simd
import SnailSightCore

struct PlanEntry {
    let plan: FloorPlan
    let image: CGImage
}

/// Levels of the open scan and their floor plans (built off the main thread on first use).
@MainActor
final class ScanPlans: ObservableObject {
    @Published private(set) var floors: [Float] = []
    @Published private(set) var names: [String] = []
    @Published private(set) var ready: [Int: PlanEntry] = [:]
    private var tri: TriangleIndex?
    private var building = Set<Int>()
    private let log: DebugLog

    init(log: DebugLog) { self.log = log }

    func setMesh(_ t: TriangleIndex, mainY: Float?) async {
        tri = t
        let pos = t.positions, idx = t.indices
        let t0 = Date()
        var f = await Task.detached(priority: .utility) { ScanLevels.detect(positions: pos, indices: idx) }.value
        if f.isEmpty, let y = mainY ?? pos.map(\.y).min() { f = [y] }
        floors = f
        names = ScanLevels.names(f, mainY: mainY)
        log.event("scan_levels", ["floors": .doubles(f.map { Double($0) }), "s": .double(Date().timeIntervalSince(t0))])
    }

    /// The level the eye is on (eye ≈ floor + 1.45 m).
    func level(ofEye y: Float) -> Int? { ScanLevels.index(of: y - 1.0, floors: floors) }

    func request(_ i: Int) {
        guard ready[i] == nil, !building.contains(i), let t = tri, floors.indices.contains(i) else { return }
        building.insert(i)
        let y = floors[i]
        Task {
            let t0 = Date()
            let fp = await Task.detached(priority: .utility) { FloorPlan.build(positions: t.positions, indices: t.indices, floorY: y) }.value
            if let fp, let img = PlanImage.make(fp) {
                ready[i] = PlanEntry(plan: fp, image: img)
                log.event("scan_plan", ["level": .int(i), "px": .int(fp.width * fp.height), "s": .double(Date().timeIntervalSince(t0))])
            }
            building.remove(i)
        }
    }
}

struct RoomEditorView: View {
    enum Start: Equatable { case browse, newRoom(around: SIMD2<Double>?), edit(String) }

    @ObservedObject var labels: ScanLabelStore
    @ObservedObject var plans: ScanPlans
    let start: Start
    @Environment(\.dismiss) private var dismiss
    @State private var level: Int
    @State private var editor: RoomPolygonEditor?
    @State private var editingID: String?
    @State private var selected: String?
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var panStart = CGSize.zero
    @State private var dragIndex: Int?
    @State private var details: RoomRecord?
    @State private var focus: SIMD2<Double>?
    @State private var confirmDelete = false

    init(labels: ScanLabelStore, plans: ScanPlans, level: Int, start: Start) {
        self.labels = labels
        self.plans = plans
        self.start = start
        _level = State(initialValue: level)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color(white: 0.06).ignoresSafeArea()
                if let e = plans.ready[level] {
                    GeometryReader { geo in canvas(e, geo.size) }
                } else {
                    ProgressView("Drawing the floor plan…").foregroundStyle(.white)
                }
                panel
            }
            .navigationTitle(plans.names.indices.contains(level) ? plans.names[level] : "Rooms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if plans.names.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            ForEach(plans.names.indices, id: \.self) { i in Button(plans.names[i]) { setLevel(i) } }
                        } label: { Image(systemName: "square.stack.3d.up") }
                    }
                }
            }
            .sheet(item: $details) { r in
                NavigationStack {
                    RoomDetailsForm(room: r, areas: labels.areas, rooms: labels.rooms.rooms) { saved in
                        Task {
                            if await labels.upsertRoom(saved) {
                                editor = nil
                                editingID = nil
                                selected = saved.id
                            }
                        }
                    }
                }
            }
            .confirmationDialog("Delete this room?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let s = selected { Task { if await labels.deleteRoom(s) { selected = nil } } }
                }
            }
        }
        .onAppear {
            plans.request(level)
            switch start {
            case .browse: break
            case .newRoom(let p): editor = RoomPolygonEditor(); editingID = nil; focus = p
            case .edit(let id): beginEdit(id)
            }
        }
    }

    private func setLevel(_ i: Int) {
        level = i
        zoom = 1; pan = .zero
        plans.request(i)
    }

    private func roomsOnLevel() -> [RoomRecord] {
        guard plans.floors.indices.contains(level) else { return labels.rooms.rooms }
        let y = Double(plans.floors[level])
        return labels.rooms.rooms.filter { r in
            guard let z = r.floorZ else { return true }
            return abs(z - y) < 1.2 || ScanLevels.index(of: Float(z), floors: plans.floors) == level
        }
    }

    private func fit(_ e: PlanEntry, _ size: CGSize) -> PlanFit {
        let b = PlanFit.fit(e.plan, in: size, inset: 12)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        return PlanFit(scale: b.scale * zoom,
                       origin: CGPoint(x: c.x + (b.origin.x - c.x) * zoom + pan.width, y: c.y + (b.origin.y - c.y) * zoom + pan.height))
    }

    private func toMap(_ p: CGPoint, _ f: PlanFit, _ e: PlanEntry) -> SIMD2<Double> { e.plan.map(f.plan(p)) }
    private func toView(_ m: SIMD2<Double>, _ f: PlanFit, _ e: PlanEntry) -> CGPoint { f.view(e.plan.pixel(mapX: m.x, mapY: m.y)) }

    @ViewBuilder private func canvas(_ e: PlanEntry, _ size: CGSize) -> some View {
        let f = fit(e, size)
        let snapM = Double(24 / f.scale) * Double(e.plan.metersPerPixel)
        Canvas { ctx, _ in
            ctx.draw(Image(decorative: e.image, scale: 1), in: f.rect(e.plan))
            for r in roomsOnLevel() where r.id != editingID {
                let pts = r.points.map { toView($0, f, e) }
                guard pts.count >= 3 else { continue }
                var path = Path()
                path.addLines(pts)
                path.closeSubpath()
                let c = Color(hex: r.color)
                ctx.fill(path, with: .color(c.opacity(selected == r.id ? 0.35 : 0.18)))
                ctx.stroke(path, with: .color(c), lineWidth: selected == r.id ? 3 : 1.5)
                let cen = toView(Polygon2D.centroid(r.points), f, e)
                ctx.draw(Text(r.name).font(.caption.weight(.bold)).foregroundColor(.white), at: cen)
            }
            if let ed = editor {
                let pts = ed.points.map { toView($0, f, e) }
                if pts.count >= 2 {
                    var path = Path()
                    path.addLines(pts)
                    if ed.closed { path.closeSubpath() }
                    if ed.closed { ctx.fill(path, with: .color(.cyan.opacity(0.2))) }
                    ctx.stroke(path, with: .color(.cyan), style: StrokeStyle(lineWidth: 2.5, dash: ed.closed ? [] : [6, 4]))
                }
                for (i, p) in pts.enumerated() {
                    let r: CGFloat = (!ed.closed && i == 0 && pts.count >= 3) ? 11 : 7
                    let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(ed.selected == i ? .orange : .white))
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.black), lineWidth: 1.5)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { p in
            let m = toMap(p, f, e)
            if editor != nil {
                _ = editor?.tap(m, snap: snapM)
            } else {
                selected = roomsOnLevel().last { Polygon2D.contains($0.points, m) }?.id
            }
        }
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { v in
                    if dragIndex == nil && panStart == pan && v.translation == .zero { return }
                    if let i = dragIndex {
                        editor?.move(i, to: toMap(v.location, f, e))
                    } else if editor != nil, dragIndex == nil, v.translation.width.magnitude + v.translation.height.magnitude < 12,
                              let i = editor?.nearestVertex(toMap(v.startLocation, f, e), within: snapM) {
                        dragIndex = i
                        editor?.selected = i
                        editor?.move(i, to: toMap(v.location, f, e))
                    } else {
                        pan = CGSize(width: panStart.width + v.translation.width, height: panStart.height + v.translation.height)
                    }
                }
                .onEnded { _ in
                    dragIndex = nil
                    panStart = pan
                }
                .simultaneously(with: MagnifyGesture()
                    .onChanged { v in zoom = min(16, max(0.6, zoomStart * v.magnification)) }
                    .onEnded { _ in zoomStart = zoom })
        )
        .onAppear { applyFocus(e, size) }
        .onChange(of: focus) { _, _ in applyFocus(e, size) }
    }

    /// Centre the view on a point at 3× zoom (a new room started from a tap in 3D).
    private func applyFocus(_ e: PlanEntry, _ size: CGSize) {
        guard let m = focus else { return }
        focus = nil
        zoom = 3; zoomStart = 3
        pan = .zero
        let f = fit(e, size)
        let p = toView(m, f, e)
        pan = CGSize(width: size.width / 2 - p.x, height: size.height / 2 - p.y)
        panStart = pan
    }

    private func beginEdit(_ id: String) {
        guard let r = labels.rooms.rooms.first(where: { $0.id == id }) else { return }
        editor = RoomPolygonEditor(room: r)
        editingID = id
        selected = id
    }

    private var panel: some View {
        VStack(spacing: 8) {
            if let e = labels.error { Text(e).font(.caption).foregroundStyle(.orange) }
            if let ed = editor {
                Text(ed.closed ? "Drag a corner to move it · tap an edge to add a corner · tap a corner to select it"
                               : "Tap the room's corners on the plan · tap the first corner to close")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if ed.closed, let p = ed.problem() { Text(p).font(.caption.weight(.semibold)).foregroundStyle(.red) }
                HStack {
                    Button("Cancel", role: .cancel) { editor = nil; editingID = nil }
                    Spacer()
                    if !ed.closed {
                        Button { editor?.undoLast() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(ed.points.isEmpty)
                        Button { _ = editor?.close() } label: { Label("Close", systemImage: "checkmark.circle") }.disabled(ed.points.count < 3)
                    } else if let s = ed.selected {
                        Button(role: .destructive) { editor?.delete(s) } label: { Label("Corner", systemImage: "trash") }
                            .disabled(ed.points.count <= 3)
                    }
                    Spacer()
                    Button(editingID == nil ? "Next" : "Save") { finishOutline() }
                        .buttonStyle(.borderedProminent)
                        .disabled(ed.problem() != nil || labels.saving)
                }
            } else {
                if let s = selected, let r = labels.rooms.rooms.first(where: { $0.id == s }) {
                    HStack {
                        Circle().fill(Color(hex: r.color)).frame(width: 12, height: 12)
                        Text(r.name).font(.headline)
                        if let a = r.areaM2 { Text(String(format: "%.1f m²", a)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                    }
                    HStack {
                        Button { beginEdit(s) } label: { Label("Outline", systemImage: "pencil.and.outline") }
                        Button { details = r } label: { Label("Name", systemImage: "character.cursor.ibeam") }
                        Spacer()
                        Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    }
                } else {
                    Text(labels.rooms.rooms.isEmpty ? "No rooms yet: draw one." : "Tap a room to edit it, or draw a new one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { editor = RoomPolygonEditor(); editingID = nil; selected = nil } label: {
                    Label("New room", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(plans.ready[level] == nil)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    private func finishOutline() {
        guard let ed = editor, ed.problem() == nil else { return }
        let poly = ed.polygon()
        if let id = editingID, var r = labels.rooms.rooms.first(where: { $0.id == id }) {
            r.polygon = poly
            Task {
                if await labels.upsertRoom(r) { editor = nil; editingID = nil; selected = id }
            }
        } else {
            let fz = plans.floors.indices.contains(level) ? Double(plans.floors[level]) : nil
            details = RoomRecord(id: labels.rooms.newRoomID(), name: "", polygon: poly, floorZ: fz.map { ($0 * 1000).rounded() / 1000 },
                                 height: 2.4, color: labels.rooms.nextColor())
        }
    }
}
