import SwiftUI
import SnailSightCore

/// Gear sheet: who this phone is to the server, which server answers, logs and the capture upload queue.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var overrideText = UserDefaults.standard.string(forKey: NetKeys.override) ?? ""
    @AppStorage(CameraTuner.modeKey) private var cameraMode: String = CameraMode.sharp.rawValue
    @State private var liveMapText = UserDefaults.standard.string(forKey: "live.mapID") ?? "site"

    var body: some View {
        NavigationStack {
            Form {
                Section("This phone (agent)") {
                    row("agent_id", model.agentID)
                    row("agent_type", Identity.agentType)
                    row("version", model.version)
                }
                Section {
                    row("active", model.serverBase.map { "\($0) (\(model.serverLabel))" } ?? "offline")
                    row("defaults", "Tailscale \(ServerConfig.tailnet.isEmpty ? "(none)" : ServerConfig.tailnet)\nhome LAN \(ServerConfig.lan.isEmpty ? "(none)" : ServerConfig.lan)")
                    TextField("override, e.g. 192.168.1.10:8904", text: $overrideText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    HStack {
                        Button("Save + re-check") { applyOverride(overrideText) }
                        Spacer()
                        Button("Clear override", role: .destructive) { overrideText = ""; applyOverride("") }
                    }
                } header: { Text("Map server (snailsight)") }
                Section {
                    Picker("Camera", selection: $cameraMode) {
                        ForEach(CameraMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .onChange(of: cameraMode) { _, _ in CameraTuner.shared.apply(reason: "settings") }
                } header: { Text("Camera (recordings + object scans)") } footer: {
                    Text("Sharp: auto exposure never uses a shutter longer than 1/250 s (raises ISO instead), so walking and turning blur far less; white balance is locked for each recording, exposure too for object scans. Slightly grainier in dim rooms. Auto: the phone's normal camera.")
                }
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sim scale")
                            Spacer()
                            Text(SimScale.label(model.simScale)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $model.simScale, in: SimScale.globalRange, step: 0.05)
                    }
                    Picker("Sim quality", selection: $model.simPerf) {
                        ForEach(SimPerfMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Allow sim while recording", isOn: $model.simAllowWhileRecording)
                    Toggle("Shared sim on the map server", isOn: $model.sharedSim)
                    Toggle("Force shared sim (beta)", isOn: $model.forceServerSim)
                    Toggle("X-ray: see sim bodies through walls", isOn: $model.simXRay)
                } header: { Text("Sim (robot, animals, objects in AR)") } footer: {
                    Text("Sim scale shrinks every robot, animal and object together (looks, collisions, paths and speeds); a body can have its own size in its action bar. 100 % = real size. Sim quality Auto eases off shadows, mesh updates and sim rate as iOS reports heat, and pauses only when iOS says critical; Battery saver always runs light. A recording pauses and hides the sim unless allowed here.")
                }
                Section {
                    Toggle("Map mesh", isOn: $model.meshMapOn)
                    Toggle("Auto when localized", isOn: $model.meshMapAuto)
                    if let m = model.meshMapText { Text(m).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Text(model.locPill.text).font(.caption.monospaced()).foregroundStyle(.secondary)
                } header: { Text("Mapping (mesh only)") } footer: {
                    Text("Collects LiDAR depth, a sharp photo every ~0.75 m and ARKit's mesh while you walk — no video, no audio — and sends it to the map server, which re-meshes and re-textures only the areas you covered and publishes a new house-map version. Off at launch; Auto starts it whenever the phone is localized. Pauses while recording, in Scans or when the phone is too hot; everything is saved on the phone first and resent after a Wi-Fi drop.")
                }
                Section {
                    Toggle("Live map", isOn: $model.liveOn)
                    Picker("Rate", selection: $model.liveRateHz) {
                        ForEach(LiveGate.allowedRates, id: \.self) { Text(LiveText.rate($0)).tag($0) }
                    }
                    HStack {
                        Text("map_id").foregroundStyle(.secondary)
                        TextField("site", text: $liveMapText)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .multilineTextAlignment(.trailing).font(.callout.monospaced())
                            .onSubmit { applyLiveMap() }
                            .onDisappear { applyLiveMap() }
                    }
                    if let l = model.liveText { Text(l).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Toggle("Force live downlink (beta)", isOn: $model.forceLiveDownlink)
                } header: { Text("Live map (server)") } footer: {
                    Text("Streams a keyframe (photo + LiDAR depth + pose) 1–2 times a second while you move; nothing while the phone is still, while recording or in Scans. Every keyframe is saved on the phone first and resent after a Wi-Fi drop. map_id applies the next time Live map is turned on. Watch it on the server's /live/ page.")
                }
                Section {
                    Picker("House overlay", selection: $model.houseStyle) {
                        ForEach(HouseStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Raw scan", isOn: $model.rawScan)
                    Toggle("Objects", isOn: $model.arObjects)
                    Toggle("Robot terrain", isOn: $model.arTerrain)
                    Toggle("Other agents", isOn: $model.arAgents)
                    if !model.arStatus.title.isEmpty {
                        Text("\(model.arStatus.title) · \(model.arStatus.detail)").font(.caption).foregroundStyle(.secondary)
                    }
                    let f = model.serverFeatures.list.sorted().joined(separator: ", ")
                    Text("Server features: \(f.isEmpty ? "unknown (offline)" : f)").font(.caption2).foregroundStyle(.secondary)
                } header: { Text("House map in AR (1:1)") } footer: {
                    Text("Once LOCALIZED in the house map, the house near you streams in as tiles (Model = textured, Wire / Ghost = outlines; nothing is downloaded before the lock), with room names and detected objects where they really are; corrections ease in, never jump. Raw scan shows the scanned mesh instead of the cleaned-up walls, floors and furniture. Robot terrain colours the floor green → red for RobosnailBob. Shared sim and live downlink switch on by themselves when the map server offers them; Force tries them anyway.")
                }
                Section("Logs") {
                    Button(model.sendingLog ? "Sending…" : "Send log now") { model.sendLog() }.disabled(model.sendingLog)
                    if let r = model.lastLogResult { Text(r).font(.caption) }
                    if let url = model.logURL { ShareLink(item: url) { Label("Share log file…", systemImage: "square.and.arrow.up") } }
                    Text("Logs upload automatically every 30 s and when the app goes to the background.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if model.uploads.isEmpty { Text("No captures yet. Tap Record.").foregroundStyle(.secondary) }
                    ForEach(Array(model.uploads.reversed())) { it in captureRow(it) }
                    Button("Retry uploads now") {
                        let q = model.queue!
                        Task { await q.retryNow(); await q.kick(reason: "manual") }
                    }
                } header: { Text("Captures") } footer: {
                    Text("Captures upload in ~16 MB parts on a background transfer: they keep going when you leave the app or lock the phone, and resume after Wi-Fi drops or a restart. The newest 3 captures stay on the phone after upload.")
                }
            }
            .navigationTitle("SnailSight")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func applyLiveMap() {
        let t = liveMapText.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = AgentID.isValidName(t) ? t : "site"
        liveMapText = id
        model.liveMapID = id
    }

    private func applyOverride(_ raw: String) {
        let d = UserDefaults.standard
        if let n = ServerConfig.normalise(raw) { d.set(n, forKey: NetKeys.override); overrideText = n }
        else { d.removeObject(forKey: NetKeys.override) }
        let lk = model.link!
        Task { await lk.probe(force: true) }
        model.periodicSync()
    }

    private func captureRow(_ it: UploadItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(it.clientSessionID).font(.subheadline.monospaced())
                Spacer()
                Text(it.state).font(.caption.weight(.semibold)).foregroundStyle(color(it))
            }
            Text(detail(it)).font(.caption).foregroundStyle(.secondary)
            if !it.serverHasAll && it.bytesTotal > 0 { ProgressView(value: it.progress) }
            if let e = it.error { Text(e).font(.caption2).foregroundStyle(.red).lineLimit(3) }
            if it.serverHasAll && !it.localDeleted {
                Button("Delete from phone", role: .destructive) {
                    let q = model.queue!
                    Task { await q.deleteLocal(it.id) }
                }.font(.caption)
            }
        }
    }

    private func detail(_ it: UploadItem) -> String {
        var s = "\(it.frames) frames · \(String(format: "%.0f", Double(it.captureBytes) / 1_048_576)) MB"
        if it.bytesTotal > 0 { s += String(format: " · ↑ %.0f %%", it.progress * 100) }
        if !it.parts.isEmpty { s += " · parts \(it.parts.filter(\.done).count)/\(it.parts.count)" }
        if it.backgroundSafe && !it.serverHasAll { s += " · background ✓" }
        if let d = it.dropped, d > 0 { s += " · \(d) dropped" }
        if let r = it.report { s += "\n\(r)" }
        if let sid = it.sessionID { s += " · \(sid)" }
        if it.localDeleted { s += " · removed from phone" }
        return s
    }

    private func color(_ it: UploadItem) -> Color {
        switch it.state {
        case "processed": return .green
        case "failed": return .red
        case "uploaded", "processing": return .blue
        default: return .orange
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).multilineTextAlignment(.trailing).textSelection(.enabled).font(.callout.monospaced())
        }
    }
}
