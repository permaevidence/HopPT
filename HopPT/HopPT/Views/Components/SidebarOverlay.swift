import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct SidebarOverlay<Content: View>: View {
    @Binding var isShowing: Bool
    let content: Content

    init(isShowing: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self._isShowing = isShowing
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = min(proxy.size.width * 0.70, proxy.size.width)

            ZStack(alignment: .leading) {
                // Dim background when visible
                if isShowing {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeOut) { isShowing = false } }
                        .transition(.opacity)
                }

                // Panel itself
                content
                    .frame(width: panelWidth)
                    .background(.regularMaterial)
                    .shadow(radius: 8)
                    .offset(x: isShowing ? 0 : -panelWidth - 8)
                    .gesture(
                        DragGesture()
                            .onEnded { value in
                                // Swipe left to close
                                if value.translation.width < -50 {
                                    withAnimation(.easeOut) { isShowing = false }
                                }
                            }
                    )
            }
            .animation(.easeOut(duration: 0.25), value: isShowing)
        }
        .ignoresSafeArea()
    }
}

struct CircleIcon: View {
    let systemName: String
    var active: Bool = false
    var accessibilityLabel: String? = nil

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 36, height: 36)
            .background(
                Circle().fill(active ? Color.black : Color(.tertiarySystemFill))  // Changed from Color.accentColor
            )
            .foregroundStyle(active ? .white : .secondary)
            .overlay(
                Circle().stroke(
                    active ? Color.black.opacity(0.35)  // Changed from Color.accentColor.opacity(0.35)
                           : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
            )
            .accessibilityLabel(accessibilityLabel ?? systemName)
    }
}
