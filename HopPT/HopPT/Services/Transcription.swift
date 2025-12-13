import Foundation
import Combine
import AVFoundation
import WhisperKit
import UIKit

@MainActor
final class ModelDownloadManager: ObservableObject {
    static let shared = ModelDownloadManager()

    // UI state
    @Published var isDownloading = false { didSet { updateSystemLocks() } }
    @Published var isLoading     = false { didSet { updateSystemLocks() } }
    @Published var isCompiling   = false { didSet { updateSystemLocks() } }
    @Published var downloadProgress: Float = 0
    @Published var statusMessage = "Checking model…"
    @Published var isModelReady  = false
    @Published var showCompilationAlert = false

    // WhisperKit
    private var whisperKit: WhisperKit?

    // Storage & model identifiers (same as your other project)
    private let modelStorage    = "huggingface/models/argmaxinc/whisperkit-coreml"
    private let repoName        = "argmaxinc/whisperkit-coreml"
    private let targetModelName = "openai_whisper-large-v3-v20240930_turbo_632MB"

    private var compiledKey: String { "whisperkit_model_compiled_\(targetModelName)" }

    // Public read-only helpers for UI
    var hasModelOnDisk: Bool { modelIsDownloaded }
    var isCompiled: Bool { UserDefaults.standard.bool(forKey: compiledKey) }

    // Local path to model folder
    private var localModelFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(modelStorage)
                   .appendingPathComponent(targetModelName)
    }

    private var modelIsDownloaded: Bool {
        FileManager.default.fileExists(atPath: localModelFolder.path)
    }

    private init() {
        checkForAppUpdate()
    }
    
#if os(iOS)
private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

private func updateSystemLocks() {
    // Keep screen awake while we’re busy
    let keepAwake = isDownloading || isCompiling || isLoading
    UIApplication.shared.isIdleTimerDisabled = keepAwake

    // Give a few extra minutes if user briefly backgrounds the app
    if keepAwake {
        if bgTaskID == .invalid {
            bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "WhisperOps") { [weak self] in
                guard let self else { return }
                UIApplication.shared.endBackgroundTask(self.bgTaskID)
                self.bgTaskID = .invalid
            }
        }
    } else {
        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
    }
}
#endif

    private func checkForAppUpdate() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let currentBuild   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let versionKey = "\(currentVersion)_\(currentBuild)"

        let lastVersionKey = UserDefaults.standard.string(forKey: "whisperkit_last_app_version") ?? ""
        if lastVersionKey != versionKey && !lastVersionKey.isEmpty {
            UserDefaults.standard.removeObject(forKey: compiledKey)
            print("[ModelDownloadManager] App updated from \(lastVersionKey) to \(versionKey), reset compilation flag")
        }
        UserDefaults.standard.set(versionKey, forKey: "whisperkit_last_app_version")
    }

    // Check current status (call on app launch and when opening Settings)
    func checkModelStatus() async {
        if !modelIsDownloaded {
            isModelReady = false; isLoading = false; isCompiling = false
            statusMessage = "Model not downloaded"
            return
        }
        if !isCompiled {
            isModelReady = false; isLoading = false; isCompiling = false
            statusMessage = "Model not compiled"
            return
        }
        await loadModel() // already downloaded & compiled → just load
    }

    // Load (and compile if first run) the model from local storage
    func loadModel() async {
        let firstRunNeedsCompile = !isCompiled

        if firstRunNeedsCompile {
            isCompiling   = true
            isLoading     = false
            statusMessage = "Compiling… leave this page open. This might take up to 5 minutes."
        } else {
            isLoading     = true
            isCompiling   = false
            statusMessage = "Loading model…"
        }

        do {
            var cfg = WhisperKitConfig(model: targetModelName,
                                       modelFolder: localModelFolder.path)
            cfg.download = false // stay strictly offline here

            whisperKit = try await WhisperKit(cfg)
            try await whisperKit?.prewarmModels()

            if firstRunNeedsCompile {
                UserDefaults.standard.set(true, forKey: compiledKey)
            }

            isModelReady  = true
            isLoading     = false
            isCompiling   = false
            statusMessage = "Model ready"
        } catch {
            print("[ModelDownloadManager] loadModel error:", error)
            isModelReady  = false
            isLoading     = false
            isCompiling   = false
            statusMessage = "Failed to load model"
        }
    }

    // Download from Hugging Face, then compile (first run)
    func startDownload() async {
        isDownloading    = true
        downloadProgress = 0
        statusMessage    = "Downloading transcription model…"

        do {
            let folder = try await WhisperKit.download(
                variant: targetModelName,
                from:    repoName,
                progressCallback: { progress in
                    DispatchQueue.main.async {
                        self.downloadProgress = Float(progress.fractionCompleted)
                        self.statusMessage    = "Downloading… \(Int(progress.fractionCompleted * 100))%"
                    }
                }
            )

            // After download, compile once
            isDownloading = false
            isCompiling   = true
            statusMessage = "Compiling model…"

            var cfg = WhisperKitConfig(model: targetModelName,
                                       modelFolder: folder.path)
            cfg.download = false

            whisperKit = try await WhisperKit(cfg)
            try await whisperKit?.prewarmModels()

            UserDefaults.standard.set(true, forKey: compiledKey)

            isCompiling   = false
            isModelReady  = true
            statusMessage = "Model ready"
        } catch {
            print("[ModelDownloadManager] download error:", error)
            isDownloading = false
            isCompiling   = false
            isModelReady  = false
            statusMessage = "Download failed"
        }
    }

    func getWhisperKit() -> WhisperKit? { whisperKit }

    // Optional: allow removing the model from disk
    func deleteModelFromDisk() throws {
        whisperKit = nil
        if FileManager.default.fileExists(atPath: localModelFolder.path) {
            try FileManager.default.removeItem(at: localModelFolder)
        }
        UserDefaults.standard.removeObject(forKey: compiledKey)
        isModelReady       = false
        isDownloading      = false
        isLoading          = false
        isCompiling        = false
        downloadProgress   = 0
        statusMessage      = "Model not downloaded"
    }
}

@MainActor
final class WhisperTranscriber: ObservableObject {
    // Public state
    @Published var isRecording      = false
    @Published var isTranscribing   = false
    @Published var latestTranscript : String?
    let isSupported = DeviceSupport.isIPhone13OrNewer

    // Private
    private var recorder: AVAudioRecorder?
    private var pipe: WhisperKit? { ModelDownloadManager.shared.getWhisperKit() }

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    private func start() async {
        guard !isRecording else { return }
        guard ModelDownloadManager.shared.isModelReady else {
            print("[Whisper] Model not ready yet")
            return
        }

        // Ask mic permission
        let granted: Bool = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
        guard granted else { return }

        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("[Whisper] AVAudioSession error:", error.localizedDescription)
            return
        }

        // Prepare recorder (16 kHz mono AAC)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.prepareToRecord()
            recorder?.record()
            isRecording = true
        } catch {
            print("[Whisper] Failed to start recorder:", error.localizedDescription)
            recorder = nil
        }
    }

    private func stop() {
        guard let recorder else { return }
        recorder.stop()
        isRecording    = false
        isTranscribing = true
        Task { await transcribe(url: recorder.url) }
        self.recorder  = nil
    }

    private func transcribe(url: URL) async {
        guard let pipe else {
            print("[Whisper] WhisperKit not available")
            isTranscribing = false
            return
        }

        do {
            if let text = try await pipe.transcribe(audioPath: url.path)?.text {
                latestTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            print("[Whisper] Transcription error:", error.localizedDescription)
        }

        isTranscribing = false
    }
}
