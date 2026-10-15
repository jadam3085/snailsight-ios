// 9.8 Scans labeling UI: label billboards over the 3D view (a 2D overlay projected with the shared camera, so they
// work in Mesh, Splat and Hybrid; dimmed when the mesh hides them), the "label here" sheet (object pin with name,
// kind, notes, optional photo — or the room this point is in), object details / correction (rename, re-class, delete),
// the label list (search, filter, fly to, multi-select merge / delete) and the room details form (name from Home
// Assistant areas or free text, notes, colour).
import SwiftUI
import UIKit
import PhotosUI
import simd
import SnailSightCore

// MARK: billboards

@MainActor
final class LabelOverlayModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: String
        let name: String
        let kind: String
        let category: String?
        let point: CGPoint
        let distance: Float
        let occluded: Bool
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", rooms = "Rooms", objects = "Objects", off = "Off"
        var id: String { rawValue }
    }

    @Published private(set) var items: [Item] = []
    @Published var filter: Filter = .all { didSet { refresh(force: true) } }
    var size: CGSize = .zero { didSet { if size != oldValue { refresh(force: true) } } }
    var labels: [MapLabel] = [] {
        didSet {
            yUp = labels.map(\.yUp)
            occluded = [:]
            lastOcclusion = .distantPast
            refresh(force: true)
        }
    }
    weak var camera: ViewerCamera?
    var triangles: TriangleIndex?

    private var yUp: [SIMD3<Float>] = []
    private var occluded: [String: Bool] = [:]
    private var lastT = Date.distantPast
    private var lastOcclusion = Date.distantPast
    private var trailing = false

    /// Called on every camera change; redraws at most ~30 Hz plus one trailing redraw when the motion stops.
    func refresh(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(lastT) < 1.0 / 30 {
            if !trailing {
                trailing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.trailing = false
                    self?.refresh(force: true)
                }
            }
            return
        }
        lastT = now
        guard let c = camera, filter != .off, size.width > 0, size.height > 0, !labels.isEmpty else {
            if !items.isEmpty { items = [] }
            return
        }
        let idx = labels.indices.filter { i in
            switch filter {
            case .all: return true
            case .rooms: return labels[i].kind == "room"
            case .objects: return labels[i].kind != "room"
            case .off: return false
            }
        }
        let vis = ScreenProjection.visible(idx.map { yUp[$0] }, size: SIMD2(Float(size.width), Float(size.height)),
                                           eye: c.eye, forward: c.forward, fovy: c.fovy, maxDistance: 30, maxCount: 40)
        let checkOcclusion = now.timeIntervalSince(lastOcclusion) > 0.3
        if checkOcclusion { lastOcclusion = now }
        items = vis.map { v in
            let l = labels[idx[v.index]]
            var o = occluded[l.id] ?? false
            if checkOcclusion, let t = triangles {
                let d = yUp[idx[v.index]] - c.eye
                let dist = simd_length(d)
                o = dist > 0.4 && t.raycast(origin: c.eye, dir: d, maxT: dist - 0.3) != nil
                occluded[l.id] = o
            }
            return Item(id: l.id, name: l.name, kind: l.kind, category: l.category,
                        point: CGPoint(x: CGFloat(v.screen.x), y: CGFloat(v.screen.y)), distance: v.distance, occluded: o)
        }
    }
}

enum LabelStyle {
    static func color(_ category: String?) -> Color {
        switch category {
        case "furniture": return .orange
        case "fixture": return .teal
        case "appliance": return .pink
        case "movable": return .yellow
        default: return .mint
        }
    }
    static func icon(_ category: String?) -> String {
        switch category {
        case "furniture": return "sofa.fill"
        case "fixture": return "lightbulb.fill"
        case "appliance": return "washer.fill"
        case "movable": return "shippingbox.fill"
        default: return "mappin"
        }
    }
}

struct LabelOverlay: View {
    @ObservedObject var model: LabelOverlayModel
    let onTap: (String) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.items) { it in
                Button { onTap(it.id) } label: { chip(it) }
                    .buttonStyle(.plain)
                    .position(it.point)
                    .opacity(it.occluded ? 0.4 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func chip(_ it: LabelOverlayModel.Item) -> some View {
        let small = it.distance > 8
        if it.kind == "room" {
            Text(it.name)
                .font(small ? .caption2.weight(.bold) : .caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.7), lineWidth: 1))
                .foregroundStyle(.white)
        } else {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: LabelStyle.icon(it.category)).font(.caption2)
                    Text(it.name).font(small ? .caption2.weight(.semibold) : .caption.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(LabelStyle.color(it.category).opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.black)
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)).foregroundStyle(LabelStyle.color(it.category))
            }
            .offset(y: -12)
        }
    }
}

// MARK: label here

/// A tap on the scan in Label mode: the mesh hit in both frames and the room it is in.
struct LabelTarget: Identifiable {
    let id = UUID()
    let yUp: SIMD3<Float>
    let map: SIMD3<Double>
    let room: RoomRecord?
}

struct NewLabelSheet: View {
    @ObservedObject var labels: ScanLabelStore
    let target: LabelTarget
    let onDrawRoom: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category = ObjectCategory.other
    @State private var notes = ""
    @State private var photo: UIImage?
    @State private var showCamera = false
    @State private var pick: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Router, Spare keys)", text: $name)
                    Picker("Kind", selection: $category) {
                        ForEach(ObjectCategory.allCases, id: \.self) { c in
                            Label(c.rawValue.capitalized, systemImage: LabelStyle.icon(c.rawValue)).tag(c)
                        }
                    }
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
                    PhotoRow(photo: $photo, showCamera: $showCamera, pick: $pick)
                } header: { Text("Pin a label here") }
                Section {
                    if let r = target.room {
                        NavigationLink {
                            RoomDetailsForm(room: r, areas: labels.areas, rooms: labels.rooms.rooms) { nr in
                                Task { await labels.upsertRoom(nr) }
                            }
                        } label: {
                            Label("In \(r.name) — rename / HA area", systemImage: "square.dashed")
                        }
                    } else {
                        Text("This spot is not inside a drawn room yet.").font(.callout).foregroundStyle(.secondary)
                        Button {
                            dismiss()
                            onDrawRoom()
                        } label: { Label("Draw a room around here", systemImage: "pencil.and.outline") }
                    }
                } header: { Text("Room") }
                Section {
                    Text(String(format: "Map frame x %.2f  y %.2f  z %.2f m", target.map.x, target.map.y, target.map.z))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || labels.saving)
                }
            }
        }
        .sheet(isPresented: $showCamera) { CameraPicker { photo = $0 }.ignoresSafeArea() }
        .onChange(of: pick) { _, it in loadPick(it) { photo = $0 } }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let id = ObjectEdits.newID(labels.objects.objects)
        let thumb = photo.flatMap { labels.savePhoto($0, for: id) }
        let o = ObjectEdits.newLabel(id: id, name: n, category: category, notes: notes, at: target.map,
                                     roomID: target.room?.id, haAreaID: target.room?.haAreaID, photoThumbBase64: thumb,
                                     by: labels.author, now: Date().timeIntervalSince1970)
        Task {
            if await labels.addLabel(o) { dismiss() }
        }
    }
}

/// Photo: take one or pick from the library; shows the current one.
struct PhotoRow: View {
    @Binding var photo: UIImage?
    @Binding var showCamera: Bool
    @Binding var pick: PhotosPickerItem?

    var body: some View {
        if let p = photo {
            HStack {
                Image(uiImage: p).resizable().scaledToFit().frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 8))
                Spacer()
                Button("Remove", role: .destructive) { photo = nil }
            }
        }
        HStack {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Take photo", systemImage: "camera") }.buttonStyle(.borderless)
            }
            Spacer()
            PhotosPicker(selection: $pick, matching: .images) { Label("Library", systemImage: "photo") }.buttonStyle(.borderless)
        }
    }
}

func loadPick(_ it: PhotosPickerItem?, _ done: @escaping @MainActor (UIImage) -> Void) {
    guard let it else { return }
    Task {
        if let d = try? await it.loadTransferable(type: Data.self), let img = UIImage(data: d) {
            await MainActor.run { done(img) }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: object details / corrections

struct LabelDetailSheet: View {
    @ObservedObject var labels: ScanLabelStore
    let object: SceneObject
    let onFly: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var cls: String
    @State private var category: ObjectCategory
    @State private var notes: String
    @State private var confirmDelete = false

    init(labels: ScanLabelStore, object: SceneObject, onFly: @escaping () -> Void) {
        self.labels = labels
        self.object = object
        self.onFly = onFly
        _name = State(initialValue: object.isManual ? object.displayName : (object.name ?? ""))
        _cls = State(initialValue: object.label)
        _category = State(initialValue: ObjectCategory(rawValue: object.category) ?? .other)
        _notes = State(initialValue: object.notes)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let img = labels.photo(for: object) {
                    Section { Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 220) }
                }
                Section {
                    TextField(object.isManual ? "Name" : "Your name for it (optional, e.g. Mom's chair)", text: $name)
                    if !object.isManual {
                        TextField("Class (e.g. chair → stool)", text: $cls)
                        if let d = object.detLabel, d != object.label {
                            Text("Detector said: \(d)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Picker("Kind", selection: $category) {
                        ForEach(ObjectCategory.allCases, id: \.self) { c in Text(c.rawValue.capitalized).tag(c) }
                    }
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
                } header: { Text(object.isManual ? "Your label" : "Detected object — correct it") }
                Section {
                    LabeledContent("Source", value: object.isManual ? "label from a phone" : (object.source ?? "detector"))
                    if let r = object.roomID, let room = labels.rooms.rooms.first(where: { $0.id == r }) {
                        LabeledContent("Room", value: room.name)
                    }
                    if !object.isManual, let c = object.confidence {
                        LabeledContent("Confidence", value: String(format: "%.0f %%", c * 100))
                    }
                    if let n = object.observations, n > 1 { LabeledContent("Seen", value: "\(n) times") }
                }
                Section {
                    Button { dismiss(); onFly() } label: { Label("Fly to it", systemImage: "scope") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .navigationTitle(object.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled((object.isManual ? name : cls).trimmingCharacters(in: .whitespaces).isEmpty || labels.saving)
                }
            }
            .confirmationDialog("Delete \(object.displayName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
            }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces), k = cls.trimmingCharacters(in: .whitespaces)
        Task {
            let ok = await labels.editObject(object, name: n, label: object.isManual ? nil : k, category: category, note: notes)
            if ok { dismiss() }
        }
    }

    private func delete() {
        Task { if await labels.deleteObjects([object.id]) { dismiss() } }
    }
}

// MARK: list

struct LabelListView: View {
    @ObservedObject var labels: ScanLabelStore
    let onFlyObject: (SceneObject) -> Void
    let onFlyRoom: (RoomRecord) -> Void
    let onEditRooms: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var source = LabelSearch.Source.all
    @State private var category: ObjectCategory?
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var editing: SceneObject?
    @State private var confirmMerge = false
    @State private var confirmDelete = false

    private var shown: [SceneObject] {
        LabelSearch.filter(labels.objects.objects, query: query, category: category, source: source, rooms: labels.rooms.rooms)
    }
    private var rooms: [RoomRecord] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return labels.rooms.rooms.filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var mergeTarget: SceneObject? {
        labels.objects.objects.filter { selection.contains($0.id) }.max { ($0.observations ?? 1) < ($1.observations ?? 1) }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if let e = labels.error { Section { Text(e).font(.callout).foregroundStyle(.orange) } }
                if source == .all && category == nil && !selecting {
                    Section {
                        ForEach(rooms) { r in
                            Button { dismiss(); onFlyRoom(r) } label: {
                                HStack {
                                    Circle().fill(Color(hex: r.color)).frame(width: 10, height: 10)
                                    Text(r.name)
                                    Spacer()
                                    if r.haAreaID != nil { Text("HA").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                                    if let a = r.areaM2 { Text(String(format: "%.1f m²", a)).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        Button { dismiss(); onEditRooms() } label: { Label("Draw / edit rooms on the floor plan", systemImage: "pencil.and.outline") }
                    } header: { Text("Rooms (\(labels.rooms.rooms.count))") }
                }
                Section {
                    ForEach(shown) { o in
                        row(o).tag(o.id)
                    }
                } header: {
                    Text("Objects (\(shown.count))")
                } footer: {
                    Text(labels.correctionsAPI
                         ? "Renames, deletes and merges go through the server's object corrections, so they survive new detection runs."
                         : "Renames, deletes and merges are saved in the objects list (the detector's corrections API is not live on this server yet).")
                }
            }
            .environment(\.editMode, .constant(selecting ? .active : .inactive))
            .searchable(text: $query, prompt: "Search labels and rooms")
            .navigationTitle("Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(selecting ? "Done" : "Select") { selecting.toggle(); selection.removeAll() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if selecting {
                        Button("Merge (\(selection.count))") { confirmMerge = true }.disabled(selection.count < 2 || labels.saving)
                        Spacer()
                        Button("Delete (\(selection.count))", role: .destructive) { confirmDelete = true }.disabled(selection.isEmpty || labels.saving)
                    } else {
                        Picker("Show", selection: $source) {
                            ForEach(LabelSearch.Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Menu {
                            Button("All kinds") { category = nil }
                            ForEach(ObjectCategory.allCases, id: \.self) { c in Button(c.rawValue.capitalized) { category = c } }
                        } label: { Image(systemName: category == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
                    }
                }
            }
            .confirmationDialog("Merge \(selection.count) objects into “\(mergeTarget?.displayName ?? "")”?", isPresented: $confirmMerge,
                                titleVisibility: .visible) {
                Button("Merge") { merge() }
            } message: { Text("For duplicates of one thing: one object remains, with a box around all of them.") }
            .confirmationDialog("Delete \(selection.count) labels?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
            }
            .sheet(item: $editing) { o in
                LabelDetailSheet(labels: labels, object: o) { dismiss(); onFlyObject(o) }
            }
        }
    }

    private func row(_ o: SceneObject) -> some View {
        HStack(spacing: 10) {
            Image(systemName: LabelStyle.icon(o.category)).foregroundStyle(LabelStyle.color(o.category)).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(o.displayName).font(.body)
                Text([o.name != nil && !o.isManual ? o.label : nil, o.category, o.roomID.flatMap { id in labels.rooms.rooms.first { $0.id == id }?.name },
                      o.isManual ? "mine" : "detected", o.notes.isEmpty ? nil : o.notes].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !selecting {
                Button { dismiss(); onFlyObject(o) } label: { Image(systemName: "scope") }.buttonStyle(.borderless)
                Button { editing = o } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
            }
        }
    }

    private func merge() {
        guard let t = mergeTarget else { return }
        let ids = Array(selection)
        Task {
            if await labels.mergeObjects(ids, into: t.id) {
                selection.removeAll()
                selecting = false
            }
        }
    }

    private func deleteSelected() {
        let ids = Array(selection)
        Task {
            if await labels.deleteObjects(ids) {
                selection.removeAll()
                selecting = false
            }
        }
    }
}

// MARK: room details

struct RoomDetailsForm: View {
    @State private var room: RoomRecord
    let areas: [HAArea]
    let rooms: [RoomRecord]
    let onSave: (RoomRecord) -> Void
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(room: RoomRecord, areas: [HAArea], rooms: [RoomRecord], onDelete: (() -> Void)? = nil,
         onSave: @escaping (RoomRecord) -> Void) {
        _room = State(initialValue: room)
        self.areas = areas
        self.rooms = rooms
        self.onDelete = onDelete
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Name") { TextField("Room name", text: $room.name) }
            Section {
                if areas.isEmpty {
                    Text("Home Assistant areas are not available right now — type a name above.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button { room.haAreaID = nil } label: {
                    HStack { Text("No HA area"); Spacer(); if room.haAreaID == nil { Image(systemName: "checkmark") } }
                }
                ForEach(HAArea.suggestions(areas, rooms: rooms, editing: room.id)) { a in
                    Button {
                        room.haAreaID = a.areaID
                        room.name = a.name
                    } label: {
                        HStack {
                            Text(a.name)
                            if let f = a.floor, !f.isEmpty { Text(f).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if rooms.contains(where: { $0.id != room.id && $0.haAreaID == a.areaID }) {
                                Text("used").font(.caption2).foregroundStyle(.secondary)
                            }
                            if room.haAreaID == a.areaID { Image(systemName: "checkmark") }
                        }
                    }
                }
            } header: { Text("Home Assistant area") } footer: { Text("Read from Home Assistant; nothing is written back to it.") }
            Section("Notes") {
                TextField("Notes", text: Binding(get: { room.notes ?? "" }, set: { room.notes = $0 }), axis: .vertical).lineLimit(1...4)
            }
            Section("Colour") {
                HStack {
                    ForEach(RoomsDoc.palette, id: \.self) { c in
                        Circle().fill(Color(hex: c)).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(.white, lineWidth: room.color == c ? 3 : 0))
                            .onTapGesture { room.color = c }
                    }
                }
            }
            if let onDelete {
                Section { Button("Delete room", role: .destructive) { onDelete(); dismiss() } }
            }
        }
        .navigationTitle(room.name.isEmpty ? "Room" : room.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(room); dismiss() }.disabled(room.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
