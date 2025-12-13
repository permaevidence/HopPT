import Foundation
import AVFoundation
import NaturalLanguage
import Combine

final class TTSManager: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synth = AVSpeechSynthesizer()
    private var buffer = ""
    private var processedCount = 0
    private var sessionActive = false

    // NEW: language detection + voice cache
    private let langRecognizer = NLLanguageRecognizer()
    private var lastVoice: AVSpeechSynthesisVoice?
    private var lastLanguageTag: String?

    override init() {
        super.init()
        synth.delegate = self
    }

    func beginStreaming() {
        buffer.removeAll()
        processedCount = 0
        isSpeaking = false
        lastVoice = nil
        lastLanguageTag = nil
        startAudioSessionIfNeeded()
    }

    func ingest(delta: String) {
        guard !delta.isEmpty else { return }
        buffer += delta
        speakCommittedSentences()
    }

    func endStreaming() {
        guard processedCount < buffer.count else { return }
        let start = buffer.index(buffer.startIndex, offsetBy: processedCount)
        let tail = String(buffer[start..<buffer.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            enqueueUtterance(for: tail)
            processedCount = buffer.count
        }
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        processedCount = buffer.count
        buffer.removeAll()
        isSpeaking = false
        stopAudioSessionIfNeeded()
    }

    // MARK: - Commit/split as before
    private func speakCommittedSentences() {
        guard processedCount < buffer.count else { return }
        let commitIdx = lastSentenceBoundaryIndex(in: buffer, fromOffset: processedCount)
        guard commitIdx > processedCount else { return }

        let start = buffer.index(buffer.startIndex, offsetBy: processedCount)
        let end   = buffer.index(buffer.startIndex, offsetBy: commitIdx)
        let chunk = buffer[start..<end]

        let parts = chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        if parts.isEmpty {
            enqueueUtterance(for: String(chunk))
        } else {
            parts.forEach { enqueueUtterance(for: String($0)) }
        }
        processedCount = commitIdx
    }

    private func lastSentenceBoundaryIndex(in text: String, fromOffset: Int) -> Int {
        if text.isEmpty { return fromOffset }
        let terminators: Set<Character> = [".", "?", "!", "…", "\n"]
        var lastIdx: Int? = nil
        var idx = 0
        var prevWasNewline = false

        for ch in text {
            let pos = idx; idx += 1
            if pos <= fromOffset {
                prevWasNewline = (ch == "\n"); continue
            }
            if ch == "\n" && prevWasNewline { lastIdx = pos + 1 }
            else if terminators.contains(ch) { lastIdx = pos + 1 }
            prevWasNewline = (ch == "\n")
        }
        return lastIdx ?? fromOffset
    }

    // MARK: - Language detection + voice selection
    private func enqueueUtterance(for text: String) {
        // Sanitize first so language detection & speech ignore emojis
        let clean = sanitizedForSpeech(text)
        guard !clean.isEmpty else { return }

        let langTag = detectLanguageBCP47(for: clean) ?? lastLanguageTag ?? Locale.current.identifier
        let voice = bestVoice(matching: langTag)
                    ?? lastVoice
                    ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)

        let u = AVSpeechUtterance(string: clean)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0

        lastVoice = voice
        lastLanguageTag = voice?.language
        synth.speak(u)
    }

    /// Returns a full BCP-47 tag (e.g. "it-IT") when possible.
    private func detectLanguageBCP47(for text: String) -> String? {
        langRecognizer.reset()
        langRecognizer.processString(text)
        guard let lang = langRecognizer.dominantLanguage else { return nil }
        let twoLetter = lang.rawValue.lowercased() // e.g., "it", "en"

        // If a concrete voice exists for this family, return its full tag.
        if let v = bestVoice(matching: twoLetter) {
            return v.language // e.g., "it-IT"
        }
        // Fall back to 2-letter tag (AVSpeech can still find a default)
        return twoLetter
    }

    /// Finds the nicest installed voice matching an exact tag or a language prefix.
    private func bestVoice(matching languageOrPrefix: String) -> AVSpeechSynthesisVoice? {
        // Exact tag first (e.g., "it-IT")
        if let exact = AVSpeechSynthesisVoice(language: languageOrPrefix) { return exact }

        // Then by prefix ("it" → any it-*), preferring Enhanced quality when present
        let lower = languageOrPrefix.lowercased()
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(lower) }
        return candidates.first(where: { $0.quality == .enhanced }) ?? candidates.first
    }

    private func startAudioSessionIfNeeded() {
        guard !sessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActive = true
        } catch {
            print("[TTS] audio session error:", error.localizedDescription)
        }
    }

    private func stopAudioSessionIfNeeded() {
        guard sessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        } catch {
            print("[TTS] audio session deactivate error:", error.localizedDescription)
        }
    }

    /// Remove emojis & common emoticons so TTS won't read them.
    private func sanitizedForSpeech(_ text: String) -> String {
        // 1) Remove emoji-like grapheme clusters (but keep plain digits/#/* when not emoji)
        var noEmoji = ""
        noEmoji.reserveCapacity(text.count)
        for ch in text {
            noEmoji.append(ch.isEmojiLikeForSpeech ? " " : ch) // keep a space to avoid word-gluing
        }

        // 2) Strip common emoticons and :shortcodes: with boundaries to avoid eating legit text
        var cleaned = noEmoji

        // Emoticons like :) ;-) :D :p and <3, but only when not embedded in words
        let emoticons = #"(?<!\w)(?:[;:=8xX]-?[\)\(DdPp]|<3)(?!\w)"#
        cleaned = cleaned.replacingOccurrences(of: emoticons, with: " ", options: .regularExpression)

        // Slack/GitHub-style shortcodes, e.g., :smile:, :thumbs_up:
        // Require non-word boundaries so :C++: in code blocks is still caught, but
        // things like "path:/usr/local:" won't match because there isn't a trailing colon-word-colon shape.
        let shortcodes = #"(?<!\w):[A-Za-z0-9_+\-]{1,30}:(?!\w)"#
        cleaned = cleaned.replacingOccurrences(of: shortcodes, with: " ", options: .regularExpression)

        // 3) Tidy whitespace and spacing before punctuation
        cleaned = cleaned
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }
}

extension TTSManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = true }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking {
            DispatchQueue.main.async { self.isSpeaking = false }
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking {
            DispatchQueue.main.async { self.isSpeaking = false }
        }
    }
}

private extension Character {
    /// True for things that *visually* render as emoji: pictographs, ZWJ sequences,
    /// keycaps (1️⃣, #️⃣), flags, or when VS16 forces emoji presentation.
    var isEmojiLikeForSpeech: Bool {
        let scalars = unicodeScalars

        // Any scalar that defaults to emoji presentation (😀, 👍, etc.)
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }

        // Variation Selector-16 forces emoji presentation on otherwise texty scalars
        if scalars.contains(where: { $0.value == 0xFE0F }) { return true } // VS16

        // ZWJ joins (family/man-woman-boy, profession emojis, etc.)
        if scalars.contains(where: { $0.value == 0x200D }) { return true } // ZWJ

        // Keycap sequences like 1️⃣, #️⃣, *️⃣
        if scalars.contains(where: { $0.value == 0x20E3 }) { return true } // COMBINING ENCLOSING KEYCAP

        // Regional indicator flags are two scalars in 1F1E6–1F1FF
        if scalars.count == 2,
           scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains(Int($0.value)) }) { return true }

        // Skin tone modifiers imply an emoji sequence when present
        if scalars.contains(where: { (0x1F3FB...0x1F3FF).contains(Int($0.value)) }) { return true }

        return false
    }
}
