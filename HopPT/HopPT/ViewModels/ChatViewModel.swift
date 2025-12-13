import Foundation
import SwiftUI
import CoreData
import Combine
import Vision
import PDFKit
import UIKit

class ChatViewModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var currentConversation: Conversation?
    @Published var messages: [Message] = []
    @Published var inputText = ""
    @Published var isLoading = false
    @Published var streamedResponse = ""
    @Published var useWebSearch = false
    @Published var webStatus: WebStatus? = nil
    @Published var pendingAttachments: [Attachment] = []
    @Published var isTTSSpeaking = false  // NEW: reflect TTS state for UI

    private let webPipeline: WebSearchPipeline
    private var streamToken = UUID()
    private var pipelineTask: Task<Void, Never>? = nil
    
    private let context: NSManagedObjectContext
    private let lmStudioService: LMStudioService
    private let settings: AppSettings
    private let ATTACHMENT_CHAR_LIMIT: Int? = nil // set to nil for no cap
    
    // NEW: TTS
    private let tts = TTSManager()
    private var cancellables = Set<AnyCancellable>()
    
    init(context: NSManagedObjectContext, settings: AppSettings) {
            self.context = context
            self.settings = settings
            self.lmStudioService = LMStudioService(settings: settings)
            self.webPipeline = WebSearchPipeline(settings: settings)
            loadConversations()

            // Observe TTS state so we can enable/disable the Stop button
            tts.$isSpeaking
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.isTTSSpeaking = $0 }
                .store(in: &cancellables)

            // If the toggle is turned off mid-stream, stop speaking immediately
            settings.$ttsEnabled
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] enabled in
                    if !enabled { self?.tts.stop() }
                }
                .store(in: &cancellables)
        }
    
    // Expose a simple stop for the UI
        func stopTTS() {
            tts.stop()
        }
    
    func loadConversations(preserveSelection: Bool = false) {
        let request = NSFetchRequest<Conversation>(entityName: "Conversation")
        request.sortDescriptors = [
            NSSortDescriptor(key: "updatedAt", ascending: false),
            NSSortDescriptor(key: "createdAt", ascending: false)
        ]

        do {
            let currentID = currentConversation?.objectID
            conversations = try context.fetch(request)

            if preserveSelection, let currentID,
               let same = conversations.first(where: { $0.objectID == currentID }) {
                currentConversation = same
                loadMessages(for: same)
            } else if currentConversation == nil, let first = conversations.first {
                selectConversation(first)
            }
        } catch {
            print("Error loading conversations: \(error)")
        }
    }
    
    func createNewConversation() {
        let conversation = Conversation(context: context)
        conversation.id = UUID()
        conversation.title = "New Chat"
        conversation.createdAt = Date()
        conversation.updatedAt = conversation.createdAt
        
        do {
            try context.save()
            conversations.insert(conversation, at: 0)
            currentConversation = conversation
            messages = []
            pruneEmptyConversations(keeping: conversation)
        } catch {
            print("Error creating conversation: \(error)")
        }
    }
    
    func selectConversation(_ conversation: Conversation) {
        currentConversation = conversation
        loadMessages(for: conversation)
        pruneEmptyConversations(keeping: conversation)
    }
    
    func loadMessages(for conversation: Conversation) {
        let request = NSFetchRequest<Message>(entityName: "Message")
        request.predicate = NSPredicate(format: "conversation == %@", conversation)
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        do {
            messages = try context.fetch(request)
        } catch {
            print("Error loading messages: \(error)")
            messages = []
        }
    }
    
    func sendMessage() {
        // 1) Guard + ensure we have a conversation
        let typed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = !pendingAttachments.isEmpty
        let modelAtSend = settings.model
        guard !typed.isEmpty || hasAttachments else { return }
        guard let conversation = currentConversation ?? createAndReturnNewConversation() else { return }
        
        // Mark last activity now so it jumps to the top immediately
        conversation.updatedAt = Date()
        try? context.save()

        // Optionally reorder in-memory list right away (keeps UI snappy)
        conversations.sort {
            ($0.updatedAt ?? $0.createdAt) > ($1.updatedAt ?? $1.createdAt)
        }

        self.webStatus = nil

        // 2) Build final user content
        let attachBlock = buildAttachmentsBlock()
        let finalUserContent = typed + (attachBlock.isEmpty ? "" : "\n\n" + attachBlock)

        // 3) Create the user message (not saved until stream completes)
        let userMessage = Message(context: context)
        userMessage.id = UUID()
        userMessage.content = finalUserContent
        userMessage.isUser = true
        userMessage.timestamp = Date()
        userMessage.conversation = conversation

        // If this is the first message, set a title from the typed text or first attachment name
        if messages.isEmpty {
            let titleSource: String = !typed.isEmpty ? typed : (pendingAttachments.first?.filename ?? "New Chat")
            conversation.title = String(titleSource.prefix(50))
        }

        messages.append(userMessage)

        // 4) Reset UI state and create an AI placeholder message
        inputText = ""
        isLoading = true
        streamedResponse = ""

        // attachments are now part of the outgoing message — clear the panel
        pendingAttachments.removeAll()

        let aiMessage = Message(context: context)
        aiMessage.id = UUID()
        aiMessage.content = ""
        aiMessage.isUser = false
        aiMessage.timestamp = Date()
        aiMessage.conversation = conversation
        aiMessage.modelName = modelAtSend
        messages.append(aiMessage)

        // 5) Token snapshot to guard against race conditions
        let tokenAtStart = streamToken

        // 6) Prepare fallback messages for "no web" path
        let apiMessages = messages
            .filter { $0.isUser || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { msg in
                ["role": msg.isUser ? "user" : "assistant", "content": msg.content]
            }

        // NEW: Start TTS session if enabled (speaks as chunks arrive)
        if settings.ttsEnabled { tts.beginStreaming() }

        if useWebSearch {
            // --- WEB path ---
            let filteredHistory = self.messages.filter {
                $0.isUser || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            pipelineTask = webPipeline.runSearchAndStream(
                question: finalUserContent,
                history: filteredHistory,
                service: lmStudioService,
                onChunk: { [weak self] chunk in
                    guard let self = self, self.streamToken == tokenAtStart else { return }
                    self.streamedResponse += chunk
                    aiMessage.content = self.streamedResponse

                    // NEW: stream to TTS
                    if self.settings.ttsEnabled { self.tts.ingest(delta: chunk) }
                },
                onComplete: { [weak self] in
                    guard let self = self, self.streamToken == tokenAtStart else { return }
                    self.isLoading = false
                    self.webStatus = nil

                    // NEW: flush any remaining TTS tail
                    if self.settings.ttsEnabled { self.tts.endStreaming() }

                    do {
                        try self.context.save()
                        if let conv = self.currentConversation { self.loadMessages(for: conv) }
                        self.loadConversations(preserveSelection: true)
                    } catch {
                        print("Error saving message: \(error)")
                    }
                },
                onError: { [weak self] error in
                    guard let self = self, self.streamToken == tokenAtStart else { return }
                    print("[web] Web search error: \(error.localizedDescription)")
                    self.isLoading = false
                    self.webStatus = nil

                    // NEW: stop any ongoing speech
                    self.tts.stop()

                    let errorMessage = """
                    ⚠️ Web Search Error

                    The web search encountered an error and could not complete your request.

                    Error details: \(error.localizedDescription)

                    Please try again or disable web search to use offline mode.
                    """
                    aiMessage.content = errorMessage
                    do {
                        try self.context.save()
                        if let conv = self.currentConversation { self.loadMessages(for: conv) }
                        self.loadConversations(preserveSelection: true)
                    } catch {
                        print("Error saving error message: \(error)")
                    }
                },
                onStatus: { [weak self] status in
                    DispatchQueue.main.async { self?.webStatus = status }
                }
            )
        } else {
            // --- OFFLINE path ---
            lmStudioService.streamChat(
                messages: apiMessages,
                onChunk: { [weak self] chunk in
                    guard let self = self, self.streamToken == tokenAtStart else { return }
                    self.streamedResponse += chunk
                    aiMessage.content = self.streamedResponse

                    // NEW: stream to TTS
                    if self.settings.ttsEnabled { self.tts.ingest(delta: chunk) }
                },
                onComplete: { [weak self] in
                    guard let self = self, self.streamToken == tokenAtStart else { return }
                    self.isLoading = false

                    // NEW: flush any remaining TTS tail
                    if self.settings.ttsEnabled { self.tts.endStreaming() }

                    do {
                        try self.context.save()
                        if let conv = self.currentConversation { self.loadMessages(for: conv) }
                        self.loadConversations(preserveSelection: true)
                    } catch {
                        print("Error saving message: \(error)")
                    }
                },
                onError: { [weak self] error in
                    guard let self = self, self.streamToken == tokenAtStart else { return }
                    self.isLoading = false

                    // NEW: stop any ongoing speech
                    self.tts.stop()

                    aiMessage.content = "Error: \(error.localizedDescription)"
                    try? self.context.save()
                    self.loadConversations(preserveSelection: true)
                }
            )
        }
    }
    
    func stopEverything() {
        // Invalidate future callbacks
        streamToken = UUID()

        // Cancel network/stream/pipeline work
        lmStudioService.cancelStreaming()
        webPipeline.cancelRunning()
        pipelineTask?.cancel()
        pipelineTask = nil
        
        // NEW: also stop TTS
        tts.stop()

        // Reset UI state
        isLoading = false
        webStatus = nil

        // Optionally mark the last assistant message as partial (commented out)
        // if let last = messages.last(where: { !$0.isUser }) {
        //     last.content = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        //     if !last.content.isEmpty { last.content += "\n\n⏹️ Stopped." }
        // }

        // Persist whatever has streamed so far
        do { try context.save() } catch { print("Save after stop failed: \(error)") }
    }
    
    func editAndResend(from message: Message, newContent: String) {
        guard let conversation = currentConversation,
              let messageIndex = messages.firstIndex(where: { $0.objectID == message.objectID }) else { return }
        
        // Cancel any ongoing operations
        stopEverything()
        
        // Delete all messages from this one onwards
        let messagesToDelete = Array(messages.suffix(from: messageIndex))
        for msg in messagesToDelete {
            context.delete(msg)
        }
        messages.removeSubrange(messageIndex...)
        
        // Update conversation's updatedAt
        conversation.updatedAt = Date()
        
        // Save the deletion
        try? context.save()
        
        // Set input and send
        inputText = newContent
        sendMessage()
    }
    
    private func createAndReturnNewConversation() -> Conversation? {
        createNewConversation()
        return currentConversation
    }
    
    func deleteConversation(_ conversation: Conversation) {
        let id = conversation.objectID
        
        // If this is the current conversation, handle cleanup first
        if currentConversation?.objectID == id {
            // Cancel any in-flight operations immediately
            streamToken = UUID()
            
            // CRITICAL: Clear messages BEFORE any Core Data operations
            // This prevents the UI from trying to render soon-to-be-deleted objects
            messages.removeAll()
            
            // Find a replacement conversation
            var replacementConversation: Conversation? = nil
            
            if let currentIndex = conversations.firstIndex(where: { $0.objectID == id }) {
                // Try to select the previous conversation (more natural UX)
                if currentIndex > 0 {
                    replacementConversation = conversations[currentIndex - 1]
                } else if conversations.count > 1 && currentIndex + 1 < conversations.count {
                    // No previous, so select the next one
                    replacementConversation = conversations[currentIndex + 1]
                }
            }
            
            // Remove from in-memory list BEFORE Core Data deletion
            conversations.removeAll { $0.objectID == id }
            
            // Now safe to delete from Core Data
            context.delete(conversation)
            
            do {
                try context.save()
                
                // Update current conversation AFTER successful save
                if let replacement = replacementConversation {
                    currentConversation = replacement
                    loadMessages(for: replacement)
                } else {
                    // No other conversations exist - create new one
                    currentConversation = nil
                    createNewConversation()
                }
            } catch {
                print("Error deleting conversation: \(error)")
                // Restore the conversation to the list on error
                loadConversations(preserveSelection: false)
            }
        } else {
            // Not the current conversation, safe to delete immediately
            conversations.removeAll { $0.objectID == id }
            context.delete(conversation)
            
            do {
                try context.save()
            } catch {
                print("Error deleting conversation: \(error)")
                // Restore list on error
                loadConversations(preserveSelection: true)
            }
        }
    }
    
    func pruneEmptyConversations(keeping keep: Conversation? = nil) {
        let req = NSFetchRequest<Conversation>(entityName: "Conversation")
        var preds: [NSPredicate] = [NSPredicate(format: "messages.@count == 0")]
        if let keep = keep {
            preds.append(NSPredicate(format: "SELF != %@", keep))
        }
        req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: preds)

        do {
            let empties = try context.fetch(req)
            guard !empties.isEmpty else { return }

            // Delete from Core Data
            empties.forEach { context.delete($0) }
            try context.save()

            // Also remove from in-memory list so UI updates immediately
            let removedIDs = Set(empties.map { $0.objectID })
            conversations.removeAll { removedIDs.contains($0.objectID) }
        } catch {
            print("Prune empty conversations failed: \(error)")
        }
    }
    
    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    @MainActor
    private func addAttachment(kind: Attachment.Kind, filename: String, text: String) {
        let t = ATTACHMENT_CHAR_LIMIT.map { text.clipped(to: $0) } ?? text
        pendingAttachments.append(Attachment(kind: kind, filename: filename, text: t))
    }

    // MARK: - Attachments processing

    func processPickedImageData(_ data: Data, suggestedName: String? = nil) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let ui = UIImage(data: data),
                  let cg = ui.cgImage else { return }
            let text = Self.ocrText(from: cg)
            await MainActor.run {
                self.addAttachment(kind: .image, filename: suggestedName ?? "Photo.jpg", text: text)
            }
        }
    }

    func processPickedPDF(url: URL) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var text = ""
            var didAccess = false
            if url.startAccessingSecurityScopedResource() {
                didAccess = true
            }
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            if let doc = PDFDocument(url: url) {
                for i in 0..<doc.pageCount {
                    if let page = doc.page(at: i), let s = page.string {
                        text += s + "\n"
                    }
                }
            }
            let finalText = text
            await MainActor.run {
                self.addAttachment(kind: .pdf, filename: url.lastPathComponent, text: finalText)
            }
        }
    }
    
    func deleteAllConversations() {
            // Cancel any in-flight operations
            streamToken = UUID()
            
            // Clear UI state immediately to prevent accessing deleted objects
            messages.removeAll()
            currentConversation = nil
            
            // Fetch all conversations from Core Data
            let request = NSFetchRequest<Conversation>(entityName: "Conversation")
            
            do {
                let allConversations = try context.fetch(request)
                
                // Delete each conversation from Core Data
                allConversations.forEach { context.delete($0) }
                
                // Save the context
                try context.save()
                
                // Clear the in-memory list
                conversations.removeAll()
                
                // Create a new empty conversation to start fresh
                createNewConversation()
                
            } catch {
                print("Error deleting all conversations: \(error)")
                // Reload conversations on error
                loadConversations(preserveSelection: false)
            }
        }

    private nonisolated static func ocrText(from cgImage: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        // Italian + English by default; add more if you like
        req.recognitionLanguages = ["it-IT", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([req])
            let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        } catch {
            print("[OCR] error:", error.localizedDescription)
            return ""
        }
    }

    // Builds the block that will be appended to the user message
    private func buildAttachmentsBlock() -> String {
        guard !pendingAttachments.isEmpty else { return "" }
        var out = "### Attachments\n"
        for (idx, a) in pendingAttachments.enumerated() {
            out += "(\(idx + 1)) \(a.filename) [\(a.kind.rawValue)]\n"
            out += "```\n\(a.text)\n```\n\n"
        }
        return out
    }
}

extension String {
    func clipped(to maxChars: Int) -> String {
        guard count > maxChars else { return self }
        return String(prefix(maxChars)) + "\n…[truncated]"
    }
    /// Truncate to `maxChars` total (including the "...").
    func truncatedWithDots(maxChars: Int) -> String {
        guard maxChars > 3, count > maxChars else { return self }
        let end = index(startIndex, offsetBy: maxChars - 3)
        return String(self[..<end]) + "..."
    }
}

extension ChatViewModel {
    /// Approximate prompt tokens for the *pending* send (history + input + attachments).
    var tokenEstimate: Int {
        let historyChars = messages
            .filter { !$0.isDeleted }
            .filter { $0.isUser || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.content.count }
            .reduce(0, +)

        let inputChars = inputText.count

        let attachmentsChars = pendingAttachments
            .map { $0.text.count }
            .reduce(0, +)

        return approxTokens(fromCharCount: historyChars + inputChars + attachmentsChars)
    }
}

func approxTokens(fromCharCount n: Int) -> Int {
    Int(ceil(Double(n) / 3.8))
}
