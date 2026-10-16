import SwiftUI
import SnailSightCore

// 9.8 HUD (owner on 9.7.75: "less bulky and more polished, less wasted space, small buttons"):
//  - top: one slim status pill (tracking · place · fps · heat · server), tap to expand a detail card
//  - bottom: a small icon toolbar (Tool, Sim, Spawn/Places, Record, Scans, More), thumb reach; everything else that used
//    to be a chip row lives in the More menu
//  - contextual: the selected sim body's floating action bar, recording / upload / measure capsules only when relevant
// Every 9.7 function is still one or two taps away (see `moreMenu`).

struct HUDView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 4) {                                    // 10.2: "am I localized?" at the top edge
                LocalizationPill()
                if let m = model.meshMapText { MappingLine(text: m, live: model.meshMapLive) }
                if model.locExpanded { LocCard().transition(.move(edge: .top).combined(with: .opacity)) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, -2)
            HStack(alignment: .top, spacing: 6) {
                StatusPill()
                Spacer(minLength: 0)
            }
            if model.statusExpanded { StatusCard().transition(.move(edge: .top).combined(with: .opacity)) }
            if let t = model.toast {
                Text(t).font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            bottomStack
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.2), value: model.statusExpanded)
        .animation(.snappy(duration: 0.2), value: model.locExpanded)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .animation(.easeInOut(duration: 0.2), value: model.undoText)
    }

    @ViewBuilder private var bottomStack: some View {
        VStack(spacing: 6) {
            if model.recording { recordingCapsules }
            if !model.recording, let it = model.panelItem { UploadCapsule(item: it) }
            if let m = model.measureText {
                Text(m).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    .padding(.horizontal, 14).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if let u = model.undoText { UndoToast(text: u) }
            if let l = model.liveText { LiveCapsule(text: l, good: model.liveGood) }
            if model.houseStyle != .off || model.arTerrain, !model.recording,
               !model.arStatus.title.isEmpty, model.arStatus.tone != .good {
                ARStatusChip(status: model.arStatus)               // 10.1 AR 1:1: finding / correcting / dimmed
            }
            if let c = model.cubeSel, !model.recording { CubeBar(cube: c) }
            if model.simOn && !model.recording && model.spawnMode { SpawnModeBanner() }
            if model.simOn && !model.recording {
                SimArea(shared: model.serverSim.ui)               // 10.1: shared (S2) or local (S1) sim controls
            }
            BottomToolbar()
        }
    }


    // MARK: recording

    @ViewBuilder private var recordingCapsules: some View {
        if let w = model.recWarning {
            Label(w, systemImage: "thermometer.medium").font(.caption.weight(.semibold)).lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.orange.opacity(0.85), in: Capsule()).foregroundStyle(.black)
        }
        if model.meshMode == .frozen {          // 9.6: the mesh stays, dimmed; say why it stopped
            Label(model.recNote ?? "Mesh frozen until Stop (kept on screen, dimmed)", systemImage: "snowflake")
                .font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
        }
        RecPill()
    }
}

// MARK: - status pill + card

private struct StatusPill: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button { model.statusExpanded.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(trackColor).frame(width: 8, height: 8)
                Image(systemName: placeIcon).font(.caption2.weight(.bold)).foregroundStyle(placeColor)
                Text(placeShort).font(.caption.weight(.semibold)).lineLimit(1).foregroundStyle(placeColor)
                    .frame(maxWidth: 130, alignment: .leading)
                Text(fpsText).font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(fpsWarn ? Color.orange : Color.primary)
                if let chip = thermalChip {
                    Label(chip.label, systemImage: "thermometer.medium").font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                        .foregroundStyle(.orange)
                }
                if model.recording && model.recStats.slowDown {
                    Image(systemName: "tortoise.fill").font(.caption2).foregroundStyle(.yellow)
                        .accessibilityLabel("Moving fast for sharp photos")
                }
                Circle().fill(model.serverBase == nil ? Color.orange : Color.green).frame(width: 6, height: 6)
                Image(systemName: model.statusExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Status: \(model.locPill.text), place \(model.place.short), \(fpsText)")
    }

    private var trackColor: Color {
        switch model.tracking.severity {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        }
    }
    // 10.3: the localization pill above is the ONE state (house-map lock + ARKit tracking); this pill names the saved
    // place only, in neutral colours, so the two never disagree ("Limited · Relocalizing" next to "LOCALIZED").
    private var placeIcon: String { model.place.tone == .good ? "mappin.and.ellipse" : "mappin" }
    private var placeColor: Color { model.place.tone == .good ? .primary : .secondary }
    private var placeShort: String { model.place.short }
    private var target: Int { model.controller.heatBudget.arFPS }
    private var fpsWarn: Bool { StatusText.fpsTone(fps: model.fps, target: target) == .warn }
    private var fpsText: String {
        model.recording ? String(format: "%.0f fps · REC %.0f", model.fps, model.recRateHz) : String(format: "%.0f fps", model.fps)
    }
    private var thermalChip: (label: String, detail: String)? {
        StatusText.thermalChip(ThermalLevel(label: model.thermal), recording: model.recording, recRateHz: model.recRateHz)
    }
}

enum HUDColors {
    static func place(_ t: PlaceHUD.Tone) -> Color {
        switch t {
        case .good: return .green
        case .working: return .orange
        case .bad: return .red
        case .neutral: return .primary
        }
    }
}

/// The expanded status: everything the 9.7 banner said, in one card, plus why fps / heat look the way they do.
private struct StatusCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(model.locPill.text).font(.footnote.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(model.locPill.tone == .good ? Color.green : model.locPill.tone == .working ? .orange : .secondary)
                Spacer(minLength: 0)
                Button { model.showSettings = true } label: { Image(systemName: "gearshape").font(.callout) }
                    .accessibilityLabel("Settings")
            }
            if model.locPill.text.hasPrefix("TRACKING LIMITED"), let h = model.tracking.hint {
                row("hand.point.up.left", h, .orange)
            }
            Button { model.showPlaces = true } label: {             // saved place: secondary info
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "map").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.place.title).font(.caption.weight(.semibold))
                            .foregroundStyle(model.place.tone == .working ? Color.orange : .secondary)
                        Text(model.place.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            row("speedometer", StatusText.fpsExplain(fps: model.fps, target: model.controller.heatBudget.arFPS,
                                                     thermal: ThermalLevel(label: model.thermal)), .secondary)
            if let c = StatusText.thermalChip(ThermalLevel(label: model.thermal), recording: model.recording,
                                              recRateHz: model.recRateHz) {
                row("thermometer.medium", c.detail, .orange)
            }
            if let n = model.heatNote { row("leaf", n, .secondary) }
            if !model.arStatus.title.isEmpty {
                row("house", "\(model.arStatus.title) · \(model.arStatus.detail)", model.arStatus.tone == .good ? .secondary : .orange)
            }
            if let m = model.mapFollower.statusLine { row("arrow.triangle.2.circlepath", m, .secondary) }   // 10.7
            Text("ar \(model.tracking.code) · map \(model.mapping) · mesh \(model.meshAnchors) \(AdaptiveCapture.meshLabel(model.meshMode, recording: model.recording)) · heat \(model.thermal) · v\(model.version)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            row(model.serverBase == nil ? "wifi.slash" : "server.rack", model.serverText,
                model.serverBase == nil ? .orange : .secondary)
            if let e = model.error { row("exclamationmark.triangle", e, .red) }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { model.statusExpanded = false }
    }

    private func row(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.caption2).frame(width: 14)
            Text(text).font(.caption2).lineLimit(3).multilineTextAlignment(.leading)
        }
        .foregroundStyle(color)
    }
}

// MARK: - bottom toolbar

private struct BottomToolbar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            toolMenu
            ToolButton(icon: model.simOn ? "pawprint.fill" : "pawprint", label: "Sim", active: model.simOn) {
                model.simOn.toggle()
            }
            .disabled(model.recording && !model.simAllowWhileRecording)
            if model.simOn {
                ToolButton(icon: model.spawnMode ? "plus.circle.fill" : "plus.circle", label: "Spawn",
                           active: model.spawnMode, tint: .cyan) {
                    if model.spawnMode { model.endSpawnMode() } else { model.startSpawnMode() }
                }
                .disabled(model.recording)
            } else {
                ToolButton(icon: "map", label: "Places") { model.showPlaces = true }
            }
            RecordButton()
            ToolButton(icon: "square.stack.3d.up", label: "Scans") { model.openScans() }
                .disabled(model.recording)
            MoreMenu()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08)))
    }

    private var toolMenu: some View {
        Menu {
            Picker("Tap tool", selection: $model.tool) {
                ForEach(ToolMode.allCases) { t in Label(t.rawValue, systemImage: Self.icon(t)).tag(t) }
            }
        } label: {
            ToolLabel(icon: Self.icon(model.tool), label: model.tool == .ruler ? "Ruler" : model.tool.rawValue)
        }
        .onChange(of: model.tool) { _, t in model.flash(t.help) }
    }

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

private struct ToolLabel: View {
    let icon: String
    let label: String
    var active = false
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? Color.cyan : tint)
            Text(label).font(.system(size: 9, weight: .medium)).lineLimit(1).foregroundStyle(.secondary)
        }
        .frame(width: 46, height: 40)
        .background(active ? Color.cyan.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

private struct ToolButton: View {
    let icon: String
    let label: String
    var active = false
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) { ToolLabel(icon: icon, label: label, active: active, tint: tint) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}

/// Record: the one prominent control (red ring; a stop square while recording).
private struct RecordButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button { model.toggleRecording() } label: {
            ZStack {
                Circle().stroke(.white.opacity(0.9), lineWidth: 2.5).frame(width: 44, height: 44)
                if model.recording {
                    RoundedRectangle(cornerRadius: 4).fill(Color.red).frame(width: 18, height: 18)
                } else {
                    Circle().fill(Color.red).frame(width: 34, height: 34)
                }
            }
            .frame(width: 54, height: 46)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.recording ? "Stop recording" : "Record room")
    }
}

/// Everything else, one tap away (9.7 chip rows → menu sections).
private struct MoreMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            Section("View") {
                Picker(selection: $model.meshStyle) {
                    ForEach(MeshStyle.allCases) { Text($0.rawValue).tag($0) }
                } label: { Label("Mesh: \(model.meshStyle.rawValue)", systemImage: "square.grid.3x3") }
                .pickerStyle(.menu)
                Toggle(isOn: $model.occlusion) { Label("Occlusion", systemImage: "square.2.layers.3d") }
                Toggle(isOn: $model.peopleOcclusion) { Label("People occlusion", systemImage: "person.fill") }
            }
            Section("Sim") {
                Toggle(isOn: $model.simOn) { Label("Sim", systemImage: "pawprint") }
                if model.simOn {
                    Button { model.startSpawnMode() } label: { Label("Spawn…", systemImage: "plus.circle") }
                    Toggle(isOn: Binding(get: { model.controller.sim.ui.scaleRef },
                                         set: { model.controller.sim.ui.scaleRef = $0 })) {
                        Label("1 m reference", systemImage: "ruler")
                    }
                    Toggle(isOn: $model.simXRay) { Label("X-ray (see bodies through walls)", systemImage: "eye.circle") }
                    Button(role: .destructive) { model.controller.sim.clear() } label: {
                        Label("Clear sim", systemImage: "xmark.circle")
                    }
                }
                if model.serverFeatures.serverSim(forced: model.forceServerSim) {
                    Toggle(isOn: $model.sharedSim) { Label("Shared sim (server)", systemImage: "server.rack") }
                    if model.simOn && model.serverSim.isActive {
                        Button { model.serverSim.spawn("sim-rover", arView: model.controller.arView) } label: {
                            Label("Spawn sim rover at +", systemImage: "car.side")
                        }
                        Button { model.serverSim.spawn("sim-drone", arView: model.controller.arView) } label: {
                            Label("Spawn sim drone at +", systemImage: "airplane")
                        }
                        Button { model.serverSim.startDroneAssist() } label: {
                            Label("Drone-assist demo (selected rover)", systemImage: "airplane.departure")
                        }
                    }
                }
                Picker(selection: $model.simScale) {
                    ForEach([0.25, 0.35, 0.5, 0.75, 1.0], id: \.self) { Text(SimScale.label($0)).tag($0) }
                } label: { Label("Sim scale \(SimScale.label(model.simScale))", systemImage: "arrow.down.right.and.arrow.up.left") }
                .pickerStyle(.menu)
                Picker(selection: $model.simPerf) {
                    ForEach(SimPerfMode.allCases) { Text($0.title).tag($0) }
                } label: { Label("Sim quality", systemImage: "leaf") }
                .pickerStyle(.menu)
            }
            Section("House (AR 1:1)") {
                Picker(selection: $model.houseStyle) {
                    ForEach(HouseStyle.allCases) { Text($0.rawValue).tag($0) }
                } label: { Label("House overlay: \(model.houseStyle.rawValue)", systemImage: "house") }
                .pickerStyle(.menu)
                Toggle(isOn: $model.arObjects) { Label("Objects", systemImage: "shippingbox") }
                Toggle(isOn: $model.arTerrain) { Label("Robot terrain", systemImage: "square.grid.3x3.topleft.filled") }
                Toggle(isOn: $model.arAgents) { Label("Other agents", systemImage: "person.2.wave.2") }
                Button { model.tool = .robotPath } label: { Label("Robot path tool", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                Button { model.tool = .objects } label: { Label("Fix objects tool", systemImage: "pencil") }
            }
            Section("Mapping (mesh only)") {
                Toggle(isOn: $model.meshMapOn) { Label("Map mesh", systemImage: "cube.transparent") }
                Toggle(isOn: $model.meshMapAuto) { Label("Auto when localized", systemImage: "location.viewfinder") }
            }
            Section("Live map") {
                Toggle(isOn: $model.liveOn) { Label("Live map", systemImage: "dot.radiowaves.left.and.right") }
                Picker(selection: $model.liveRateHz) {
                    ForEach(LiveGate.allowedRates, id: \.self) { Text(LiveText.rate($0)).tag($0) }
                } label: { Label("Live rate \(LiveText.rate(model.liveRateHz))", systemImage: "metronome") }
                .pickerStyle(.menu)
            }
            Section("Place") {
                Button { model.placeCtl.saveNow() } label: { Label("Save place", systemImage: "square.and.arrow.down") }
                    .disabled(model.place.relocalizing)
                Button { model.showPlaces = true } label: { Label("Places…", systemImage: "map") }
            }
            Section("Capture") {
                if !model.recording {
                    Button { model.objectScan.showChooser = true } label: {
                        Label("Object scan (high-res)", systemImage: "cube.transparent")
                    }
                }
                Button { model.openScans() } label: { Label("Scans", systemImage: "square.stack.3d.up") }
                    .disabled(model.recording)
            }
            Section("Session") {
                Button { model.showCubes = true } label: { Label("Cubes…", systemImage: "cube") }
                Button { model.controller.clearCubes() } label: { Label("Clear cubes", systemImage: "trash") }
                Button { model.controller.clearMeasures() } label: { Label("Clear measures", systemImage: "ruler") }
                Button { model.controller.resetSession() } label: { Label("Reset AR", systemImage: "arrow.counterclockwise") }
                Button { model.sendLog() } label: {
                    Label(model.sendingLog ? "Sending log…" : "Send log", systemImage: "paperplane")
                }
                .disabled(model.sendingLog)
                if let url = model.logURL {
                    ShareLink(item: url) { Label("Share log file…", systemImage: "square.and.arrow.up") }
                }
                Button { model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        } label: {
            ToolLabel(icon: "ellipsis.circle", label: "More")
        }
        .accessibilityLabel("More")
    }
}

// MARK: - 10.2 localization pill, its card, the mapping line

/// "LOCALIZED · whole house v10 · geometry+visual · ±2 cm" (green) / "FINDING YOU… 12 s" (amber) / "OFFLINE" · "NOT IN MAP"
/// (grey). Tap for the detail card. Never blocks: it only reads MapLocalizer's published state.
private struct LocalizationPill: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let p = model.locPill
        Button { model.locExpanded.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: icon(p.tone)).font(.system(size: 10, weight: .bold))
                Text(p.text).font(.caption2.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if model.meshMapLive {
                    Image(systemName: "cube.transparent").font(.system(size: 10, weight: .bold))
                        .accessibilityLabel("mapping")
                }
            }
            .foregroundStyle(p.tone == .idle ? Color.white : Color.black)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(fill(p.tone), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Localization: \(p.text)")
        .accessibilityHint("Shows how the phone is localized in the house map")
    }

    private func icon(_ t: LocPillTone) -> String {
        switch t {
        case .good: return "location.fill"
        case .working: return "location.magnifyingglass"
        case .idle: return model.serverBase == nil ? "wifi.slash" : "location.slash"
        }
    }

    private func fill(_ t: LocPillTone) -> Color {
        switch t {
        case .good: return Color.green.opacity(0.85)
        case .working: return Color.orange.opacity(0.85)
        case .idle: return Color.gray.opacity(0.65)
        }
    }
}

/// "mapping · 34 MB · 12 kf" (green dot while capturing, orange when paused / uploading).
private struct MappingLine: View {
    let text: String
    let live: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(live ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(text).font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel(text)
    }
}

/// The pill's detail: method, last fix, error, map; Retry, Pick place, Map mesh.
private struct LocCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(model.locPill.rows.enumerated()), id: \.offset) { _, r in
                Text(r).font(.caption2).lineLimit(2).multilineTextAlignment(.leading)
            }
            Text(model.serverText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 8) {
                Button { model.mapLocalizer.retry() } label: {
                    Label(model.mapLocalizer.isLocked ? "Re-check" : "Retry", systemImage: "arrow.clockwise")
                }
                .disabled(model.serverBase == nil)
                Button { model.locExpanded = false; model.showPlaces = true } label: {
                    Label("Pick place", systemImage: "map")
                }
                Spacer(minLength: 0)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            Toggle(isOn: $model.meshMapOn) {
                Label("Map mesh (no video, no audio)", systemImage: "cube.transparent").font(.caption)
            }
            Toggle(isOn: $model.meshMapAuto) {
                Label("Auto when localized", systemImage: "location.viewfinder").font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 10.0 Live map status line

/// "LIVE 2 Hz · sent 120 · acked 118 · queue 2 · lag 180 ms · placed via anchors" / "LIVE offline · queue 37 (resuming)".
private struct LiveCapsule: View {
    let text: String
    let good: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.caption2.weight(.bold))
                .foregroundStyle(good ? Color.green : Color.orange)
            Text(text).font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke((good ? Color.green : Color.orange).opacity(0.35)))
        .accessibilityLabel(text)
    }
}

// MARK: - 9.9 cubes: selected cube bar, undo toast, list

/// The selected placed cube: what it is, ✕ deletes it (Undo for 5 s), the list button opens all cubes.
private struct CubeBar: View {
    @EnvironmentObject var model: AppModel
    let cube: CubeSelection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cube.fill").foregroundStyle(.cyan)
            Text("Cube #\(cube.number) · 10 cm").font(.caption.weight(.bold))
            Spacer(minLength: 4)
            Button { model.showCubes = true } label: { Image(systemName: "list.bullet").frame(width: 28, height: 26) }
                .accessibilityLabel("All cubes")
            Button { model.controller.deleteSelectedCube() } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 26).background(Color.red.opacity(0.8), in: Circle())
            }
            .accessibilityLabel("Delete cube \(cube.number)")
            Button { model.controller.selectCube(nil) } label: { Image(systemName: "chevron.down").frame(width: 24, height: 26) }
                .accessibilityLabel("Deselect")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: 360)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.cyan.opacity(0.35)))
    }
}

/// "Deleted cube #3   Undo" for 5 s.
private struct UndoToast: View {
    @EnvironmentObject var model: AppModel
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash").font(.caption)
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
            Button("Undo") { model.controller.undoDeletion() }
                .font(.caption.weight(.bold)).foregroundStyle(.yellow)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .transition(.opacity)
    }
}

/// Every cube (placed test cubes + sim blocks / crates / boxes): swipe to delete, Clear all. Deletions get the Undo toast.
struct CubeListView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    struct PlacedRow: Identifiable { let id: UUID; let number: Int }
    struct SimRow: Identifiable { let id: Int; let title: String; let detail: String }
    @State private var placed: [PlacedRow] = []
    @State private var sims: [SimRow] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Placed cubes (\(placed.count))") {
                    if placed.isEmpty { Text("None: Tool ▸ Cube, then tap a surface").foregroundStyle(.secondary) }
                    ForEach(placed) { c in
                        Button {
                            model.controller.selectCube(c.id)
                            dismiss()
                        } label: { Label("Cube #\(c.number) · 10 cm", systemImage: "cube.fill") }
                    }
                    .onDelete { idx in
                        model.controller.deleteCubes(idx.map { placed[$0].id }, via: "list")
                        reload()
                    }
                }
                Section("Sim cubes (\(sims.count))") {
                    if sims.isEmpty { Text("None: Sim ▸ Spawn ▸ Blocks / Crate / Box").foregroundStyle(.secondary) }
                    ForEach(sims) { o in
                        HStack {
                            Label(o.title, systemImage: "square.stack.3d.up.fill")
                            Spacer()
                            Text(o.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        model.controller.sim.deleteObjects(idx.map { sims[$0].id }, via: "list")
                        reload()
                    }
                }
            }
            .navigationTitle("Cubes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear all", role: .destructive) { model.controller.clearCubes(); reload() }
                        .disabled(placed.isEmpty && sims.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let u = model.undoText {
                    HStack {
                        Text(u).font(.caption.weight(.semibold))
                        Spacer()
                        Button("Undo") { model.controller.undoDeletion(); reload() }.font(.caption.weight(.bold))
                    }
                    .padding(12).background(.ultraThinMaterial)
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        placed = model.controller.placedCubes.map { PlacedRow(id: $0.id, number: $0.number) }
        sims = model.controller.sim.cubeObjects.map { SimRow(id: $0.id, title: $0.title, detail: $0.detail) }
    }
}

// MARK: - recording + upload capsules

private struct RecPill: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.recStats
        let mb = Double(s.bytes) / 1_048_576
        let mins = Int(s.elapsed) / 60, secs = Int(s.elapsed) % 60
        return HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 9, height: 9)
            Text(String(format: "REC %d:%02d", mins, secs)).font(.subheadline.weight(.bold)).monospacedDigit()
            Text(String(format: "%d fr · %.0f MB · %.0f fps", s.frames, mb, model.recRateHz))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if s.keyframes > 0 { Text("\(s.keyframes) kf").font(.caption2).foregroundStyle(.secondary) }
            if s.dropped > 0 { Text("\(s.dropped) dropped").font(.caption2).foregroundStyle(.orange) }
            if s.slowDown {                 // 9.8: a small hint, only after sustained blur the keyframes confirm
                Label("slower", systemImage: "tortoise.fill").font(.caption2.weight(.semibold))
                    .foregroundStyle(.yellow)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Capture upload status on the main screen (owner 2026-10-12: not only in Settings), one compact capsule.
private struct UploadCapsule: View {
    @EnvironmentObject var model: AppModel
    let item: UploadItem

    var body: some View {
        let it = item
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: it.serverHasAll ? (it.state == "processed" ? "checkmark.circle.fill" : "gearshape.2")
                                                  : "icloud.and.arrow.up")
                    .font(.caption)
                Text(model.uploadLine(it)).font(.caption.weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if it.serverHasAll {
                    Button { model.hiddenUploadPanel = it.id } label: { Image(systemName: "xmark").font(.caption2) }
                        .accessibilityLabel("Hide")
                }
            }
            if !it.serverHasAll {
                ProgressView(value: it.progress).tint(it.backgroundSafe ? .green : .orange).scaleEffect(y: 0.6)
                if !it.backgroundSafe {
                    Text(model.uploadHint(it)).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
            if let e = it.error, !it.serverHasAll || it.state == "failed" {
                Text(e).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 10.1 AR 1:1 status + sim area

/// "FINDING YOU · …" / "CORRECTING 12 cm" / "TRACKING LIMITED" while the house overlay is not plainly locked.
private struct ARStatusChip: View {
    let status: ARMapStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.tone == .warn ? "exclamationmark.triangle" : "house")
                .font(.caption2.weight(.bold)).foregroundStyle(status.tone == .warn ? Color.orange : Color.cyan)
            Text(status.title).font(.caption2.weight(.bold)).lineLimit(1)
            Text(status.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel("\(status.title). \(status.detail)")
    }
}

/// Sim controls: the shared sim's bar while the map server is authoritative, else the local sim's (9.8) bar; the
/// joystick drives whichever robot is in charge.
private struct SimArea: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var shared: ServerSimUI

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if shared.active {
                ServerSimBar(ui: shared, sim: model.serverSim)
            } else {
                SimActionBar(ui: model.controller.sim.ui, sim: model.controller.sim)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if shared.active ? (shared.selection?.rover ?? false) : model.simRobot {
                    JoystickView(size: 104) { v in
                        if shared.active { model.serverSim.setStick(v) } else { model.controller.sim.setStick(v) }
                    }
                }
                // 10.6: ONE status chip — in server mode the bar's own chip carries "Server sim · N bodies"
                let text = shared.active ? ""
                    : [shared.status, model.simStatus].filter { !$0.isEmpty }.joined(separator: " · ")
                if !text.isEmpty {
                    Text(text).font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer(minLength: 0)
            }
        }
    }
}


/// 10.6 Spawn mode banner: what to do, which kind is picked, change it, or end the mode.
private struct SpawnModeBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 0) {
                Text("Spawn mode").font(.caption.weight(.bold))
                Text(model.spawnPick.map { "\(name($0)): tap the floor to place · drag to move · drop on the trash to delete" }
                     ?? "Pick an animal, then tap the floor to place")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            Button(model.spawnPick == nil ? "Pick" : "Change") { model.showSpawn = true }
                .font(.caption.weight(.semibold)).buttonStyle(.bordered).controlSize(.small)
            Button { model.endSpawnMode() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                .buttonStyle(.plain).accessibilityLabel("End spawn mode")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: 440)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.cyan.opacity(0.6), lineWidth: 1.5))
    }

    private func name(_ k: String) -> String {
        k == "robot" ? "RobosnailBob" : (model.controller.sim.catalog.item(k)?.label ?? k.capitalized)
    }
}

/// 10.6 trash can while a body is dragged: drop it here to delete it (red = will delete).
struct SimTrashCan: View {
    let hot: Bool

    var body: some View {
        Image(systemName: hot ? "trash.fill" : "trash")
            .font(.system(size: hot ? 30 : 24, weight: .semibold))
            .foregroundStyle(hot ? Color.white : Color.red)
            .frame(width: hot ? 72 : 60, height: hot ? 72 : 60)
            .background(hot ? Color.red : Color.black.opacity(0.45), in: Circle())
            .overlay(Circle().stroke(Color.red, lineWidth: 2))
            .animation(.snappy(duration: 0.15), value: hot)
            .accessibilityLabel(hot ? "Release to delete" : "Drag here to delete")
            .allowsHitTesting(false)
    }
}
