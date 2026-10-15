import SwiftUI

/// On-screen thumb stick for the sim robot: output (x right, y up) in the unit disc; releases to zero.
/// Shaping (deadzone, expo) and the robot's real limits are applied in SnailSightCore (StickShaper, DiffDrive).
struct JoystickView: View {
    var size: CGFloat = 136
    var onChange: (SIMD2<Double>) -> Void
    @State private var knob: CGSize = .zero

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.35))
                .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 2))
            Image(systemName: "arrow.up").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                .offset(y: -size * 0.38)
            Circle().fill(Color.white.opacity(0.9)).frame(width: size * 0.42, height: size * 0.42)
                .shadow(radius: 3).offset(knob)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let r = size / 2
                    var v = CGSize(width: g.location.x - r, height: g.location.y - r)
                    let len = (v.width * v.width + v.height * v.height).squareRoot()
                    if len > r { v = CGSize(width: v.width * r / len, height: v.height * r / len) }
                    knob = v
                    onChange(SIMD2(Double(v.width / r), Double(-v.height / r)))
                }
                .onEnded { _ in
                    knob = .zero
                    onChange(.zero)
                }
        )
        .accessibilityLabel("Robot joystick")
    }
}
