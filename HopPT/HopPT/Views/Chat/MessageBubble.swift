import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct MessageBubble: View {
    @ObservedObject var message: Message
    var onEdit: ((Message, String) -> Void)? = nil
    
    // Add state for the edit sheet
    @State private var showingEditSheet = false
    @State private var editedText = ""

    var body: some View {
        guard !message.isDeleted && !message.isFault else {
            return AnyView(EmptyView())
        }
        
        let isUser = message.isUser
        let content = message.content

        let (cleanText, parsedAttachments) = isUser
            ? splitUserContentAndAttachments(content)
            : (content, [])

        let copyText: String? = {
            if isUser {
                let t = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            } else {
                let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
        }()

        return AnyView(
            HStack(spacing: 0) {
                if isUser { Spacer(minLength: 40) }

                VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {

                    if isUser {
                        if !cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            TableAwareMarkdown(text: cleanText, bubbleBackground: Color(.secondarySystemBackground))
                                .foregroundColor(.primary)
                                // ADD CONTEXT MENU HERE
                                .contextMenu {
                                    if let text = copyText {
                                        Button {
                                            UIPasteboard.general.string = text
                                        } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }
                                        
                                        ShareLink(item: text) {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                    }
                                    
                                    // Edit at the bottom (third)
                                    if let onEdit = onEdit {
                                        Button {
                                            editedText = cleanText
                                            showingEditSheet = true
                                        } label: {
                                            Label("Edit & Resend", systemImage: "pencil")
                                        }
                                    }
                                }
                        }

                        if !parsedAttachments.isEmpty {
                            VStack(alignment: .trailing, spacing: 8) {
                                ForEach(parsedAttachments) { att in
                                    SentAttachmentView(att: att)
                                        .frame(maxWidth: 320, alignment: .trailing)
                                }
                            }
                        }
                    } else {
                        TableAwareMarkdown(text: content, bubbleBackground: .clear)
                            // Optional: add context menu for assistant messages too
                            .contextMenu {
                                if let text = copyText {
                                    Button {
                                        UIPasteboard.general.string = text
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    
                                    ShareLink(item: text) {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                    }

                    HStack(spacing: 8) {
                        Text(message.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        if !isUser, let m = message.modelName, !m.isEmpty {
                            ModelTag(name: m)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                }
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            }
            .padding(.vertical, 2)
            // ADD SHEET FOR EDIT
            .sheet(isPresented: $showingEditSheet) {
                EditMessageSheet(
                    text: $editedText,
                    onSend: { newText in
                        onEdit?(message, newText)
                        showingEditSheet = false
                    },
                    onCancel: {
                        showingEditSheet = false
                    }
                )
            }
        )
    }
}

// MARK: - Supporting Types and Functions

struct ModelTag: View {
    let name: String
    var body: some View {
        Text(name.truncatedWithDots(maxChars: 35))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct EditMessageSheet: View {
    @Binding var text: String
    let onSend: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($isFocused)
                .padding()
                .navigationTitle("Edit Message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            onSend(text)
                        }
                        .fontWeight(.semibold)
                        .disabled(!canSend)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onAppear { isFocused = true }
    }
}

enum MDChunk { case table(String), other(String) }

// Pipe-table separator matcher, e.g. `| --- | :---: | ---: |`
let tableSeparatorRegex: NSRegularExpression = {
    try! NSRegularExpression(pattern: #"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$"#)
}()

/// Splits a markdown string into `.table` and `.other` chunks.
/// - Respects fenced code blocks (```) so tables inside code are ignored.
/// - Detects GitHub-style pipe tables: header row, then a separator row of dashes/colons.
func markdownChunks(from text: String) -> [MDChunk] {
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    var chunks: [MDChunk] = []
    var buffer: [String] = []
    var i = 0
    var inFence = false

    func flushOther() {
        guard !buffer.isEmpty else { return }
        chunks.append(.other(buffer.joined(separator: "\n")))
        buffer.removeAll()
    }

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Track fenced code blocks (```lang)
        if trimmed.hasPrefix("```") {
            inFence.toggle()
            buffer.append(line)
            i += 1
            continue
        }

        // If not inside a code fence, look for a table header + separator
        if !inFence, i + 1 < lines.count,
           line.contains("|"),
           tableSeparatorRegex.firstMatch(
                in: lines[i + 1],
                options: [],
                range: NSRange(location: 0, length: lines[i + 1].utf16.count)
           ) != nil {

            // Emit accumulated non-table text
            flushOther()

            // Collect the table block: header + separator + subsequent pipe rows
            var tableLines = [line, lines[i + 1]]
            i += 2
            while i < lines.count {
                let L = lines[i]
                let t = L.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || !L.contains("|") { break }
                tableLines.append(L)
                i += 1
            }
            chunks.append(.table(tableLines.joined(separator: "\n")))

            // Preserve a blank line after a table if it existed
            if i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                buffer.append("")  // keep spacing
                i += 1
            }
            continue
        }

        // Default: accumulate normal lines
        buffer.append(line)
        i += 1
    }

    flushOther()
    return chunks
}

struct TableData {
    let headers: [String]
    let rows: [[String]]
    let alignments: [TextAlignment]
}

extension TableData {
    init?(from markdown: String) {
        let lines = markdown.split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return nil }
        
        // Parse header
        let headerLine = lines[0]
        let headers = headerLine
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        guard headers.count > 0 else { return nil }
        
        // Parse separator (for alignment info)
        let separatorLine = lines[1]
        let separatorParts = separatorLine
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        let alignments = separatorParts.map { part -> TextAlignment in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(":") && trimmed.hasSuffix(":") {
                return .center
            } else if trimmed.hasSuffix(":") {
                return .trailing
            } else {
                return .leading
            }
        }
        
        // Parse rows
        var rows: [[String]] = []
        for i in 2..<lines.count {
            let cells = lines[i]
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            
            if cells.count > 0 {
                rows.append(cells)
            }
        }
        
        self.headers = headers
        self.rows = rows
        self.alignments = alignments.count == headers.count ? alignments : Array(repeating: .leading, count: headers.count)
    }
}

struct CustomTableView: View {
    let tableData: TableData
    let bubbleBackground: Color
    
    // Configuration
    let maxColumnCharacters: Int = 25
    let cellPadding: CGFloat = 8
    let minColumnWidth: CGFloat = 40
    
    private func estimatedWidth(for text: String) -> CGFloat {
        // Rough estimate: ~8 points per character for system font
        let charCount = min(text.count, maxColumnCharacters)
        return max(CGFloat(charCount * 8 + 16), minColumnWidth)
    }
    
    private func columnWidths() -> [CGFloat] {
        var widths: [CGFloat] = []
        
        for colIndex in 0..<tableData.headers.count {
            var maxWidth: CGFloat = estimatedWidth(for: tableData.headers[colIndex])
            
            for row in tableData.rows {
                if colIndex < row.count {
                    let cellWidth = estimatedWidth(for: row[colIndex])
                    maxWidth = max(maxWidth, cellWidth)
                }
            }
            
            // Cap the maximum width
            let maxAllowedWidth = CGFloat(maxColumnCharacters * 8 + 16)
            widths.append(min(maxWidth, maxAllowedWidth))
        }
        
        return widths
    }
    
    var body: some View {
        let widths = columnWidths()
        
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                // Header row with uniform height
                EquiHeightHStack(spacing: 0) {
                    ForEach(Array(tableData.headers.enumerated()), id: \.offset) { index, header in
                        // Use Markdown for headers to support formatting
                        Markdown(header)
                            .markdownTextStyle(\.text) {
                                FontWeight(.bold)
                            }
                            .lineLimit(nil)
                            .multilineTextAlignment(
                                index < tableData.alignments.count ?
                                tableData.alignments[index] : .leading
                            )
                            .frame(width: widths[index], alignment: alignment(for: index))
                            .padding(cellPadding)
                            .frame(maxHeight: .infinity)
                            .background(Color.gray.opacity(0.1))
                            .overlay(
                                Rectangle()
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                            )
                    }
                }
                
                // Data rows with uniform height per row
                ForEach(Array(tableData.rows.enumerated()), id: \.offset) { rowIndex, row in
                    EquiHeightHStack(spacing: 0) {
                        ForEach(0..<tableData.headers.count, id: \.self) { colIndex in
                            let cellText = colIndex < row.count ? row[colIndex] : ""
                            
                            // Use Markdown for cell content to support formatting
                            Markdown(cellText)
                                .lineLimit(nil)
                                .multilineTextAlignment(
                                    colIndex < tableData.alignments.count ?
                                    tableData.alignments[colIndex] : .leading
                                )
                                .frame(width: widths[colIndex], alignment: alignment(for: colIndex))
                                .padding(cellPadding)
                                .frame(maxHeight: .infinity)
                                .background(
                                    rowIndex % 2 == 0 ?
                                    Color.clear :
                                    Color.gray.opacity(0.05)
                                )
                                .overlay(
                                    Rectangle()
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                                )
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.automatic)
    }
    
    private func alignment(for index: Int) -> Alignment {
        guard index < tableData.alignments.count else { return .leading }
        switch tableData.alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }
}

struct EquiHeightHStack: Layout {
    var spacing: CGFloat = 0
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let heights = subviews.map { $0.sizeThatFits(proposal).height }
        let maxHeight = heights.max() ?? 0
        let widths = subviews.map { $0.sizeThatFits(proposal).width }
        let totalWidth = widths.reduce(0, +) + spacing * CGFloat(subviews.count - 1)
        
        return CGSize(width: totalWidth, height: maxHeight)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = subviews.map { $0.sizeThatFits(proposal).height }
        let maxHeight = heights.max() ?? 0
        
        var x = bounds.minX
        for subview in subviews {
            let width = subview.sizeThatFits(proposal).width
            let proposalWithHeight = ProposedViewSize(width: width, height: maxHeight)
            
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: proposalWithHeight
            )
            
            x += width + spacing
        }
    }
}

struct TableAwareMarkdown: View {
    let text: String
    var bubbleBackground: Color = .clear

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdownChunks(from: text).enumerated()), id: \.offset) { _, chunk in
                switch chunk {
                case .other(let s):
                    Markdown(s)
                        .textSelection(.enabled)
                        .tint(.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .table(let s):
                    // Try to parse as table data first
                    if let tableData = TableData(from: s) {
                        CustomTableView(tableData: tableData, bubbleBackground: bubbleBackground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Fallback to regular markdown if parsing fails
                        ScrollView(.horizontal) {
                            Markdown(s)
                                .textSelection(.enabled)
                                .tint(.accentColor)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.trailing, 12)
                        }
                        .scrollIndicators(.automatic)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(bubbleBackground)
        .cornerRadius(12)
    }
}

