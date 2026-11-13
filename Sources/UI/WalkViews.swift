// SnailSight 12.26 one-tap walk HUD: the walk bar (one status line + detail + the problem in plain words + at most one
// gentle capture hint + Stop) and the summary card after Stop. Driven by WalkController (Sources/Live).
import SwiftUI
import SnailSightCore

/// Bottom of the AR HUD while a walk runs or its summary is up.
struct WalkHUD: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var walker: WalkController

    var body: some View {
        if let s = walker.summary {
            WalkSummaryCard(walker: walker, summary: s)
        } else if walker.active, let l = walker.line {
            WalkBar(walker: walker, line: l)
        }
    }
}

private struct WalkBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var walker: WalkController
    let line: WalkLine

    private var dot: Color {
        switch line.tone {
        case .good: return .green
        case .working: return .orange
        case .problem: return .red
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            if let h = walker.hint, walker.hintsOn {
                HStack(spacing: 6) {
                    Image(systemName: h.symbol).font(.caption2.weight(.bold))
                    Text(h.text).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    Button { walker.hintsOn = false; model.flash("Walk hints off: Mapping ▸ Walk hints turns them back on", seconds: 3) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).padding(3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Turn walk hints off")
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
            HStack(alignment: .center, spacing: 10) {
                Button { walker.expanded.toggle() } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(dot).frame(width: 9, height: 9).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.title).font(.footnote.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                            if let p = line.problem {
                                Text(p).font(.caption2.weight(.semibold)).foregroundStyle(.orange).lineLimit(2)
                            } else if let d = line.detail {
                                Text(d).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                            }
                            if walker.expanded {
                                if let l = model.liveText { Text(l).font(.caption2).monospacedDigit().lineLimit(2) }
                                if let st = model.liveStagesDetail ?? model.liveStagesText {
                                    Text(st).font(.caption2).monospacedDigit().lineLimit(4).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Walk: \(line.title). \(line.problem ?? line.detail ?? "")")
                .accessibilityHint("Shows the live map details")
                Button { walker.stop(cause: "owner_tap") } label: {
                    Text("Stop").font(.footnote.weight(.bold)).padding(.horizontal, 12).frame(height: 32)
                        .background(Color.red.opacity(0.9), in: Capsule()).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop walk")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(dot.opacity(0.35)))
        }
        .frame(maxWidth: 440)
        .animation(.easeInOut(duration: 0.25), value: walker.hint)
    }
}

private struct WalkSummaryCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var walker: WalkController
    let summary: WalkSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "figure.walk").font(.headline)
                Text("Walk done").font(.headline)
                Spacer()
            }
            ForEach(Array(summary.lines.enumerated()), id: \.offset) { _, l in
                Text(l).font(.footnote).monospacedDigit()
            }
            Text(summary.next).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Done") { walker.dismissSummary() }.buttonStyle(.borderedProminent)
                Button("Walk again") { walker.dismissSummary(); walker.start(cause: "summary_again") }.buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button { walker.dismissSummary(); model.setMode(.cop, cause: "walk_summary") } label: {
                    Label("snailCOP", systemImage: "scope")
                }
                .buttonStyle(.bordered)
                .disabled(summary.queueLeft > 0)
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: 440, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
