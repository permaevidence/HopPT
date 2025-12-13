import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var showingCreate = false
    @State private var draftForCreate = EndpointConfig()
    @State private var showingDeleteAllAlert = false
    @ObservedObject private var whisper = ModelDownloadManager.shared
    
    let viewModel: ChatViewModel

    var body: some View {
        Form {
            endpointsSection
            webSearchSection
            voiceInputSection
            ttsSection
            dangerZoneSection  // Add this new section
                    }
                    #if os(iOS)
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
                    #endif
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .sheet(isPresented: $showingCreate) {
                        NavigationStack {
                            EndpointDetailView(
                                draft: draftForCreate,
                                onSave: { endpoint in
                                    settings.upsertEndpoint(endpoint)
                                }
                            )
                            .environmentObject(settings)
                            .navigationTitle("New Endpoint")
                            .navigationBarTitleDisplayMode(.inline)
                        }
                        .presentationDetents([.large])
                    }
                    .alert("Delete All Conversations?", isPresented: $showingDeleteAllAlert) {
                        Button("Cancel", role: .cancel) { }
                        Button("Delete All", role: .destructive) {
                            viewModel.deleteAllConversations()
                        }
                    } message: {
                        Text("This will permanently delete all conversations and messages. This action cannot be undone.")
                    }
                    .task {
                        await whisper.checkModelStatus()
                    }
                }

    // MARK: - Sections

    @ViewBuilder
    private var endpointsSection: some View {
        Section {
            if settings.endpoints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No endpoints saved.")
                        .foregroundStyle(.secondary)
                    Button {
                        draftForCreate = EndpointConfig()
                        showingCreate = true
                    } label: {
                        Label("Add Endpoint", systemImage: "plus.circle.fill")
                    }
                }
            } else {
                ForEach($settings.endpoints) { $endpoint in
                    NavigationLink {
                        EndpointDetailView(
                            draft: endpoint,
                            onSave: { edited in settings.upsertEndpoint(edited) }
                        )
                        .environmentObject(settings)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(endpoint.name.isEmpty ? (URL(string: endpoint.apiBase)?.host ?? "Endpoint")
                                                           : endpoint.name)
                                    .font(.headline)
                                Text(endpoint.apiBase)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if settings.activeEndpointID == endpoint.id {
                                Text("Active").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            settings.deleteEndpoint(endpoint)
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }

                Button {
                    draftForCreate = EndpointConfig()
                    showingCreate = true
                } label: {
                    Label("Add Endpoint", systemImage: "plus")
                }
            }
        } header: {
            Text("Endpoints")
        }
    }

    @ViewBuilder
    private var webSearchSection: some View {
        Section {
            // 1) Search key first (used only for SERP)
            SecretField("serper.dev API Key", text: $settings.serperApiKey)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            
            Text(
              "Web Search uses serper.dev. Insert your API Key. They offer a generous free tier package. This is required if you want to use Web Search."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            // 2) Scraping mode selector
            Picker("Scraping Mode", selection: $settings.scrapingMode) {
                ForEach(ScrapingMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            // 3) Jina key only when Jina Reader is selected
            if settings.scrapingMode == .serperAPI { // ← rename to your case if needed
                SecretField("Jina Reader API Key", text: $settings.jinaApiKey)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
            }

            Text(
              "For higher quality scrapings go to jina.ai and get an API Key. Responses might take longer, though."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text("Search & Scraping")
        }
        // Smoothly show/hide the Jina field when the selection changes
        .animation(.default, value: settings.scrapingMode)
    }
    
    @ViewBuilder
    private var voiceInputSection: some View {
        Section {
            // Status row
            HStack {
                Label("Status", systemImage: "waveform.circle")
                Spacer()
                Text(whisper.statusMessage)
                    .foregroundStyle(.secondary)
            }

            // Download progress (if any)
            if whisper.isDownloading {
                ProgressView(value: Double(whisper.downloadProgress))
                    .progressViewStyle(.linear)
                Text("Downloading… \(Int(whisper.downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Actions based on state
            if !whisper.hasModelOnDisk {
                Button {
                    Task { await whisper.startDownload() }
                } label: {
                    Label("Download Whisper model (≈600 MB)", systemImage: "arrow.down.circle.fill")
                }
            } else if !whisper.isCompiled || !whisper.isModelReady {
                Button {
                    Task { await whisper.loadModel() }
                } label: {
                    Label("Compile model", systemImage: "cpu")
                }
                Text("Compilation happens once (and after app updates). Keep the app open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Model ready. The microphone appears in the composer.")
                }
                .font(.callout)

                Button(role: .destructive) {
                    do { try whisper.deleteModelFromDisk() }
                    catch { print("[Whisper] delete error:", error.localizedDescription) }
                } label: {
                    Label("Remove model from device", systemImage: "trash")
                }
            }
        } header: {
            Text("Voice Input (whisper-large-v3-turbo)")
        } footer: {
            Text("Runs entirely on-device with WhisperKit. First compile can take a few minutes depending on device.")
        }
    }
    
    @ViewBuilder
        private var dangerZoneSection: some View {
            Section {
                Button(role: .destructive) {
                    showingDeleteAllAlert = true
                } label: {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("Delete All Conversations")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Permanently removes all conversations and messages from this device.")
            }
        }
    
    @ViewBuilder
       private var ttsSection: some View {
           Section {
               Toggle("Enable Voice Only mode", isOn: $settings.ttsEnabled)
           } header: {
               Text("Voice Mode")
           } footer: {
               Text("This will work only if the transcription model is compiled.")
           }
       }
}

struct SecretField: View {
    let title: String
    @Binding var text: String
    @State private var reveal = false

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if reveal {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textContentType(.password)
            .textFieldStyle(.roundedBorder)

            Button {
                reveal.toggle()
            } label: {
                Image(systemName: reveal ? "eye.slash" : "eye")
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reveal ? "Hide" : "Show")
        }
    }
}
