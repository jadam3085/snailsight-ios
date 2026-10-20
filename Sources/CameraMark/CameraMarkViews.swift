// SnailSight 12.2 Mark camera + Camera check: the picker (camera / sensor placements or a new one), the point-at
// overlay (crosshair, guidance, Mark · Undo · Locate · Accept) and the Camera check panel. 44 pt targets, VoiceOver
// labels on every control.
import SwiftUI
import SnailSightCore

// MARK: picker

struct CameraMarkPicker: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var mark: CameraMarkController
    @ObservedObject var data: MapPlanData
    @State private var query = ""
    @State private var newKind = "camera"
    @State private var newName = ""
    @State private var newSource = "frigate:"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pick the camera or sensor, then aim the crosshair at the real one and tap Mark. Mark again from a spot about 2 m to the side; two marks 10° apart locate it, even on the roofline.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("On the map") {
                    if data.cameras.isEmpty {
                        Text(model.serverBase == nil ? "Map server offline" : "Loading cameras and sensors…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { p in
                        Button { mark.start(placement: p) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: p.kind == "camera" ? "video" : "sensor")
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title).font(.subheadline.weight(.semibold))
                                    Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let d = distance(p) { Text(NearList.distanceText(d)).font(.caption).foregroundStyle(.secondary) }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Mark \(p.title), \(p.subtitle)")
                    }
                }
                Section("New camera or sensor") {
                    Picker("Kind", selection: $newKind) {
                        Text("Camera").tag("camera")
                        Text("Sensor").tag("sensor")
                    }
                    .pickerStyle(.segmented)
                    .frame(minHeight: 44)
                    TextField("Name (e.g. Roof east)", text: $newName)
                        .frame(minHeight: 44)
                        .accessibilityLabel("New name")
                    TextField("Source: frigate:<cam>, ring:<cam>, ha:<entity>", text: $newSource)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .frame(minHeight: 44)
                        .accessibilityLabel("Source")
                    Button {
                        mark.start(MarkTarget(id: nil, kind: newKind, name: newName.trimmingCharacters(in: .whitespaces),
                                              source: newSource.trimmingCharacters(in: .whitespaces), current: nil,
                                              level: nil))
                    } label: { Label("Mark the new one", systemImage: "scope") }
                    .frame(minHeight: 44)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || !MarkWire.validSource(newSource))
                }
            }
            .searchable(text: $query, prompt: "Find a camera or sensor")
            .navigationTitle("Mark camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { mark.showPicker = false }.frame(minWidth: 44, minHeight: 44)
                }
            }
            .onAppear { data.ensureCameras() }
        }
    }

    private var filtered: [Placement] {
        let list = data.cameras.sorted { (distance($0) ?? 1e9, $0.title) < (distance($1) ?? 1e9, $1.title) }
        guard !query.isEmpty else { return list }
        let q = query.lowercased()
        return list.filter { $0.title.lowercased().contains(q) || ($0.record?.source ?? "").lowercased().contains(q) }
    }

    private func distance(_ p: Placement) -> Double? {
        guard let me = mark.meMap else { return nil }
        return hypot(p.pose.x - me[0], p.pose.y - me[1])
    }
}

// MARK: point-at overlay

struct CameraMarkOverlay: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var mark: CameraMarkController

    var body: some View {
        ZStack {
            if mark.active {
                crosshair
                VStack(spacing: 8) {
                    banner.padding(.top, 54)
                    Spacer()
                    controls.padding(.bottom, 26)
                }
                .padding(.horizontal, 12)
            }
        }
        .sheet(isPresented: $mark.showPicker) {
            CameraMarkPicker(mark: mark, data: model.planData).environmentObject(model)
                .presentationDetents([.medium, .large])
        }
    }

    private var crosshair: some View {
        GeometryReader { g in
            ZStack {
                Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5).frame(width: 34, height: 34)
                Rectangle().fill(Color.white).frame(width: 1.5, height: 54)
                Rectangle().fill(Color.white).frame(width: 54, height: 1.5)
                Circle().fill(Color.red).frame(width: 4, height: 4)
            }
            .shadow(color: .black.opacity(0.8), radius: 1.5)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var banner: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let g = mark.guide
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "scope")
                    Text(mark.target?.title ?? "").font(.headline).lineLimit(1)
                    Spacer()
                    Text(mark.lock.title).font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(lockColor.opacity(0.3), in: Capsule())
                }
                Text(mark.note ?? g.text)
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if !mark.rays.isEmpty {
                    Text(String(format: "%d mark%@ · %.0f° apart", mark.rays.count, mark.rays.count == 1 ? "" : "s", g.spreadDeg))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private var lockColor: Color {
        switch mark.lock { case .strong: return .green; case .good: return .mint; case .weak: return .orange; case .none: return .red }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if mark.result != nil {
                HStack(spacing: 10) {
                    button("Accept", "checkmark.circle.fill", prominent: true, label: "Accept the located position") { mark.accept() }
                        .disabled(mark.busy)
                    button("Mark more", "plus.viewfinder", label: "Discard this result and mark more") { mark.undoResult() }
                }
            } else {
                HStack(spacing: 10) {
                    button("Undo", "arrow.uturn.backward", label: "Undo the last mark") { mark.undo() }
                        .disabled(mark.rays.isEmpty)
                    Button { mark.mark() } label: {
                        ZStack {
                            Circle().fill(Color.white).frame(width: 72, height: 72)
                            Image(systemName: "scope").font(.system(size: 28, weight: .bold)).foregroundStyle(.black)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: 76, height: 76)
                    .accessibilityLabel("Mark")
                    .accessibilityHint("Records where the crosshair points")
                    button("Locate", "location.viewfinder", prominent: mark.guide.phase == .ready,
                           label: "Locate from the marks") { mark.locate() }
                        .disabled(mark.busy || mark.rays.count < 2)
                }
                if mark.lidarHit != nil {
                    button("Use LiDAR point", "dot.scope", label: "Use the LiDAR point under the crosshair") { mark.useLidarHit() }
                }
            }
            button("Close", "xmark", label: "Close Mark camera") { mark.close() }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func button(_ title: String, _ symbol: String, prominent: Bool = false, label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(prominent ? Color.accentColor : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: Camera check panel

struct CameraCheckPanel: View {
    @ObservedObject var check: CameraCheck

    var body: some View {
        if check.on {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "video.badge.checkmark")
                    Text(check.line).font(.caption.weight(.semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    Button { check.on = false } label: { Image(systemName: "xmark.circle.fill") }
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Stop camera check")
                }
                ForEach(check.rows.prefix(4)) { r in
                    HStack(spacing: 6) {
                        Image(systemName: r.sawMe ? "eye.fill" : "eye").foregroundStyle(r.sawMe ? .green : .secondary)
                        Text(r.title).font(.caption).lineLimit(1)
                        if r.sawMe { Text("saw you").font(.caption2.weight(.bold)).foregroundStyle(.green) }
                        Spacer()
                        if let s = r.score { Text(String(format: "%.0f %%", s * 100)).font(.caption2).monospacedDigit() }
                        if r.calibrated { Image(systemName: "checkmark.seal").font(.caption2) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(r.title) sees you\(r.sawMe ? ", and detected you" : "")")
                }
            }
            .padding(.leading, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
