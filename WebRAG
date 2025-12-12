import Foundation
import NaturalLanguage

public struct RAGChunk: Codable {
    public let text: String
    public let sourceURL: String
    public let chunkIndex: Int
    public let score: Double
}

public final class WebRAG {
    private let chunkSize: Int
    private let overlap: Int

    private static let candidateLanguageCodes: [String] = [
        "en","it","es","fr","de","pt","ru","tr","nl","pl","uk",
        "cs","sk","ro","hu","sv","no","da","fi","el","bg",
        "hr","sr","sl","he","ar","fa","ur","hi","bn","ta","te",
        "th","vi","id","ms","ko","ja","zh","zh-Hans","zh-Hant"
    ]

    // Map <NLLanguage -> NLEmbedding> for all installed/available embeddings.
    private let embeddings: [NLLanguage: NLEmbedding] = {
        var table: [NLLanguage: NLEmbedding] = [:]
        for code in WebRAG.candidateLanguageCodes {
            let lang = NLLanguage(rawValue: code)
            if let e = NLEmbedding.sentenceEmbedding(for: lang) {
                table[lang] = e
            }
        }
        return table
    }()

    // Optional helper for debugging/telemetry.
    public var availableEmbeddingLanguages: [String] {
        embeddings.keys.map { $0.rawValue }.sorted()
    }

    /// Main initializer (chars + chars)
    public init(chunkSizeChars: Int, overlapChars: Int) {
        precondition(chunkSizeChars > 0)
        precondition(overlapChars >= 0 && overlapChars < chunkSizeChars)
        self.chunkSize = chunkSizeChars
        self.overlap   = overlapChars
    }

    /// Convenience: tokens + ratio (1 token ≈ 4 chars)
    public convenience init(chunkSizeTokens: Int, tokenToChar: Int = 4, overlapRatio: Double = 0.15) {
        let chars = chunkSizeTokens * tokenToChar
        let overlap = Int(round(Double(chars) * overlapRatio))
        self.init(chunkSizeChars: chars, overlapChars: overlap)
    }

    public func topChunks(
        for fullText: String,
        query: String,
        url: String,
        topK: Int = 3,
        payloadIsMarkdown: Bool = false   // ⬅️ NEW
    ) -> [RAGChunk] {
        guard !fullText.isEmpty else { return [] }
        let windows = chunk(fullText)
        guard !windows.isEmpty else { return [] }

        let docLang = languageWithEmbedding(for: fullText) ?? languageWithEmbedding(for: query)
        guard let emb = embeddingFor(docLang),
              let qv = vector(payloadIsMarkdown ? stripMarkdown(query) : query, using: emb) else { return [] }

        var ranked: [RAGChunk] = []
        ranked.reserveCapacity(windows.count)

        for (i, chunkMD) in windows.enumerated() {
            let chunkForScore = payloadIsMarkdown ? stripMarkdown(chunkMD) : chunkMD
            guard let cv = vector(chunkForScore, using: emb) else { continue }
            let s = cosine(cv, qv)
            // IMPORTANT: keep the original window text (Markdown if available) for the LLM
            ranked.append(.init(text: chunkMD, sourceURL: url, chunkIndex: i, score: s))
        }

        return Array(ranked.sorted { $0.score > $1.score }.prefix(topK))
    }

    // MARK: - Internal

    private func chunk(_ text: String) -> [String] {
        var out: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[start..<end]))
            if end == text.endIndex { break }
            start = text.index(end, offsetBy: -overlap, limitedBy: text.startIndex) ?? text.startIndex
        }
        return out
    }

    // Choose the best language we *actually* have an embedding for (by confidence).
    private func languageWithEmbedding(for text: String, sample: Int = 20_000) -> NLLanguage? {
        let snippet = String(text.prefix(sample))
        let r = NLLanguageRecognizer()
        r.processString(snippet)
        let hyps = r.languageHypotheses(withMaximum: 3) // top few candidates
        // Return the highest-confidence language that exists in our registry.
        return hyps.sorted(by: { $0.value > $1.value })
                  .first(where: { embeddings[$0.key] != nil })?.key
    }

    // Get an embedding model with sensible fallbacks.
    private func embeddingFor(_ lang: NLLanguage?) -> NLEmbedding? {
        if let lang, let e = embeddings[lang] { return e }
        if let e = embeddings[.english] { return e }   // common, good fallback
        return embeddings.values.first                  // last-resort: any available
    }

    // Embed text with a specific embedding model.
    private func vector(_ text: String, using emb: NLEmbedding) -> [Double]? {
        emb.vector(for: text).map(Array.init)
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<n {
            dot += a[i] * b[i]
            na  += a[i] * a[i]
            nb  += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }
    
    private func stripMarkdown(_ s: String) -> String {
        var out = s
        // code fences
        out = out.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        // inline code
        out = out.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        // images and links → keep label
        out = out.replacingOccurrences(of: #"!?$begin:math:display$([^$end:math:display$]+)\]$begin:math:text$[^)]+$end:math:text$"#, with: "$1", options: .regularExpression)
        // headings markers
        out = out.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        // emphasis markers
        out = out.replacingOccurrences(of: #"[*_]{1,3}([^*_]+)[*_]{1,3}"#, with: "$1", options: .regularExpression)
        // HTML tags/entities
        out = out.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"&[a-zA-Z]+;"#, with: " ", options: .regularExpression)
        return out
    }
}

