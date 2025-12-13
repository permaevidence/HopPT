import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct ModelBrowserView: View {
    @Binding var endpoint: EndpointConfig
    @EnvironmentObject private var settings: AppSettings  // ADD THIS

    @State private var searchText = ""
    @State private var allModels: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var filteredModels: [String] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allModels }
        return allModels.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading models…")
                }
            } else if let err = errorMessage {
                Label {
                    Text(err).font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.secondary)
                Button("Retry") { Task { await loadModels() } }
            } else if allModels.isEmpty {
                Section {
                    Text("Server didn't expose /models (OpenAI-compatible) or /api/tags (Ollama), or returned an empty list.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ManualAddModelsEditor(models: $endpoint.selectedModels, showSelectedList: false)
                }
            } else {
                Section {
                    ForEach(filteredModels, id: \.self) { id in
                        Button {
                            toggleSelection(id)
                        } label: {
                            HStack {
                                Text(id)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Image(systemName: endpoint.selectedModels.contains(id) ? "checkmark.circle.fill" : "circle")
                                    .imageScale(.medium)
                                    .foregroundStyle(endpoint.selectedModels.contains(id) ? Color.accentColor : Color.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Manage Models")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear All") { endpoint.selectedModels.removeAll() }
                .disabled(endpoint.selectedModels.isEmpty)
            }
        }
        .task { await loadModels() }
        .task(id: endpoint.apiBase) { await loadModels() }
        .task(id: endpoint.apiKey)  { await loadModels() }
        // ADD THIS: Auto-save on every model selection/deselection
        .onChange(of: endpoint) { newValue in
            settings.upsertEndpoint(newValue)
        }
    }

    @MainActor
    private func loadModels() async {
        isLoading = true
        errorMessage = nil
        allModels = []

        do {
            let client = ModelListClient(apiBase: endpoint.apiBase, apiKey: endpoint.apiKey)
            let models = try await client.fetchModels()
            allModels = models.sorted()

            if endpoint.preferredModel == nil || !(models.contains(endpoint.preferredModel!)) {
                endpoint.preferredModel = endpoint.selectedModels.first ?? models.first
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func toggleSelection(_ id: String) {
        if let idx = endpoint.selectedModels.firstIndex(of: id) {
            endpoint.selectedModels.remove(at: idx)
            if endpoint.preferredModel == id {
                endpoint.preferredModel = endpoint.selectedModels.first
            }
        } else {
            endpoint.selectedModels.append(id)
            if endpoint.preferredModel == nil { endpoint.preferredModel = id }
        }
    }
}

struct ManualAddModelsEditor: View {
    @Binding var models: [String]
    @State private var customModel = ""
    var showSelectedList: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("e.g., qwen2.5:7b-instruct", text: $customModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                Button("Add") {
                    let m = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !m.isEmpty else { return }
                    if !models.contains(m) { models.append(m) }
                    customModel = ""
                }
                .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if showSelectedList, !models.isEmpty {
                ForEach(models, id: \.self) { id in
                    HStack {
                        Text(id)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            models.removeAll { $0 == id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
