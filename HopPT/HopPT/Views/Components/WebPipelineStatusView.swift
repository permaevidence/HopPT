import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct WebPipelineStatusView: View {
    let status: WebStatus

    private var title: String {
        switch status.stage {
        case .generatingQueries: return "Generating queries…"
        case .analyzingResults:  return "Analyzing results…"
        case .scraping:          return "Scraping these URLs…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                Text(title).font(.headline)
            }

            if status.stage == .scraping && !status.urls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(status.urls.prefix(4), id: \.self) { u in
                        Text(u)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if status.urls.count > 4 {
                        Text("…and \(status.urls.count - 4) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading) // ← make the bubble stretch
        .background(                                   // ← apply background AFTER the frame
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemGray4))            // darker grey
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .transition(.opacity)
    }
}
