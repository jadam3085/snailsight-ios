// 10.7: the house map the AR view follows (newest READY version) on top, older versions as "History" (plan M1).
// 9.6 Scans screen (owner 2026-10-13: "see scans through the app, not just through the web portal"): whole-house map
// versions (latest `site` first), walks and object scans from the map server (`GET /v1/phone/scans`, same Tailscale /
// LAN server as everything else), with thumbnails. Opening one shows ScanViewerView. The main AR session is paused
// while this screen is up (one AR session at a time; the dollhouse runs its own) and resumes on close.
import SwiftUI
import SnailSightCore

struct ScansView: View {
    @ObservedObject var store: ScanStore               // 10.7: shared with the background prefetch (AppModel)
    /// 10.7: the house map version the AR view follows (newest READY); the rest of the list is history.
    let followRev: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var open: ScanItem?

    init(store: ScanStore, followRev: Int?) {
        _store = ObservedObject(wrappedValue: store)
        self.followRev = followRev
    }

    var body: some View {
        NavigationStack {
            List {
                if let e = store.error {
                    Section { Label(e, systemImage: "wifi.slash").font(.callout).foregroundStyle(.orange) }
                }
                if let last = store.lastViewedID, store.isCached(last), let it = store.cached[last]?.item {
                    Section("Last viewed (saved on this phone)") { row(it) }
                }
                ForEach(ScanCatalog.sections(store.items, followRev: followRev), id: \.title) { sec in
                    Section {
                        ForEach(sec.items) { it in row(it) }
                    } header: {
                        Text(sec.title)
                    } footer: {
                        if sec.title == ScanCatalog.followTitle {
                            Text("Nothing to pick: the AR view loads the newest ready house map by itself and swaps in a newer one when you pause. Open it here only to look at it as a model.")
                        } else if sec.title == ScanCatalog.historyTitle {
                            Text("Older versions, for looking back. A version still being built shows \"preparing\" and is not used anywhere until it is ready.")
                        }
                    }
                }
                if store.items.isEmpty && !store.loading && store.error == nil {
                    Section { Text("No scans yet. Record a room or an object, and they appear here once the map server has built them.")
                        .foregroundStyle(.secondary) }
                }
                Section {
                    HStack {
                        Text("Saved on this phone: \(ScanCatalog.bytesText(store.cacheBytes).isEmpty ? "nothing" : ScanCatalog.bytesText(store.cacheBytes))")
                        Spacer()
                        Button("Clear", role: .destructive) { store.clearCache() }.disabled(store.cacheBytes == 0)
                    }
                    .font(.footnote)
                } footer: {
                    Text("The last scan you opened stays on the phone for offline viewing; older ones are removed above 600 MB.")
                }
            }
            .overlay { if store.loading && store.items.isEmpty { ProgressView("Asking the map server…") } }
            .refreshable { await store.refresh() }
            .navigationTitle("Scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .task { await store.refresh() }
        .fullScreenCover(item: $open) { it in
            ScanViewerView(item: it, store: store, log: AppServices.shared.log)
        }
    }

    private func row(_ it: ScanItem) -> some View {
        Button { open = it } label: {
            HStack(spacing: 12) {
                thumb(it)
                VStack(alignment: .leading, spacing: 3) {
                    Text(it.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                    if let s = it.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    HStack(spacing: 6) {
                        badge(meshBadge(it), meshColor(it))
                        if it.splat != nil { badge("splat", .purple) }
                        if store.isCached(it.id) { badge("saved", .green) }
                        if it.mapID == "site", let v = it.version, v == followRev { badge("in AR", .teal) }
                        if let c = it.created { Text(Date(timeIntervalSince1970: c), style: .date).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .disabled(store.offline && !store.isCached(it.id))
        .onAppear { store.thumb(for: it) }
    }

    private func thumb(_ it: ScanItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.15))
            if let img = store.thumbs[it.id] {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: it.type == .object ? "cube" : "house").foregroundStyle(.secondary)
            }
        }
        .frame(width: 84, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func meshBadge(_ it: ScanItem) -> String {
        guard let m = it.mesh else { return "no mesh" }
        switch m.state {
        case "ready": return "mesh " + ScanCatalog.bytesText(m.bytes)
        case "queued", "building": return "mesh: preparing"
        case "failed": return "mesh failed"
        default: return "mesh on demand"
        }
    }

    private func meshColor(_ it: ScanItem) -> Color {
        switch it.mesh?.state {
        case "ready": return .blue
        case "failed": return .red
        default: return .gray
        }
    }

    private func badge(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(c.opacity(0.25), in: Capsule()).foregroundStyle(c)
    }
}
