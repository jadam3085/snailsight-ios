// SnailSight 12.0 (owner-approved concept C, 2026-10-18): ONE pull-up sheet over a clean AR view.
//  - collapsed: search + the four quick actions (Spawn · Room scan · Live map · Record)
//  - half: "Near you" (bodies, the robot / drones, cameras, other agents; nearest first, ONE primary action each) and
//    Places (the house map's rooms → the Map, + saved AR places)
//  - full: everything else, grouped — every tool that used to be in the 9.8–11.3 More menu (nothing removed, only moved)
// Drag the grabber / header between the detents (SnailSightCore.SheetDetent); typing in search opens it to half.
import SwiftUI
import SnailSightCore

struct MainSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var drag: CGFloat = 0
    @FocusState private var searching: Bool

    var body: some View {
        GeometryReader { geo in
            let h = Double(geo.size.height)
            let base = model.sheetDetent.height(container: h)
            let shown = max(SheetDetent.collapsed.height(container: h) - 40,
                            min(SheetDetent.full.height(container: h), base - Double(drag)))
            VStack(spacing: 0) {
                header(container: h, base: base)
                if model.sheetDetent != .collapsed || drag < -20 {
                    SheetContent(searching: $searching)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: CGFloat(shown), alignment: .top)
            .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22).stroke(.white.opacity(0.08)))
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .animation(.snappy(duration: 0.25), value: model.sheetDetent)
        }
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: searching) { _, s in if s && model.sheetDetent == .collapsed { model.sheetDetent = .half } }
        .onChange(of: model.sheetDetent) { _, d in
            if d == .collapsed { searching = false }
            model.log.event("sheet", ["detent": .int(d.rawValue)])
        }
    }

    private func header(container h: Double, base: Double) -> some View {
        VStack(spacing: 10) {
            Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 40, height: 5).padding(.top, 7)
                .accessibilityLabel("Sheet")
                .accessibilityHint("Swipe up for more, down to close")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { cycle() }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a room, animal, camera…", text: $model.sheetQuery)
                    .focused($searching)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if !model.sheetQuery.isEmpty {
                    Button { model.sheetQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            QuickActionsRow()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { v in drag = v.translation.height }
                .onEnded { v in
                    let end = base - Double(v.translation.height)
                    let vel = Double(v.predictedEndTranslation.height - v.translation.height) * 4
                    model.sheetDetent = SheetDetent.settle(height: end, velocity: vel, container: h)
                    drag = 0
                }
        )
    }

    private func cycle() {
        model.sheetDetent = SheetDetent(rawValue: (model.sheetDetent.rawValue + 1) % SheetDetent.allCases.count) ?? .collapsed
    }
}

// MARK: quick actions (C1)

private struct QuickActionsRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(QuickAction.allCases, id: \.self) { a in
                Button { run(a) } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            if a == .record {
                                Circle().stroke(Color.primary.opacity(0.85), lineWidth: 2).frame(width: 26, height: 26)
                                if model.recording { RoundedRectangle(cornerRadius: 3).fill(Color.red).frame(width: 12, height: 12) }
                                else { Circle().fill(Color.red).frame(width: 19, height: 19) }
                            } else {
                                Image(systemName: a.symbol).font(.system(size: 20, weight: .semibold))
                            }
                        }
                        .frame(height: 26)
                        Text(on(a) && a == .record ? "Stop" : a.title).font(.caption2.weight(.semibold)).lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(on(a) ? Color.accentColor : Color.primary)
                    .background(on(a) ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(disabled(a))
                .opacity(disabled(a) ? 0.4 : 1)
                .accessibilityLabel(a.accessibility(on: on(a)))
            }
        }
    }

    private func on(_ a: QuickAction) -> Bool {
        switch a {
        case .spawn: return model.spawnMode
        case .roomScan: return model.roomScanOn
        case .liveMap: return model.liveOn
        case .record: return model.recording
        }
    }

    private func disabled(_ a: QuickAction) -> Bool {
        switch a {
        case .spawn: return model.recording
        case .roomScan: return !RoomScanner.supported || model.recording
        case .liveMap, .record: return false
        }
    }

    private func run(_ a: QuickAction) {
        model.log.event("quick_action", ["action": .string(a.rawValue), "on": .bool(!on(a))])
        switch a {
        case .spawn:
            if model.spawnMode { model.endSpawnMode() } else {
                if !model.simOn { model.simOn = true }
                model.startSpawnMode()
                model.sheetDetent = .collapsed
            }
        case .roomScan: model.roomScanner.toggle()
        case .liveMap:
            model.liveOn.toggle()
            if model.liveOn {                       // the point of Live map: watch the shared mesh grow from your walk
                if !model.meshLive { model.meshLive = true }
                model.flash("Live map on: your walk builds the shared mesh (fresh tiles glow)", seconds: 3)
            }
        case .record: model.toggleRecording()
        }
    }
}

// MARK: half + full content

private struct SheetContent: View {
    @EnvironmentObject var model: AppModel
    var searching: FocusState<Bool>.Binding

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            List {
                nearSection
                placesSection
                if model.sheetDetent == .full && model.sheetQuery.isEmpty { FullSections() }
                else if model.sheetQuery.isEmpty {
                    Section {
                        Button { model.sheetDetent = .full } label: {
                            Label("All tools and settings", systemImage: "square.grid.2x2")
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .onAppear { model.planData.ensureCameras() }
        }
    }

    private var items: [NearItem] {
        NearList.filter(NearList.build(model.nearItems(), me: model.meZUp, limit: 40), query: model.sheetQuery)
    }

    @ViewBuilder private var nearSection: some View {
        let list = Array(items.prefix(model.sheetDetent == .full ? 20 : 8))
        Section("Near you") {
            if list.isEmpty {
                Text(model.sheetQuery.isEmpty ? "Nothing near yet: turn Sim on and Spawn, or wait for the house map to find you"
                                              : "No match for \"\(model.sheetQuery)\"")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(list) { it in NearRow(item: it) }
        }
    }

    @ViewBuilder private var placesSection: some View {
        let rooms = model.roomChips.filter { r in
            model.sheetQuery.isEmpty
                || !NearList.filter([NearItem(id: r.id, kind: .room, title: r.title)], query: model.sheetQuery).isEmpty
        }
        Section("Places") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(rooms) { r in
                        Button { model.showOnMap(r) } label: {
                            Text(r.title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(r.title), show on the map")
                    }
                    Button { model.showPlaces = true } label: {
                        Label("Saved places", systemImage: "mappin.and.ellipse").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        }
    }
}

private struct NearRow: View {
    @EnvironmentObject var model: AppModel
    let item: NearItem

    var body: some View {
        HStack(spacing: 12) {
            Button { model.focus(item) } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: item.kind == .animal ? 18 : 10, style: .continuous)
                            .fill(color.gradient)
                        Image(systemName: item.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text([item.subtitle, NearList.distanceText(item.distance)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.title), \(item.subtitle), \(NearList.distanceText(item.distance))")
            .accessibilityHint("Selects it")
            Button(item.primaryTitle) { model.primary(item) }
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 64, minHeight: 44)
                .buttonStyle(.borderless)
                .accessibilityLabel("\(item.primaryTitle) \(item.title)")
        }
        .frame(minHeight: 52)
    }

    private var color: Color {
        switch item.kind {
        case .animal: return .orange
        case .robot: return .blue
        case .drone: return .teal
        case .camera: return .gray
        case .agent: return .purple
        case .object: return .brown
        case .place, .room: return .green
        }
    }
}

// MARK: full detent: every former More-menu tool, grouped

private struct FullSections: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Tap tool") {
            Picker("Tap tool", selection: $model.tool) {
                ForEach(ToolMode.allCases) { t in Label(t.rawValue, systemImage: ToolIcons.icon(t)).tag(t) }
            }
            .pickerStyle(.menu)
            .onChange(of: model.tool) { _, t in model.flash(t.help) }
        }
        Section("View") {
            Button { model.showLayers = true } label: { Label("Layers…", systemImage: "square.3.layers.3d") }
            Button { model.openMap() } label: { Label("Map", systemImage: "map") }
            Picker(selection: $model.meshStyle) {
                ForEach(MeshStyle.allCases) { Text($0.rawValue).tag($0) }
            } label: { Label("LiDAR mesh style", systemImage: "square.grid.3x3") }
            Toggle(isOn: $model.occlusion) { Label("Occlusion", systemImage: "square.2.layers.3d") }
            Toggle(isOn: $model.peopleOcclusion) { Label("People occlusion", systemImage: "person.fill") }
        }
        Section("Sim") {
            Toggle(isOn: $model.simOn) { Label("Sim", systemImage: "pawprint") }
                .disabled(model.recording && !model.simAllowWhileRecording)
            if model.simOn {
                Button { model.startSpawnMode(); model.sheetDetent = .collapsed } label: { Label("Spawn…", systemImage: "plus.circle") }
                Toggle(isOn: Binding(get: { model.controller.sim.ui.scaleRef }, set: { model.controller.sim.ui.scaleRef = $0 })) {
                    Label("1 m reference", systemImage: "ruler")
                }
                Toggle(isOn: $model.simXRay) { Label("X-ray (see bodies through walls)", systemImage: "eye.circle") }
                Button(role: .destructive) { model.controller.sim.clear() } label: { Label("Clear sim", systemImage: "xmark.circle") }
            }
            if model.serverFeatures.serverSim(forced: model.forceServerSim) {
                Toggle(isOn: $model.sharedSim) { Label("Shared sim (server)", systemImage: "server.rack") }
                if model.simOn && model.serverSim.isActive {
                    Button { model.serverSim.spawn("sim-rover", arView: model.controller.arView); model.sheetDetent = .collapsed } label: {
                        Label("Spawn sim rover at +", systemImage: "car.side")
                    }
                    Button { model.serverSim.spawn("sim-drone", arView: model.controller.arView); model.sheetDetent = .collapsed } label: {
                        Label("Spawn sim drone at +", systemImage: "airplane")
                    }
                    Button { model.serverSim.startDroneAssist(); model.sheetDetent = .collapsed } label: {
                        Label("Drone-assist demo (selected rover)", systemImage: "airplane.departure")
                    }
                }
            }
            Picker(selection: $model.simScale) {
                ForEach([0.25, 0.35, 0.5, 0.75, 1.0], id: \.self) { Text(SimScale.label($0)).tag($0) }
            } label: { Label("Sim scale", systemImage: "arrow.down.right.and.arrow.up.left") }
            Picker(selection: $model.simPerf) {
                ForEach(SimPerfMode.allCases) { Text($0.title).tag($0) }
            } label: { Label("Sim quality", systemImage: "leaf") }
        }
        Section("House (AR 1:1)") {
            Picker(selection: $model.houseStyle) {
                ForEach(HouseStyle.allCases) { Text($0.rawValue).tag($0) }
            } label: { Label("House overlay", systemImage: "house") }
            Toggle(isOn: $model.rawScan) { Label("Raw scan (instead of structure)", systemImage: "cube.transparent") }
            Toggle(isOn: $model.arObjects) { Label("Objects", systemImage: "shippingbox") }
            Toggle(isOn: $model.arTerrain) { Label("Robot terrain", systemImage: "square.grid.3x3.topleft.filled") }
            Toggle(isOn: $model.arAgents) { Label("Other agents", systemImage: "person.2.wave.2") }
            Button { model.tool = .robotPath; model.sheetDetent = .collapsed } label: {
                Label("Robot path tool", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            Button { model.tool = .objects; model.sheetDetent = .collapsed } label: { Label("Fix objects tool", systemImage: "pencil") }
            CameraMarkRows()
        }
        Section("Mapping") {
            Toggle(isOn: $model.meshLive) { Label("Mesh (live) — see the mesh as it is built", systemImage: "cube.transparent") }
            Toggle(isOn: $model.meshMapOn) { Label("Map mesh (upload, no video)", systemImage: "cube.transparent") }
            Toggle(isOn: $model.meshMapAuto) { Label("Auto when localized", systemImage: "location.viewfinder") }
            Button { model.roomScanner.toggle() } label: {
                Label(model.roomScanOn ? "Stop room scan" : "Room scan", systemImage: "square.split.bottomrightquarter")
            }
            .disabled(!RoomScanner.supported)
            CameraMarkRows()
        }
        Section("Live map") {
            Toggle(isOn: $model.liveOn) { Label("Live map", systemImage: "dot.radiowaves.left.and.right") }
            Picker(selection: $model.liveRateHz) {
                ForEach(LiveGate.allowedRates, id: \.self) { Text(LiveText.rate($0)).tag($0) }
            } label: { Label("Live rate", systemImage: "metronome") }
            Text(model.meshStore.summary(me: model.agentID)).font(.footnote).foregroundStyle(.secondary)
        }
        Section("Place") {
            Button { model.placeCtl.saveNow() } label: { Label("Save place", systemImage: "square.and.arrow.down") }
                .disabled(model.place.relocalizing)
            Button { model.showPlaces = true } label: { Label("Places…", systemImage: "map") }
        }
        Section("Capture") {
            Button { model.toggleRecording() } label: {
                Label(model.recording ? "Stop recording" : "Record room", systemImage: "record.circle")
            }
            if !model.recording {
                Button { model.objectScan.showChooser = true } label: { Label("Object scan (high-res)", systemImage: "cube.transparent") }
            }
            Button { model.openScans() } label: { Label("Scans", systemImage: "square.stack.3d.up") }
                .disabled(model.recording)
        }
        Section("Session") {
            Button { model.showCubes = true } label: { Label("Cubes…", systemImage: "cube") }
            Button { model.controller.clearCubes() } label: { Label("Clear cubes", systemImage: "trash") }
            Button { model.controller.clearMeasures() } label: { Label("Clear measures", systemImage: "ruler") }
            Button { model.controller.resetSession() } label: { Label("Reset AR", systemImage: "arrow.counterclockwise") }
            Button { model.sendLog() } label: { Label(model.sendingLog ? "Sending log…" : "Send log", systemImage: "paperplane") }
                .disabled(model.sendingLog)
            if let url = model.logURL {
                ShareLink(item: url) { Label("Share log file…", systemImage: "square.and.arrow.up") }
            }
            Button { model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// 12.2: Mark camera + Camera check (in Mapping and House).
private struct CameraMarkRows: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button { model.cameraMark.showPicker = true } label: {
            Label("Mark camera… (confirm where a camera or sensor is)", systemImage: "scope")
        }
        .frame(minHeight: 44)
        .accessibilityLabel("Mark camera")
        .accessibilityHint("Pick a camera or sensor, then aim at the real one to locate it")
        CameraCheckToggle(check: model.cameraCheck)
    }
}

private struct CameraCheckToggle: View {
    @ObservedObject var check: CameraCheck

    var body: some View {
        Toggle(isOn: $check.on) { Label("Camera check — which cameras see me", systemImage: "video.badge.checkmark") }
            .frame(minHeight: 44)
            .accessibilityLabel("Camera check")
            .accessibilityHint("While you walk, shows which cameras see you and logs your path for calibration")
    }
}

enum ToolIcons {
    static func icon(_ t: ToolMode) -> String {
        switch t {
        case .cube: return "cube"
        case .measure: return "ruler"
        case .ruler: return "lines.measurement.horizontal"
        case .objects: return "shippingbox"
        case .robotPath: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

// MARK: - the sheet's data + actions

/// A room of the house map as a Places chip.
struct RoomChip: Identifiable, Equatable {
    var id: String
    var title: String
    var center: [Double]          // map frame x, y, z
}

extension AppModel {
    /// This phone in the world frame turned z-up ([x, −z, y]) so NearList's distances are horizontal.
    var meZUp: [Double] { Self.zUp(controller.mapLayer.camWorld) }

    static func zUp(_ w: SIMD3<Float>) -> [Double] { [Double(w.x), Double(-w.z), Double(w.y)] }

    /// Every row of "Near you", positions in the z-up world frame (bodies, robot / drones, cameras, other agents).
    func nearItems() -> [NearItem] {
        let layer = controller.mapLayer
        var out: [NearItem] = []
        for b in serverSim.bodyInfos() {
            let kind: NearItem.Kind = b.drone ? .drone : b.rover ? .robot : b.role == .robot ? .robot
                : b.role == .object ? .object : .animal
            out.append(NearItem(id: "srv:\(b.id)", kind: kind, title: b.title, subtitle: b.subtitle,
                                position: layer.toWorld(map: b.pose).map(Self.zUp), level: b.level))
        }
        for b in controller.sim.bodyInfos() {
            let kind: NearItem.Kind = b.role == .robot ? .robot : b.role == .object ? .object : .animal
            out.append(NearItem(id: "loc:\(b.id)", kind: kind, title: b.title, subtitle: "local sim", position: Self.zUp(b.world)))
        }
        if showCameras {
            for c in planData.cameras {
                out.append(NearItem(id: "cam:\(c.id)", kind: .camera, title: c.title, subtitle: c.subtitle,
                                    position: layer.toWorld(map: [c.pose.x, c.pose.y, c.pose.z]).map(Self.zUp),
                                    level: c.record?.level, primary: .show))
            }
        }
        if arAgents {
            for a in liveAgents where a.position.count >= 3 {
                out.append(NearItem(id: "agt:\(a.id)", kind: .agent, title: a.label, subtitle: a.live ? "live" : "seen",
                                    position: layer.toWorld(map: a.position).map(Self.zUp), primary: .show))
            }
        }
        return out
    }

    /// The house map's rooms (Places chips), from the rooms doc of the shown version.
    var roomChips: [RoomChip] {
        (controller.mapLayer.roomsDoc?.rooms ?? []).compactMap { r in
            let p = r.points
            guard !p.isEmpty else { return nil }
            let cx = p.map { $0[0] }.reduce(0, +) / Double(p.count), cy = p.map { $0[1] }.reduce(0, +) / Double(p.count)
            return RoomChip(id: r.id, title: r.name, center: [cx, cy, (r.floorZ ?? 0) + 0.1])
        }.sorted { $0.title < $1.title }
    }

    func openMap(focus: [Double]? = nil) {
        mapFocus = focus
        showMap = true
        sheetDetent = .collapsed
        log.event("map_open", ["focus": .bool(focus != nil)])
    }

    func showOnMap(_ r: RoomChip) { openMap(focus: r.center) }

    /// Tap on a row: select the body (the command ring opens on it), or show the item on the Map.
    func focus(_ it: NearItem) {
        let parts = it.id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "srv": serverSim.select(id: parts[1]); sheetDetent = .collapsed
        case "loc": controller.sim.select(id: Int(parts[1])); sheetDetent = .collapsed
        case "cam":
            if let c = planData.cameras.first(where: { $0.id == parts[1] }) { openMap(focus: [c.pose.x, c.pose.y, c.pose.z]) }
        case "agt":
            if let a = liveAgents.first(where: { $0.id == parts[1] }) { openMap(focus: a.position) }
        default: break
        }
    }

    /// The row's ONE primary action (Follow / Go to / Show …).
    func primary(_ it: NearItem) {
        log.event("near_action", ["id": .string(it.id), "action": .string(it.primary.rawValue)])
        switch it.primary {
        case .follow, .goTo:
            focus(it)
            let cmd: SimCommand = it.primary == .follow ? .follow : .goTo
            if it.id.hasPrefix("srv:") { serverSim.command(cmd) } else { controller.sim.command(cmd) }
        case .select, .show, .live, .locate: focus(it)
        }
    }
}
