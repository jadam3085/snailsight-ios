import SwiftUI
import UIKit
import SnailSightCore

/// 9.8 spawn picker (owner: "a lot more options for animals and objects"): a sheet with search, a Recent row and the
/// catalog's groups as a grid of thumbnails (rendered from each model by tools/ilidar_build/build_sim_assets.py; an SF
/// Symbol when a thumbnail is missing). The body lands where the screen's + points.
struct SpawnPickerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var content = SimContentStore.shared          // 12.8: lab characters appear while open
    @State private var query = ""
    @State private var tab: SimCatalogItem.Category = .animal
    private var catalog: SimCatalog { model.controller.sim.catalog }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if query.isEmpty {
                        Picker("Kind", selection: $tab) {
                            Text("Animals").tag(SimCatalogItem.Category.animal)
                            Text("Objects").tag(SimCatalogItem.Category.object)
                        }
                        .pickerStyle(.segmented)
                        recentRow
                        if tab == .animal { robotTile }
                        ForEach(catalog.groups(tab).map { SpawnGroup(name: $0.0, items: $0.1) }) { g in
                            section(g.name, g.items)
                        }
                    } else {
                        let hits = catalog.search(query)
                        if hits.isEmpty {
                            Text("Nothing called “\(query)”").font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.top, 30)
                        } else {
                            section("Results", hits)
                        }
                    }
                    Text("Lands where the + points (objects drop onto tables too). Sim scale \(SimScale.label(model.simScale)) · change it in More ▸ Sim scale.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.bottom, 20)
            }
            .navigationTitle("Spawn")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search animals and objects")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear { content.refresh(reason: "picker") }
        }
    }

    @ViewBuilder private var recentRow: some View {
        let recent = model.simRecents.keys.compactMap { catalog.item($0) }
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(recent) { tile($0) } }
                }
            }
        }
    }

    private var robotTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Robot · Vehicles").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Button {
                pick("robot")
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "car.side.fill").font(.title3).foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.simRobot ? "Move RobosnailBob here" : "RobosnailBob").font(.footnote.weight(.semibold))
                        Text("Drive with the stick · Go to / Follow / Patrol").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            // 12.5 RC car (server catalog `rc_car`, group Vehicles): drive it like the robot
            Button {
                pick(RCCar.key)
            } label: {
                HStack(spacing: 10) {
                    SimThumb(item: model.controller.sim.catalog.item(RCCar.key) ?? RCCar.catalogItem()).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RCCar.label).font(.footnote.weight(.semibold))
                        Text(model.serverSim.isActive ? "1/10 RC car · drive with the stick (Tank toggle) · Go to / Follow"
                                                      : "Needs the shared sim (map server, LOCALIZED)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Spawn RC car")
        }
    }

    /// 10.6 Spawn mode: the pick is remembered, then each floor tap places one (server sim when it is in charge).
    /// Outside Spawn mode (older entry points) it places one at the + right away, as before.
    private func pick(_ key: String) {
        if model.spawnMode {
            model.spawnPick = key
            model.log.event("sim_spawn_pick", ["kind": .string(key)])
        } else if key == RCCar.key {
            if model.serverSim.isActive { model.serverSim.spawn(RCCar.key, arView: model.controller.arView) }
            else { model.flash("The RC car drives in the shared sim: needs the map server and LOCALIZED", seconds: 3) }
        } else if key == "robot" {
            model.controller.sim.spawnRobot()
        } else if let it = model.controller.sim.catalog.item(key) {
            model.controller.sim.spawn(it)
        }
        dismiss()
    }

    private func section(_ title: String, _ items: [SimCatalogItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 8)], spacing: 8) {
                ForEach(items) { tile($0) }
            }
        }
    }

    private func tile(_ it: SimCatalogItem) -> some View {
        Button {
            pick(it.key)
        } label: {
            VStack(spacing: 3) {
                SimThumb(item: it).frame(width: 52, height: 52)
                Text(it.label).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
                Text(sizeText(it)).font(.system(size: 8)).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 76, height: 86)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Spawn \(it.label)")
    }

    /// Size as it will appear (Sim scale applied).
    private func sizeText(_ it: SimCatalogItem) -> String {
        let s = it.size * SimScale.clampGlobal(model.simScale)
        let m = max(s.x, max(s.y, s.z))
        return m < 1 ? String(format: "%.0f cm", m * 100) : String(format: "%.1f m", m)
    }
}

private struct SpawnGroup: Identifiable {
    let name: String
    let items: [SimCatalogItem]
    var id: String { name }
}

/// Bundled thumbnail (Resources/SimThumbs/<key>.png) or the catalog's SF Symbol.
struct SimThumb: View {
    let item: SimCatalogItem
    var body: some View {
        if let name = item.thumb, let img = SimContentStore.shared.localURL(for: name).flatMap({ UIImage(contentsOfFile: $0.path) })
            ?? UIImage(named: (name as NSString).deletingPathExtension) {
            Image(uiImage: img).resizable().scaledToFit()
        } else {
            Image(systemName: item.symbol).font(.title2).foregroundStyle(item.isAnimal ? Color.orange : Color.cyan)
        }
    }
}
