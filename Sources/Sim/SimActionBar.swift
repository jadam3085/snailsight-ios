import SwiftUI
import SnailSightCore

/// 9.8 floating action bar for the selected sim body (replaces the 9.4 command bar): what it is, its size and task,
/// its own scale (−/+, tap the % to go back to the global Sim scale), its commands as small icon buttons, and the
/// pending "tap the floor" prompt. Observes SimUI directly (no AppModel churn).
struct SimActionBar: View {
    @ObservedObject var ui: SimUI
    let sim: SimController

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let p = ui.prompt { promptRow(p) }
            if let s = ui.selection { selected(s) } else { idleHint }
        }
        .animation(.snappy(duration: 0.18), value: ui.selection?.id)
    }

    private func promptRow(_ p: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap.fill").foregroundStyle(.cyan)
            Text(p).font(.caption.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if ui.pending == .patrol {
                Button("Start") { sim.startPatrol() }
                    .font(.caption.weight(.bold)).disabled(ui.patrolPoints < 2)
            }
            Button { sim.cancelPending() } label: { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var idleHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap").font(.caption2)
            Text("Tap a body to command it · flick an animal to kick it · long-press a cube to delete").font(.caption2).lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func selected(_ s: SimSelection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: s.symbol).font(.caption).foregroundStyle(.cyan).frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.title).font(.caption.weight(.bold)).lineLimit(1)
                    Text(s.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                }
                Spacer(minLength: 4)
                scaleControl(s)
                Toggle(isOn: $ui.scaleRef) { Image(systemName: "ruler") }
                    .toggleStyle(.button).buttonStyle(.bordered).controlSize(.mini)
                    .accessibilityLabel("Show a 1 metre scale reference")
                if s.kind.isObject {                 // 9.9: one tap deletes an object (Undo for 5 s)
                    Button { sim.deleteSelected() } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(Color.red.opacity(0.8), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete \(s.title)")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(SimCommand.available(for: s.kind), id: \.self) { c in
                        Button { sim.command(c) } label: {
                            VStack(spacing: 1) {
                                Image(systemName: c.symbol).font(.system(size: 14, weight: .semibold))
                                Text(c.label).font(.system(size: 8, weight: .medium)).lineLimit(1)
                            }
                            .frame(minWidth: 40, minHeight: 34)
                            .padding(.horizontal, 3)
                            .background(background(c), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .foregroundStyle(c == .delete ? Color.red : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.label)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: 440)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.cyan.opacity(0.35)))
    }

    private func background(_ c: SimCommand) -> Color {
        if ui.pending == c { return Color.cyan.opacity(0.45) }
        return c == .delete ? Color.red.opacity(0.15) : Color.primary.opacity(0.08)
    }

    /// − 50 % + : this body's own scale; the % in cyan = its own override (tap it: back to the global Sim scale).
    private func scaleControl(_ s: SimSelection) -> some View {
        HStack(spacing: 0) {
            Button { sim.adjustSelectedScale(up: false) } label: { Image(systemName: "minus").frame(width: 24, height: 24) }
                .accessibilityLabel("Smaller")
            Button { sim.adjustSelectedScale(up: nil) } label: {
                Text(SimScale.label(s.scale)).font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(s.scaleIsOverride ? Color.cyan : Color.primary)
                    .frame(minWidth: 38)
            }
            .disabled(!s.scaleIsOverride)
            .accessibilityLabel(s.scaleIsOverride ? "Use the global Sim scale" : "Scale")
            Button { sim.adjustSelectedScale(up: true) } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                .accessibilityLabel("Bigger")
        }
        .font(.caption.weight(.bold))
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }
}
