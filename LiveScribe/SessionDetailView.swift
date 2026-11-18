import SwiftUI
import UIKit

struct SessionDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let sessionID: UUID

    @State private var session: TranscriptSession?
    @State private var title = ""
    @State private var text = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var copied = false
    @State private var confirmDelete = false
    @State private var deleted = false
    @FocusState private var editing: Bool

    var body: some View {
        Group {
            if session != nil {
                editor
            } else {
                Text("This transcript is no longer available.")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: text) {
                    Image(systemName: "square.and.arrow.up")
                }
                Menu {
                    Button {
                        text = text
                            .components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                        scheduleSave()
                    } label: {
                        Label("Merge lines into one paragraph", systemImage: "text.alignleft")
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = false }
            }
        }
        .confirmationDialog("Delete this transcript?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleted = true
                saveTask?.cancel()
                model.delete(ids: [sessionID])
                dismiss()
            }
        }
        .onAppear(perform: load)
        .onDisappear { saveNow() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: Binding(get: { title }, set: { title = $0; scheduleSave() }))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            Text(metaLine)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 3)
                .padding(.bottom, 10)
            Divider()
            TextEditor(text: Binding(get: { text }, set: { text = $0; scheduleSave() }))
                .focused($editing)
                .font(.body)
                .padding(.horizontal, 11)
                .scrollDismissesKeyboard(.interactively)
        }
    }

    private var metaLine: String {
        guard let session = session else { return "" }
        let date = session.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(session.source.label) · \(session.language.label) · \(date) · \(text.count) chars"
    }

    private func load() {
        guard session == nil, let loaded = model.session(id: sessionID) else { return }
        session = loaded
        title = loaded.title
        text = loaded.text
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { saveNow() }
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        guard !deleted, var current = session else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = cleanTitle.isEmpty ? current.title : cleanTitle
        guard current.text != text || current.title != newTitle else { return }
        current.text = text
        current.title = newTitle
        session = current
        model.update(current)
    }
}
