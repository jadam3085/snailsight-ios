// SnailSight 9 — P0 "world-locked AR" + P1 capture/log upload to the snailsight service (docs/SNAILSIGHT-REFACTOR-PLAN.md §7);
// 9.1.60: captures upload on a background URLSession (BackgroundTransfer.swift).
// AR core derived from Apple's "Visualizing and Interacting with a Reconstructed Scene" sample
// (LICENSE-Apple-sample.txt; original files in upstream/apple-reconstructed-scene/).
import SwiftUI

@main
struct SnailSightApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate     // background URLSession events
    @StateObject private var model = AppModel()

    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            ARViewContainer(controller: model.controller)
                .ignoresSafeArea()
            if model.simOn && !model.recording {               // sim spawn reticle: Spawn lands where this points
                Image(systemName: "plus").font(.title3.weight(.light)).foregroundStyle(.white.opacity(0.8))
                    .shadow(radius: 2).allowsHitTesting(false)
            }
            DriveOrHUD(drive: model.drive.ui, mark: model.cameraMark)   // 12.7: drive mode replaces ring + HUD
            CameraMarkOverlay(mark: model.cameraMark)           // 12.2 Mark camera: crosshair + Mark / Locate / Accept
            if model.simOn && model.simDragging {                // 10.6: drop a dragged body here to delete it
                VStack { Spacer(); SimTrashCan(hot: model.simDragHot).padding(.bottom, 44) }
                    .frame(maxWidth: .infinity).allowsHitTesting(false)
            }
            ObjectScanOverlay(scan: model.objectScan)          // 9.3 object scan: chooser, AR box panel, Object Capture
        }
        .sheet(isPresented: $model.showSettings) { SettingsView().environmentObject(model) }
        .sheet(isPresented: $model.showLayers) {                            // 12.0 layers button
            LayersSheet().environmentObject(model).presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $model.showMap) {                    // 12.0 Map (A2 / O1)
            MapPlanView(data: model.planData, mesh: model.meshStore, serverUI: model.serverSim.ui).environmentObject(model)
        }
        .fullScreenCover(isPresented: $model.showDriveViewer) {           // 12.7 drive FPV / Chase (AR paused)
            ZStack {
                DriveViewerView(model: model, data: model.planData, ui: model.drive.ui)
                DriveModeView(ui: model.drive.ui, shared: model.serverSim.ui)
            }
            .environmentObject(model)
            .statusBarHidden(true)
        }
        .sheet(isPresented: $model.showPlaces) { PlacesView().environmentObject(model) }   // P2a places
        .sheet(isPresented: $model.showSpawn) {                             // 9.8 spawn picker
            SpawnPickerView().environmentObject(model).presentationDetents([.medium, .large])
        }
        .sheet(item: $model.arObjectEdit) { e in                            // 10.1 AR: correct a detected object
            ARObjectSheet(edit: e).environmentObject(model).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $model.showCubes) {                             // 9.9 cubes list (swipe to delete)
            CubeListView().environmentObject(model).presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $model.showScans) {                  // 9.6 native scan viewer (Sources/Scans)
            ScansView(store: model.sharedScanStore(), followRev: model.mapFollower.followVersion)
        }
        .onAppear {
            model.controller.start()
            model.startNetworking()
            UIApplication.shared.isIdleTimerDisabled = true   // as in Apple's sample: never dim mid-AR
        }
    }
}

/// 12.7 drive mode (strip + twin sticks only) or the normal HUD (12.0 B2 ring + sheet).
private struct DriveOrHUD: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var drive: DriveUI
    let mark: CameraMarkController

    var body: some View {
        if drive.active {
            DriveModeView(ui: drive, shared: model.serverSim.ui)
        } else {
            CommandRingOverlay(server: model.serverSim.ui, local: model.controller.sim.ui)
            HUDView(mark: mark)
        }
    }
}
