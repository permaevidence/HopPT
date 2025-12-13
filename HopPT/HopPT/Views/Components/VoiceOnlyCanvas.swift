import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct VoiceOnlyCanvas: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 18) {
            // NEW: token pill under the nav/model selector
            TokenCountPill(count: viewModel.tokenEstimate)
                .padding(.top, 6)

            // Keep some breathing room before the sphere
            Spacer(minLength: 8)

            // Big animated sphere
            PulseSphere(isActive: viewModel.isTTSSpeaking)
                .frame(width: 180, height: 180)
                .accessibilityHidden(true)

            // Headline status text
            Text(statusHeadline)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal)

            if viewModel.isLoading && viewModel.streamedResponse.isEmpty {
                ThinkingDotsInline()
                    .padding(.top, 4)
            }

            if viewModel.useWebSearch,
               let s = viewModel.webStatus,
               viewModel.isLoading,
               viewModel.streamedResponse.isEmpty {
                InlineStatusRow(status: s)
                    .padding(.horizontal)
            }

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background(Color(.systemGroupedBackground))
        #endif
        .transition(.opacity.combined(with: .scale))
    }

    private var statusHeadline: String {
        if viewModel.isTTSSpeaking { return "" }
        if viewModel.isLoading {
            return viewModel.useWebSearch && viewModel.webStatus != nil
                ? "Searching the web and thinking…"
                : "Thinking…"
        }
        return ""
    }
}

struct TokenCountPill: View {
    let count: Int
    var body: some View {
        Text("≈ \(count.formatted()) tokens")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color(.secondarySystemBackground))
            )
            .overlay(
                Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .accessibilityLabel("Estimated tokens")
    }
}
