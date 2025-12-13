import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: ChatViewModel
    @EnvironmentObject private var settings: AppSettings

    @State private var showSidebar = false
    @State private var showSettings = false
    @State private var didLaunchNewChat = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Main chat screen in a nav stack so it has a title/toolbar
            NavigationStack {
                ChatView(
                    viewModel: viewModel,
                    onToggleSidebar: {
                        // dismiss keyboard first
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        withAnimation(.easeOut) { showSidebar = true }
                    },
                    onOpenSettings: {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        showSettings = true
                    }
                )
            }

            // Slide-in conversations panel (max 70% width)
            SidebarOverlay(isShowing: $showSidebar) {
                ConversationPanelView(
                    viewModel: viewModel,
                    onOpen: { conv in
                        viewModel.selectConversation(conv)
                        withAnimation(.easeOut) { showSidebar = false }
                    },
                    onNewChat: {
                        viewModel.createNewConversation()
                        withAnimation(.easeOut) { showSidebar = false }
                    },
                    onOpenSettings: { showSettings = true }
                )
            }
        }
        // Settings sheet (same as you had)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(viewModel: viewModel)  // Pass the viewModel here
                    .environmentObject(settings)
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        // Onboarding sheet - shows only on first launch
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { _ in }
        )) {
            OnboardingView()
        }
        // Start with a fresh chat every time the app launches
        .onAppear {
            Task { await ModelDownloadManager.shared.checkModelStatus() }
            guard !didLaunchNewChat else { return }
            didLaunchNewChat = true
            viewModel.createNewConversation()
        }
    }
}
