import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers
import Combine

struct ComposerBar: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState var isInputFocused: Bool
    @EnvironmentObject private var settings: AppSettings

    // Whisper
    @ObservedObject private var whisper = ModelDownloadManager.shared
    @StateObject private var transcriber = WhisperTranscriber()

    // Attachments UI state (kept for classic mode)
    @State private var showAttachMenu = false
    @State private var showPhotosPicker = false
    @State private var showPDFImporter = false
    @State private var pickedPhotoItem: PhotosPickerItem?

    private var canSend: Bool {
        let hasText = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !viewModel.pendingAttachments.isEmpty
        return !viewModel.isLoading && (hasText || hasAttachments) && settings.isChatConfigured
    }

    // Voice‑first UI is tied to the “Read replies aloud” setting
    private var isVoiceFirstMode: Bool { settings.ttsEnabled }

    var body: some View {
        VStack(spacing: 10) {
            // In voice-first mode we REMOVE the text field
            if !isVoiceFirstMode {
                messageField
            }

            // In voice-first mode we REMOVE the attachments strip
            if !isVoiceFirstMode {
                attachmentsStrip
            }

            if isVoiceFirstMode {
                controlsRowVoiceFirst
            } else {
                controlsRowClassic
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            if !isVoiceFirstMode {
                Text("≈ \(pendingTokenCount.formatted()) tokens")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)

        // Voice transcript plumbing
        .onReceive(transcriber.$latestTranscript.compactMap { $0 }) { transcript in
            // Keep mirroring what Whisper heard into the buffer
            // (even in voice-first mode; we just don't show the text field)
            let hadFocus = isInputFocused
            viewModel.inputText = transcript
            isInputFocused = hadFocus
        }
        .onChange(of: transcriber.isRecording, perform: handleRecordingChange)

        // Auto-send after transcription finishes (voice-first mode only)
        .onChange(of: transcriber.isTranscribing) { isTranscribing in
            guard isVoiceFirstMode else { return }
            if !isTranscribing {
                autoSendAfterTranscriptionIfNeeded()
            }
        }

        // Pickers remain for classic mode
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $pickedPhotoItem,
            matching: .images,
            preferredItemEncoding: .automatic
        )
        .fileImporter(
            isPresented: $showPDFImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            onCompletion: handlePDFImport
        )
        .onChange(of: pickedPhotoItem, perform: handlePhotoChange)
    }

    // MARK: - Classic controls row (unchanged behavior)
    @ViewBuilder
    private var controlsRowClassic: some View {
        HStack(spacing: 10) {

            // Attachments
            Button { showAttachMenu = true } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
                    .foregroundStyle(.secondary)
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    .accessibilityLabel("Add attachment")
            }
            .buttonStyle(.plain)
            .confirmationDialog("Add Attachment", isPresented: $showAttachMenu, titleVisibility: .visible) {
                Button("Photo from Library") { showPhotosPicker = true }
                Button("PDF from Files") { showPDFImporter = true }
                Button("Cancel", role: .cancel) { }
            }

            // Globe toggle
            globeButton

            Spacer(minLength: 8)

            // Mic (if supported & model ready)
            if DeviceSupport.isIPhone13OrNewer && whisper.isModelReady {
                smallMicButton
            }

            // Stop TTS (only when the setting is ON)
            if settings.ttsEnabled {
                stopTTSButton
            }

            // Stop (while streaming) or Send
            if viewModel.isLoading {
                stopStreamingButton
            } else {
                sendButton
            }
        }
    }

    // MARK: - Voice-first controls row
    @ViewBuilder
    private var controlsRowVoiceFirst: some View {
        HStack(spacing: 10) {

            // Left: only the globe toggle
            globeButton

            // Center: BIG, EXPANDING MIC (only when Whisper is ready)
            if DeviceSupport.isIPhone13OrNewer && whisper.isModelReady {
                Button {
                    // If currently recording, a tap stops the recording (unchanged)
                    if transcriber.isRecording {
                        transcriber.toggle()
                        return
                    }

                    // Voice-Only behavior: before starting a new recording,
                    // stop any ongoing stream + TTS so we don't talk over ourselves.
                    if viewModel.isTTSSpeaking || viewModel.isLoading {
                        viewModel.stopEverything()
                        // Give the audio session a beat to deactivate before recording
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            if !transcriber.isTranscribing && !transcriber.isRecording {
                                transcriber.toggle()
                            }
                        }
                    } else if !transcriber.isTranscribing {
                        transcriber.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if transcriber.isTranscribing {
                            ProgressView().progressViewStyle(.circular)
                            Text("Processing…")
                                .font(.system(size: 15, weight: .semibold))
                        } else if transcriber.isRecording {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 18, weight: .bold))
                            Text("Listening… tap to stop")
                                .font(.system(size: 15, weight: .semibold))
                        } else {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Tap to speak")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                    .background(
                        Capsule().fill(Color(.tertiarySystemFill))
                    )
                    .foregroundStyle(.primary)
                    .overlay(
                        Capsule().stroke(
                            (transcriber.isRecording ? Color.red.opacity(0.35) : Color.primary.opacity(0.08)),
                            lineWidth: 1
                        )
                    )
                }
                .buttonStyle(.plain)
                // Don’t disable on isLoading anymore — we *want* taps to stop the stream then record
                .disabled(transcriber.isTranscribing)
                .accessibilityLabel(
                    transcriber.isRecording ? "Stop recording"
                    : (transcriber.isTranscribing ? "Processing speech" : "Start recording")
                )
            }

            // Right: a single Stop button (stops TTS and streaming)
            if viewModel.isTTSSpeaking || viewModel.isLoading {
                stopTTSButton
            }
        }
    }

    // MARK: - Reusable controls

    private var globeButton: some View {
        Button { viewModel.useWebSearch.toggle() } label: {
            Image(systemName: "globe")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(viewModel.useWebSearch ? Color.black : Color(.tertiarySystemFill)))
                .foregroundStyle(viewModel.useWebSearch ? .white : .secondary)
                .overlay(
                    Circle().stroke(
                        viewModel.useWebSearch ? Color.black.opacity(0.35) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
                )
                .accessibilityLabel(viewModel.useWebSearch ? "Web search on" : "Web search off")
        }
        .buttonStyle(.plain)
    }

    private var smallMicButton: some View {
        Button {
            if !transcriber.isTranscribing && !viewModel.isLoading {
                transcriber.toggle()
            }
        } label: {
            Group {
                if transcriber.isTranscribing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .frame(width: 36, height: 36)
                } else if transcriber.isRecording {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
            }
            .background(Circle().fill(Color(.tertiarySystemFill)))
            .foregroundStyle(transcriber.isRecording ? .red : .secondary)
            .overlay(
                Circle().stroke(
                    transcriber.isRecording ? Color.red.opacity(0.35) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoading || transcriber.isTranscribing)
        .accessibilityLabel(
            transcriber.isRecording ? "Stop recording"
            : (transcriber.isTranscribing ? "Processing speech" : "Start recording")
        )
    }

    private var stopTTSButton: some View {
        let canStop = viewModel.isTTSSpeaking || viewModel.isLoading

        return Button {
            // One tap stops both voice and network streaming
            viewModel.stopEverything()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(canStop ? Color.red.opacity(0.18)
                                          : Color(.tertiarySystemFill))
                )
                .foregroundStyle(canStop ? .red : .secondary)
                .overlay(
                    Circle().stroke(
                        canStop ? Color.red.opacity(0.35)
                                : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(!canStop)
        .accessibilityLabel("Stop")
    }

    private var stopStreamingButton: some View {
        Button(role: .destructive) { viewModel.stopEverything() } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.red.opacity(0.18)))
                .foregroundStyle(.red)
                .overlay(Circle().stroke(Color.red.opacity(0.35), lineWidth: 1))
                .accessibilityLabel("Stop")
        }
        .buttonStyle(.plain)
    }

    private var sendButton: some View {
        Button {
            // Dismiss keyboard first
            isInputFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            viewModel.sendMessage()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(canSend ? Color.black : Color(.tertiarySystemFill)))
                .foregroundStyle(canSend ? .white : .secondary)
                .overlay(
                    Circle().stroke(
                        canSend ? Color.black.opacity(0.35) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
                )
                .accessibilityLabel("Send")
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
    }

    // MARK: - Subviews kept from your original code

    @ViewBuilder
    private var messageField: some View {
        ZStack(alignment: .leading) {
            if viewModel.inputText.isEmpty {
                Text("Message…")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 6)
            }

            TextField("", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($isInputFocused)
                .textInputAutocapitalization(.sentences)
                .disableAutocorrection(false)
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
                .background(Color.clear)
        }
    }

    @ViewBuilder
    private var attachmentsStrip: some View {
        if !viewModel.pendingAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(viewModel.pendingAttachments.enumerated()), id: \.element.id) { idx, att in
                        AttachmentChip(
                            index: idx + 1,
                            attachment: att,
                            onRemove: { viewModel.removeAttachment(att.id) }
                        )
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Token estimate
    private var pendingTokenCount: Int {
        let historyChars = viewModel.messages
            .filter { !$0.isDeleted }
            .filter { $0.isUser || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.content.count }
            .reduce(0, +)

        let inputChars = viewModel.inputText.count

        let attachmentsChars = viewModel.pendingAttachments
            .map { $0.text.count }
            .reduce(0, +)

        return approxTokens(fromCharCount: historyChars + inputChars + attachmentsChars)
    }

    // MARK: - Handlers (kept/adapted)

    private func handlePDFImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                viewModel.processPickedPDF(url: url)
            }
        case .failure(let err):
            print("[Importer] PDF pick error:", err.localizedDescription)
        }
    }

    private func handlePhotoChange(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                await viewModel.processPickedImageData(data, suggestedName: nil)
            } else if let picked = try? await item.loadTransferable(type: PickedImage.self),
                      let data = picked.image.jpegData(compressionQuality: 0.9) {
                await viewModel.processPickedImageData(data, suggestedName: nil)
            } else if let url = try? await item.loadTransferable(type: URL.self),
                      let data = try? Data(contentsOf: url) {
                await viewModel.processPickedImageData(data, suggestedName: url.lastPathComponent)
            }
            pickedPhotoItem = nil
        }
    }

    private func handleRecordingChange(_ newValue: Bool) {
        if newValue { transcriber.latestTranscript = nil }
    }

    /// Auto-send the transcript once Whisper is done.
    private func autoSendAfterTranscriptionIfNeeded() {
        guard !viewModel.isLoading else { return } // don't queue while streaming
        let text = (transcriber.latestTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.inputText = text
        viewModel.sendMessage()
    }
}

struct AttachmentChip: View {
    let index: Int
    let attachment: Attachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.kind == .image ? "photo" : "doc.richtext")
                .imageScale(.small)
            Text("\(index). \(attachment.filename)")
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            Capsule().fill(Color(.tertiarySystemFill))
        )
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
