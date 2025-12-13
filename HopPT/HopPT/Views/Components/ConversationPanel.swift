import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct ConversationPanelView: View {
    @ObservedObject var viewModel: ChatViewModel

    var onOpen: (Conversation) -> Void
    var onNewChat: () -> Void
    var onOpenSettings: () -> Void
    
    @State private var conversationToDelete: Conversation? = nil

    var body: some View {
        NavigationStack {
            List {
                if viewModel.conversations.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "message.circle")
                                .font(.system(size: 50))
                                .foregroundColor(.secondary)
                            Text("Start a conversation")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Button(action: onNewChat) {
                                Label("New Chat", systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(
                            viewModel.conversations
                                .filter { !$0.isDeleted },
                            id: \.objectID
                        ) { conversation in
                            let title = conversation.title
                            let date  = conversation.createdAt
                            let isSelected = (viewModel.currentConversation?.objectID == conversation.objectID)

                            Button {
                                onOpen(conversation)
                            } label: {
                                ConversationRow(title: title, createdAt: date)
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 4) // optional, for nicer spacing
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(isSelected ? Color(.secondarySystemFill) : Color.clear)
                            .contextMenu {
                                Button(role: .destructive) {
                                    conversationToDelete = conversation
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions { // ← optional, keep if you still want swipe-to-delete
                                Button(role: .destructive) {
                                    viewModel.deleteConversation(conversation)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenSettings) {
                        CircleIcon(systemName: "gearshape",
                                   active: false,
                                   accessibilityLabel: "Settings")
                    }
                    .buttonStyle(.plain)
                }
            }
            .confirmationDialog(
                    "Delete this conversation?",
                    isPresented: Binding(
                        get: { conversationToDelete != nil },
                        set: { if !$0 { conversationToDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        if let conv = conversationToDelete {
                            viewModel.deleteConversation(conv)
                        }
                        conversationToDelete = nil
                    }
                    Button("Cancel", role: .cancel) {
                        conversationToDelete = nil
                    }
                }
            #if os(iOS)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            #endif
        }
    }
}

struct ConversationRow: View {
    let title: String
    let createdAt: Date

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(createdAt, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundColor(.white)
        }
        .contentShape(Rectangle())
    }
}
