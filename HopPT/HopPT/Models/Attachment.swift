import Foundation

struct Attachment: Identifiable, Equatable, Hashable {
    enum Kind: String { case image, pdf }
    let id = UUID()
    let kind: Kind
    var filename: String
    var text: String
}

// Parsed copy of what's inside the "### Attachments" section of a saved user message.
struct ParsedAttachment: Identifiable, Equatable, Hashable {
    let id = UUID()
    let index: Int
    let filename: String
    let kind: Attachment.Kind
    let text: String
}

func splitUserContentAndAttachments(_ content: String) -> (clean: String, attachments: [ParsedAttachment]) {
    // If there's no "### Attachments" section, show the message as-is.
    guard let headerRange = content.range(of: "### Attachments") else {
        return (content, [])
    }

    let cleanText = String(content[..<headerRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    let tail = String(content[headerRange.upperBound...])

    var results: [ParsedAttachment] = []
    let nsTail = tail as NSString

    // Matches blocks like:
    // (1) filename.ext [image]   \n
    // ```                        \n
    // ...text...                 \n
    // ```
    let pattern = #"^\((\d+)\)\s+(.+?)\s+\[(image|pdf)\]\s*[\r\n]+```[\r\n]?([\s\S]*?)```"#

    do {
        let rx = try NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .anchorsMatchLines]
        )
        let matches = rx.matches(in: tail, options: [], range: NSRange(location: 0, length: nsTail.length))
        for m in matches {
            guard m.numberOfRanges >= 5 else { continue }
            let idxStr   = nsTail.substring(with: m.range(at: 1))
            let filename = nsTail.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let kindStr  = nsTail.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            let text     = nsTail.substring(with: m.range(at: 4))

            let index = Int(idxStr) ?? (results.count + 1)
            let kind  = Attachment.Kind(rawValue: kindStr) ?? .image

            results.append(ParsedAttachment(index: index, filename: filename, kind: kind, text: text))
        }
    } catch {
        // If parsing fails, we just fall back to showing no attachment containers.
    }

    return (cleanText, results)
}
