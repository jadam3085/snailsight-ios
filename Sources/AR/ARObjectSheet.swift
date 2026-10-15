import SwiftUI
import SnailSightCore

/// 10.1 P4 in AR: correct a detected object you tapped (tool "Objects"): rename what it is (class), give it your own
/// name, or delete a false positive. Same API as the Scans labels (§8.6 PATCH / DELETE, kept across detector re-runs).
struct ARObjectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let edit: ARObjectEdit
    @State private var label: String
    @State private var name: String
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false

    init(edit: ARObjectEdit) {
        self.edit = edit
        _label = State(initialValue: edit.label)
        _name = State(initialValue: edit.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What it is (e.g. chair → stool)", text: $label)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Your name for it (optional, e.g. Mom's chair)", text: $name)
                } header: { Text(edit.manual ? "Your label" : "Detected object — correct it") } footer: {
                    Text("Corrections are kept when the map server re-runs detection and carried into new house-map versions.")
                }
                if let c = edit.confidence, !edit.manual {
                    Section { LabeledContent("Confidence", value: String(format: "%.0f %%", c * 100)) }
                }
                Section {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(edit.manual ? "Delete label" : "Not a \(edit.label): delete", systemImage: "trash")
                    }
                }
                if let e = error { Section { Text(e).foregroundStyle(.red).font(.caption) } }
            }
            .disabled(busy)
            .navigationTitle(edit.name.isEmpty ? edit.label : edit.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Saving…" : "Save") { run(delete: false) }
                        .disabled(busy || label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete \(edit.label)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { run(delete: true) }
            }
        }
    }

    private func run(delete: Bool) {
        busy = true
        error = nil
        let l = label.trimmingCharacters(in: .whitespaces)
        let changedLabel: String? = (l == edit.label || edit.manual) ? nil : l
        let n = name.trimmingCharacters(in: .whitespaces)
        let newName: String? = edit.manual ? (l == edit.label ? nil : l) : (n == edit.name ? nil : n)
        let layer = model.controller.mapLayer
        Task {
            let err = await layer.correct(edit, label: changedLabel, name: newName, delete: delete)
            await MainActor.run {
                busy = false
                if let err { error = err; return }
                model.flash(delete ? "Deleted \(edit.label) from the house map" : "Saved ✓", seconds: 2)
                dismiss()
            }
        }
    }
}
