import SwiftUI
import RealityKit

/// Hosts the controller's single, long-lived ARView (created once; SwiftUI re-renders never rebuild it).
struct ARViewContainer: UIViewRepresentable {
    let controller: ARSessionController
    func makeUIView(context: Context) -> ARView { controller.arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
