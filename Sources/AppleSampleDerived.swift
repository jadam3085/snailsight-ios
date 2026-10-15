/*
Derived from Apple's sample code "Visualizing and Interacting with a Reconstructed Scene"
(https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene).
Copyright © 2026 Apple Inc. See LICENSE-Apple-sample.txt (MIT-style) for this sample's licensing information.
Originals, unmodified: upstream/apple-reconstructed-scene/ (Extensions.swift, ViewController.swift,
ViewController+CoachingOverlay.swift). Changes: SwiftUI host instead of a storyboard; vertex/normal readers return
SIMD3; coaching overlay and the session-failure alert are attached to our ARSessionController; P2a: Start Over while
relocalizing starts a new place.
*/

import ARKit
import RealityKit
import UIKit

extension ARMeshGeometry {
    /// From the sample's `vertex(at:)`: read one float3 vertex straight from the Metal buffer.
    func vertex(at index: UInt32) -> SIMD3<Float> {
        assert(vertices.format == MTLVertexFormat.float3, "Expected three floats (twelve bytes) per vertex.")
        let p = vertices.buffer.contents().advanced(by: vertices.offset + (vertices.stride * Int(index)))
        let v = p.assumingMemoryBound(to: (Float, Float, Float).self).pointee
        return SIMD3(v.0, v.1, v.2)
    }

    /// Same pattern for the per-vertex normals.
    func normal(at index: UInt32) -> SIMD3<Float> {
        let p = normals.buffer.contents().advanced(by: normals.offset + (normals.stride * Int(index)))
        let v = p.assumingMemoryBound(to: (Float, Float, Float).self).pointee
        return SIMD3(v.0, v.1, v.2)
    }
}

extension ARSessionController: ARCoachingOverlayViewDelegate {
    /// From the sample's `setupCoachingOverlay()`: Apple's standard "move your phone" onboarding, full screen.
    func setupCoachingOverlay(on arView: ARView) {
        let coachingOverlay = ARCoachingOverlayView()
        coachingOverlay.session = arView.session
        coachingOverlay.delegate = self
        coachingOverlay.goal = .tracking
        coachingOverlay.activatesAutomatically = true
        coachingOverlay.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(coachingOverlay)
        NSLayoutConstraint.activate([
            coachingOverlay.centerXAnchor.constraint(equalTo: arView.centerXAnchor),
            coachingOverlay.centerYAnchor.constraint(equalTo: arView.centerYAnchor),
            coachingOverlay.widthAnchor.constraint(equalTo: arView.widthAnchor),
            coachingOverlay.heightAnchor.constraint(equalTo: arView.heightAnchor),
        ])
    }

    func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        // P2a: "Start Over" during relocalization = give up on the saved places and start a new one
        if model.placeCtl.tracker.isRelocalizing { model.placeCtl.startNew() } else { resetSession() }
    }

    /// From the sample's `session(_:didFailWithError:)`: description + reason + recovery suggestion.
    func describe(_ error: Error) -> String {
        let e = error as NSError
        return [e.localizedDescription, e.localizedFailureReason, e.localizedRecoverySuggestion]
            .compactMap { $0 }.joined(separator: "\n")
    }

    /// From the sample: alert with a "Restart Session" action.
    func presentFailureAlert(_ message: String, restart: @escaping () -> Void) {
        guard let root = arView.window?.rootViewController else { return }
        let alert = UIAlertController(title: "The AR session failed.", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Restart Session", style: .default) { _ in restart() })
        var top = root
        while let p = top.presentedViewController { top = p }
        top.present(alert, animated: true)
    }
}
