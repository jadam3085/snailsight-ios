import SwiftUI
import SnailSightCore

/// P2a "Places" sheet: the saved places (one ARWorldMap each, with their animals), load one (relocalize), start a new
/// one, rename (free text or a Home Assistant area name from the map server), delete.
struct PlacesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var renameText = ""
    @State private var areas: [String] = []

    private var ctl: PlaceController { model.placeCtl }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.place.title).font(.headline)
                    Text(model.place.detail).font(.caption).foregroundStyle(.secondary)
                    Button { ctl.saveNow(); dismiss() } label: { Label("Save place now", systemImage: "square.and.arrow.down") }
                        .disabled(model.place.relocalizing)
                    Button { ctl.startNew(); dismiss() } label: { Label("Start new place here", systemImage: "plus.square.dashed") }
                } header: { Text("Now") } footer: {
                    Text("A place is one saved AR map: a floor or a group of rooms you walk between. Walking into a new room grows the current place; Save place (or leaving the app) keeps it. Use a new place for another floor or the yard.")
                }
                if let id = ctl.activeID, model.places.contains(where: { $0.id == id }) {
                    Section("Name this place") {
                        TextField("e.g. Basement", text: $renameText).textInputAutocapitalization(.words)
                        Button("Rename") { ctl.rename(id, to: renameText); renameText = "" }
                            .disabled(PlaceNaming.clean(renameText) == nil)
                        if !areas.isEmpty {
                            Menu {
                                ForEach(areas, id: \.self) { a in Button(a) { ctl.rename(id, to: a) } }
                            } label: { Label("Use a Home Assistant area name", systemImage: "house") }
                        }
                    }
                }
                Section {
                    if model.places.isEmpty {
                        Text("No saved places yet: spawn an animal, then Save place.").foregroundStyle(.secondary)
                    }
                    ForEach(model.places, id: \.id) { p in row(p) }
                        .onDelete { idx in for i in idx { ctl.delete(model.places[i].id) } }
                } header: { Text("Saved places") } footer: {
                    Text("Tap one to load it: the app re-runs AR with that map and relocalizes when you look at the same area. Places are also kept on the map server, so they survive a reinstall.")
                }
            }
            .navigationTitle("Places")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await loadAreas() }
        }
    }

    private func row(_ p: PlaceManifest) -> some View {
        Button {
            ctl.pick(p.id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(p.name).font(.body.weight(.semibold))
                    if p.id == ctl.activeID || p.id == ctl.tracker.current {
                        Text(ctl.tracker.isRelocalizing ? "trying" : "here").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.green.opacity(0.3), in: Capsule())
                    }
                    Spacer()
                    Text(String(format: "%.1f MB", Double(p.mapBytes) / 1_048_576)).font(.caption).monospacedDigit()
                }
                Text(detail(p)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .foregroundStyle(.primary)
    }

    private func detail(_ p: PlaceManifest) -> String {
        let kinds = Dictionary(grouping: p.entities, by: { $0.kind }).map { "\($0.value.count) \($0.key)" }.sorted()
        var s = kinds.isEmpty ? "no animals" : kinds.joined(separator: ", ")
        s += " · used " + RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: p.lastUsed), relativeTo: Date())
        if let t = p.lastLocalizeSeconds { s += String(format: " · last lock %.1f s", t) }
        if p.failStreak > 0 { s += " · \(p.failStreak) miss\(p.failStreak == 1 ? "" : "es")" }
        s += p.needsUpload ? " · not on the map server yet" : " · on the map server"
        return s
    }

    /// Home Assistant area names via the snailsight server (read-only, `/v1/ha/areas`); empty when offline.
    private func loadAreas() async {
        guard let r = try? await model.link.request("GET", "/v1/ha/areas", timeout: 8), r.1 == 200,
              let o = (try? JSONSerialization.jsonObject(with: r.0)) as? [String: Any],
              let list = o["areas"] as? [[String: Any]] else { return }
        areas = list.compactMap { $0["name"] as? String }
    }
}
