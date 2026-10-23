import SwiftUI
import SnailSightCore

// 10.6: ONE selection / command bar for the local sim and the shared server sim (SimBarView). The two adapters below
// only translate their state into a SimBarModel and route the actions; the command list comes from ONE Core function
// (SimCommand.offered), so the server bar can no longer lose its commands (10.5.213: tapping a server animal gave no
// options) and there is one status chip, not two.

struct SimBarExtra: Equatable, Identifiable {
    var id: String
    var symbol: String
    var label: String
}

/// What the bar shows for the selected body.
struct SimBarModel: Equatable {
    var title: String
    var detail: String
    var symbol: String
    var commands: [SimCommand]
    var extras: [SimBarExtra] = []
    var scale: String?                  // local bodies: their own scale (−/+); nil = no scale control
    var scaleIsOverride = false
}

enum SimBarAction: Equatable {
    case command(SimCommand)
    case extra(String)
    case scale(up: Bool?)
    case cancel
    case start
}

struct SimBarView: View {
    var prompt: String?
    var pending: SimCommand?
    var patrolPoints = 0
    var selection: SimBarModel?
    var hint: String
    var scaleRef: Binding<Bool>?
    let act: (SimBarAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let p = prompt { promptRow(p) }
            if let s = selection { selected(s) } else { idleHint }
        }
        .animation(.snappy(duration: 0.18), value: selection?.title)
    }

    private func promptRow(_ p: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap.fill").foregroundStyle(.cyan)
            Text(p).font(.caption.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if pending == .patrol {
                Button("Start") { act(.start) }.font(.caption.weight(.bold)).disabled(patrolPoints < 2)
            }
            Button { act(.cancel) } label: { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// The ONE status chip (mode + hint).
    private var idleHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap").font(.caption2)
            Text(hint).font(.caption2).lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func selected(_ s: SimBarModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: s.symbol).font(.caption).foregroundStyle(.cyan).frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.title).font(.caption.weight(.bold)).lineLimit(1)
                    Text(s.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                }
                Spacer(minLength: 4)
                if let sc = s.scale { scaleControl(sc, override: s.scaleIsOverride) }
                if let r = scaleRef {
                    Toggle(isOn: r) { Image(systemName: "ruler") }
                        .toggleStyle(.button).buttonStyle(.bordered).controlSize(.mini)
                        .accessibilityLabel("Show a 1 metre scale reference")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(s.commands, id: \.self) { c in
                        chip(c.symbol, c.label, active: pending == c, danger: c == .delete) { act(.command(c)) }
                    }
                    ForEach(s.extras) { x in chip(x.symbol, x.label, active: false, danger: false) { act(.extra(x.id)) } }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: 440)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.cyan.opacity(0.35)))
    }

    private func chip(_ symbol: String, _ label: String, active: Bool, danger: Bool,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(label).font(.system(size: 8, weight: .medium)).lineLimit(1)
            }
            .frame(minWidth: 40, minHeight: 34)
            .padding(.horizontal, 3)
            .background(active ? Color.cyan.opacity(0.45) : danger ? Color.red.opacity(0.15) : Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(danger ? Color.red : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// − 50 % + : this body's own scale; the % in cyan = its own override (tap it: back to the global Sim scale).
    private func scaleControl(_ text: String, override: Bool) -> some View {
        HStack(spacing: 0) {
            Button { act(.scale(up: false)) } label: { Image(systemName: "minus").frame(width: 24, height: 24) }
                .accessibilityLabel("Smaller")
            Button { act(.scale(up: nil)) } label: {
                Text(text).font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(override ? Color.cyan : Color.primary)
                    .frame(minWidth: 38)
            }
            .disabled(!override)
            .accessibilityLabel(override ? "Use the global Sim scale" : "Scale")
            Button { act(.scale(up: true)) } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                .accessibilityLabel("Bigger")
        }
        .font(.caption.weight(.bold))
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

/// The local (S1) sim's adapter.
struct SimActionBar: View {
    @ObservedObject var ui: SimUI
    let sim: SimController
    var status = ""

    var body: some View {
        SimBarView(prompt: ui.prompt, pending: ui.pending, patrolPoints: ui.patrolPoints,
                   selection: ui.selection.map { s in
                       SimBarModel(title: s.title, detail: s.detail, symbol: s.symbol,
                                   commands: SimCommand.offered(role: s.kind.role, server: false),
                                   scale: SimScale.label(s.scale), scaleIsOverride: s.scaleIsOverride)
                   },
                   hint: [status, "Tap a body to command it · flick an animal to kick it"].filter { !$0.isEmpty }
                       .joined(separator: " · "),
                   scaleRef: $ui.scaleRef) { a in
            switch a {
            case .command(let c): sim.command(c)
            case .scale(let up): sim.adjustSelectedScale(up: up)
            case .cancel: sim.cancelPending()
            case .start: sim.startPatrol()
            case .extra: break
            }
        }
    }
}

/// 12.9: "Models updating…" while the content store downloads changed sim models in the background (non-blocking;
/// hides itself when done). Shown on the Sim HUD and in the spawn picker.
struct ModelsUpdatingPill: View {
    @ObservedObject private var content = SimContentStore.shared

    var body: some View {
        if let u = content.updating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(u.total > 0 ? "Models updating… \(u.done)/\(u.total)" : "Models updating…")
                    .font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityLabel("Sim models updating, \(u.done) of \(u.total)")
            .allowsHitTesting(false)
        }
    }
}
