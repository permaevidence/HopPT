import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct EndpointDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    @State var draft: EndpointConfig
    var onSave: (EndpointConfig) -> Void

    init(draft: EndpointConfig, onSave: @escaping (EndpointConfig) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        List {
            Section("Endpoint") {
                TextField("Name (e.g., LM Studio, OpenRouter)", text: $draft.name)
                    .textFieldStyle(.roundedBorder)

                TextField("Base URL...)", text: $draft.apiBase)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)

                SecretField("API Key (optional for local)", text: $draft.apiKey)
                    .font(.system(.body, design: .monospaced))
            }

            modelsSection
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        // Auto-save on every change to draft (name, apiBase, apiKey, selectedModels, preferredModel)
        .onChange(of: draft) { newValue in
            onSave(newValue)
        }
    }

    private var modelsSection: some View {
        Section("Models") {
            // Current selection summary
            if draft.selectedModels.isEmpty {
                Text("No models selected yet. Tap **Manage Models…** to browse, or add manually below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(draft.selectedModels, id: \.self) { id in
                    HStack {
                        Text(id)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            draft.selectedModels.removeAll { $0 == id }
                            if draft.preferredModel == id { draft.preferredModel = draft.selectedModels.first }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let pref = draft.preferredModel, !pref.isEmpty {
                    Text("Preferred: \(pref)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("\(draft.selectedModels.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            NavigationLink {
                ModelBrowserView(endpoint: $draft)
            } label: {
                Label("Manage Models…", systemImage: "list.bullet")
            }

            ManualAddModelsEditor(models: $draft.selectedModels, showSelectedList: false)
        }
    }
}
