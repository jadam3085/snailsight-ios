// SnailSight 12.25 snailCOP mode screen + the launch mode chooser.
// snailCOP = the cop.snail portal full screen (CopController's WKWebView) with one native pill at the top left (switch to
// AR explore, reload, address, ask at launch). Offline / no Tailscale / stack off = a clear card with Retry (and Turn on).
import SwiftUI
import WebKit
import SnailSightCore

struct CopModeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var cop: CopController

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(red: 0.05, green: 0.07, blue: 0.09).ignoresSafeArea()
                CopWebHost(cop: cop)
                    .ignoresSafeArea()
                    .opacity(cop.phase == .ready ? 1 : 0.001)              // keep it laid out while it boots
                if cop.phase != .ready { CopStatusCard(cop: cop).frame(maxWidth: .infinity, maxHeight: .infinity) }
                CopModePill(cop: cop)                                     // inside the safe area: over the bar's reserved left
                    .padding(.leading, 8)
                    .padding(.top, 4)
                if let t = model.toast {
                    Text(t).font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity).padding(.top, 48)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { cop.setInsets(geo.safeAreaInsets) }
            .onChange(of: geo.safeAreaInsets) { _, e in cop.setInsets(e) }
        }
        .sheet(isPresented: Binding(get: { cop.shareItems != nil }, set: { if !$0 { cop.shareItems = nil } })) {
            ActivityView(items: cop.shareItems ?? []).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $model.showCopAddress) { CopAddressSheet().environmentObject(model) }
    }
}

/// The controller's long-lived web view (SwiftUI re-renders never rebuild it).
private struct CopWebHost: UIViewRepresentable {
    let cop: CopController
    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = .clear
        attach(to: box)
        return box
    }
    func updateUIView(_ box: UIView, context: Context) { attach(to: box) }
    private func attach(to box: UIView) {
        let w = cop.hostView
        guard w.superview !== box else { return }
        w.removeFromSuperview()
        w.frame = box.bounds
        w.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.addSubview(w)
    }
}

/// Top-left: "snailCOP ▾" — the way back to AR explore and the few native settings.
private struct CopModePill: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var cop: CopController

    var body: some View {
        Menu {
            // 12.26 one tap: AR + find your position + Live map + status line
            Button { model.walker.start(cause: "cop_pill") } label: { Label("Start walk", systemImage: "figure.walk") }
            Button { model.setMode(.ar, cause: "cop_pill") } label: { Label("AR explore (camera)", systemImage: "arkit") }
            Button { cop.reload() } label: { Label("Reload snailCOP", systemImage: "arrow.clockwise") }
            Button { model.showCopAddress = true } label: { Label("snailCOP address…", systemImage: "network") }
            Toggle(isOn: $model.askModeAtLaunch) { Label("Ask at launch", systemImage: "questionmark.circle") }
            Button { model.sendLog() } label: { Label("Send log", systemImage: "paperplane") }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "scope").font(.system(size: 13, weight: .bold))
                Text("snailCOP").font(.system(size: 14, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).frame(height: 34)
            .background(Color(red: 0.09, green: 0.11, blue: 0.13).opacity(0.92), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.15)))
        }
        .accessibilityLabel("snailCOP mode menu")
        .accessibilityHint("Switch to AR explore, reload, or set the snailCOP address")
    }
}

/// Finding the portal / why it can't be reached, with Retry (and Turn on when the gate answered).
private struct CopStatusCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var cop: CopController

    var body: some View {
        VStack(spacing: 14) {
            if cop.phase == .problem, let r = cop.reach {
                Image(systemName: icon(r.kind)).font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(r.kind == .off ? .orange : .white.opacity(0.85))
                Text(r.title).font(.title3.weight(.bold))
                Text(r.detail).font(.callout).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75))
                if r.kind == .waking { ProgressView().tint(.white) }
                HStack(spacing: 10) {
                    if r.canTurnOn {
                        Button { cop.turnOn() } label: { Text(cop.turningOn ? "Turning on…" : "Turn on").frame(minWidth: 110) }
                            .buttonStyle(.borderedProminent).tint(.green).disabled(cop.turningOn)
                    }
                    Button { cop.retry() } label: { Text("Retry").frame(minWidth: 90) }.buttonStyle(.bordered).tint(.white)
                }
                Button("Use AR explore instead") { model.setMode(.ar, cause: "cop_unreachable") }
                    .font(.footnote).tint(.white.opacity(0.8)).padding(.top, 4)
                Button("Set the snailCOP address") { model.showCopAddress = true }.font(.footnote).tint(.white.opacity(0.6))
            } else {
                ProgressView().tint(.white).scaleEffect(1.3)
                Text(cop.phase == .loading ? "Opening snailCOP…" : "Finding snailCOP…").font(.headline)
                Text("No camera and no localizing: this is the operational picture only.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 360)
        .background(Color(red: 0.09, green: 0.11, blue: 0.13), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1)))
        .padding(20)
    }

    private func icon(_ k: CopReach.Kind) -> String {
        switch k {
        case .off: return "power"
        case .waking: return "bolt.fill"
        case .noNetwork: return "wifi.slash"
        case .noTailnet: return "lock.shield"
        case .unreachable, .ready: return "exclamationmark.triangle"
        }
    }
}

/// Settings: the snailCOP address override (empty = automatic).
struct CopAddressSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = UserDefaults.standard.string(forKey: CopPortal.overrideKey) ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("automatic", text: $text).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("snailCOP address") } footer: {
                    Text("Empty = automatic: the map server's host on port \(CopPortal.portalPort), then \(CopPortal.stableName). Use the https address for the Quest-style secure page if you need motion sensors.")
                }
            }
            .navigationTitle("snailCOP")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let v = ServerConfig.normalise(text)
                        UserDefaults.standard.set(v, forKey: CopPortal.overrideKey)
                        UserDefaults.standard.removeObject(forKey: CopPortal.lastGoodKey)
                        model.log.event("cop_address", ["set": .bool(v != nil)])
                        model.cop.probe(why: "address")
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - launch chooser

struct ModeChooserView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.07, blue: 0.09).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("SnailSight").font(.largeTitle.weight(.bold))
                Text("What do you want to open?").font(.callout).foregroundStyle(.white.opacity(0.65))
                Button { model.walker.start(cause: "chooser") } label: {      // 12.26 one-tap walk
                    HStack(spacing: 12) {
                        Image(systemName: "figure.walk").font(.system(size: 26, weight: .semibold)).frame(width: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Start walk").font(.title3.weight(.bold))
                            Text("Camera + LiDAR: finds you, streams your walk to the shared map, then the server improves it.")
                                .font(.footnote).foregroundStyle(.black.opacity(0.7)).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start walk")
                card(.cop, icon: "scope", title: "snailCOP",
                     text: "The whole picture: cameras, alerts, sensors, sim and robots in the 3D world. No camera, no localizing.")
                card(.ar, icon: "arkit", title: "AR explore",
                     text: "Camera + LiDAR: find yourself in the house map, Live map, record, drive in AR.")
                Toggle("Ask every time I open the app", isOn: $model.askModeAtLaunch)
                    .font(.footnote).tint(.green).padding(.horizontal, 6).padding(.top, 6)
                Text("You can switch any time: the snailCOP pill (top left) or the scope button in AR.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(maxWidth: 440)
        }
    }

    private func card(_ m: AppMode, icon: String, title: String, text: String) -> some View {
        Button { model.setMode(m, cause: "chooser") } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 28, weight: .semibold)).frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title).font(.title3.weight(.bold))
                        if model.rememberedMode == m { Text("last used").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.white.opacity(0.15), in: Capsule()) }
                    }
                    Text(text).font(.footnote).foregroundStyle(.white.opacity(0.72)).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.11, green: 0.14, blue: 0.17), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(text)")
    }
}
