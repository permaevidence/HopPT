import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct PickedImage: Transferable {
    let image: UIImage
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let ui = UIImage(data: data) else {
                throw NSError(domain: "Transfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid image data"])
            }
            return PickedImage(image: ui)
        }
    }
}

struct SentAttachmentView: View {
    let att: ParsedAttachment
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: att.kind == .image ? "photo" : "doc.richtext")
                    .imageScale(.medium)

                Text("\(att.index). \(att.filename)")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if !att.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(expanded ? "Hide" : "View") {
                        withAnimation(.easeInOut) { expanded.toggle() }
                    }
                    .font(.caption)
                }

                Button {
                    UIPasteboard.general.string = att.text
                } label: {
                    Image(systemName: "doc.on.doc")
                        .imageScale(.medium)
                        .accessibilityLabel("Copy text")
                }
                .buttonStyle(.plain)
            }

            if expanded {
                ScrollView {
                    Text(att.text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
