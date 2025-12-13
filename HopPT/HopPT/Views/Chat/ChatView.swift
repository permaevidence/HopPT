import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var settings: AppSettings

    // NEW: auto-scroll toggler (true only when bottom sentinel is visible)
    @State private var autoScrollEnabled = true

    // Callbacks supplied by ContentView
    var onToggleSidebar: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    var body: some View {
        ZStack {
            if settings.ttsEnabled {
                // Voice Only Mode: replace transcript with animated canvas
                VoiceOnlyCanvas(viewModel: viewModel)
                    .transition(.opacity.combined(with: .scale))
            } else {
                // Classic transcript UI
                messagesArea
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            ComposerBar(viewModel: viewModel, isInputFocused: _isInputFocused)
                .padding(.bottom, -4)
        }
        .toolbar {
            // Left
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onToggleSidebar) {
                    CircleIcon(systemName: "sidebar.leading",
                               active: false,
                               accessibilityLabel: "Show conversations")
                }.buttonStyle(.plain)
            }

            // Center: model selector in title area
            ToolbarItem(placement: .principal) {
                ModelPickerMenu(onManage: onOpenSettings)
                    .environmentObject(settings)
            }

            // Right
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if viewModel.isLoading { viewModel.stopEverything() }
                    viewModel.createNewConversation()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New conversation")
            }
        }
        //.onAppear { isInputFocused = true }
        #if os(iOS)
        // Idle-timer control
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = viewModel.isLoading
        }
        .onChange(of: viewModel.isLoading) { isLoading in
            UIApplication.shared.isIdleTimerDisabled = isLoading
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { UIApplication.shared.isIdleTimerDisabled = false }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        #endif
    }

    // MARK: - Classic Messages Area (shown when Voice Only mode is OFF)
    @ViewBuilder
    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(
                            viewModel.messages
                                .filter { !$0.isDeleted }
                                .filter { $0.isUser || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                            id: \.objectID
                        ) { message in
                            MessageBubble(message: message) { msg, newText in
                                viewModel.editAndResend(from: msg, newContent: newText)
                            }
                        }

                        if viewModel.useWebSearch,
                           let s = viewModel.webStatus,
                           viewModel.isLoading,
                           viewModel.streamedResponse.isEmpty {
                            InlineStatusRow(status: s)
                                .padding(.horizontal)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                                .id("webStatusRow" as AnyHashable)
                        }

                        if viewModel.isLoading && viewModel.streamedResponse.isEmpty {
                            ThinkingBubble()
                                .id("thinking" as AnyHashable)
                        }

                        // Bottom sentinel used to detect if the user is at bottom
                        Color.clear
                            .frame(height: 1)
                            .id("bottom" as AnyHashable)
                            .onAppear { autoScrollEnabled = true }     // bottom visible → allow auto scroll
                            .onDisappear { autoScrollEnabled = false }  // scrolled up → freeze auto scroll
                    }
                    .padding(.horizontal)
                    .padding(.top)
                    .padding(.bottom, 16) // room above the inset composer
                }
                .scrollDismissesKeyboard(.interactively)
                // As soon as the user drags, freeze auto-scroll
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1).onChanged { _ in autoScrollEnabled = false }
                )

                // Floating "Jump to latest" button when user has scrolled up
                if !autoScrollEnabled {
                    Button {
                        withAnimation {
                            proxy.scrollTo("bottom" as AnyHashable, anchor: .bottom)
                        }
                        autoScrollEnabled = true
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color(.tertiarySystemFill)))
                            .foregroundStyle(.black) // ← force black (not blue)
                            .overlay(
                                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to latest")
                    .padding(.trailing, 12)
                    .padding(.bottom, 76) // keep above the composer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // Only auto-scroll when the bottom is visible (or re-enabled by the button)
            .onChange(of: viewModel.messages.count) { _ in
                guard autoScrollEnabled else { return }
                withAnimation { proxy.scrollTo("bottom" as AnyHashable, anchor: .bottom) }
            }
            .onChange(of: viewModel.streamedResponse) { _ in
                guard autoScrollEnabled else { return }
                withAnimation { proxy.scrollTo("bottom" as AnyHashable, anchor: .bottom) }
            }
            .onChange(of: viewModel.webStatus?.stage) { _ in
                guard autoScrollEnabled else { return }
                withAnimation { proxy.scrollTo("bottom" as AnyHashable, anchor: .bottom) }
            }
        }
    }
}

struct InlineStatusRow: View {
    let status: WebStatus
    var body: some View {
        WebPipelineStatusView(status: status)
            .frame(maxWidth: .infinity, alignment: .leading) // full width, no "Assistant" label
    }
}
