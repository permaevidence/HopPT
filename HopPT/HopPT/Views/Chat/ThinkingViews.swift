import SwiftUI
import MarkdownUI
import PhotosUI
import CoreData
import UniformTypeIdentifiers

struct ThinkingBubble: View {
    @State private var anim = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Assistant")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .frame(width: 8, height: 8)
                            .opacity(0.5)
                            .scaleEffect(anim ? 1.1 : 0.6)
                            .animation(
                                .easeInOut(duration: 0.6)
                                    .repeatForever()
                                    .delay(Double(i) * 0.2),
                                value: anim
                            )
                    }
                }
                .padding(12)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(12)
            }
            Spacer(minLength: 40)
        }
        .onAppear { anim = true }
    }
}

struct ThinkingDotsInline: View {
    @State private var anim = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 8, height: 8)
                    .opacity(0.6)
                    .scaleEffect(anim ? 1.15 : 0.65)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(i) * 0.18),
                        value: anim
                    )
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            Capsule().fill(Color.gray.opacity(0.15))
        )
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onAppear { anim = true }
    }
}

struct PulseSphere: View {
    var isActive: Bool
    @State private var t: Double = 0

    // Tweak these for feel
    private let period: Double = 1.2   // seconds per breath
    private let amplitude: CGFloat = 0.06

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            // progress in [0, 1]
            let progress = 0.5 + 0.5 * sin(2 * .pi * (now / period))
            let scale: CGFloat = isActive ? (1.0 + amplitude * CGFloat(progress)) : 1.0
            let glow = isActive ? 0.35 : 0.12

            ZStack {
                // Subtle outer ring that softly grows/shrinks when active
                Circle()
                    .strokeBorder(Color.accentColor.opacity(isActive ? 0.25 : 0.10), lineWidth: 2)
                    .scaleEffect(isActive ? (1.06 + 0.02 * CGFloat(progress)) : 1.0)
                    .blur(radius: isActive ? 1.5 : 0)

                // Core sphere
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.accentColor.opacity(0.9),
                                Color.accentColor.opacity(0.6),
                                Color.accentColor.opacity(0.28),
                                Color.accentColor.opacity(0.18)
                            ]),
                            center: .center,
                            startRadius: 6,
                            endRadius: 180
                        )
                    )
                    .overlay(
                        // Soft highlight
                        Circle()
                            .fill(.white.opacity(0.10))
                            .blur(radius: 18)
                            .offset(y: -24)
                            .mask(Circle())
                    )
                    .scaleEffect(scale)
                    .shadow(color: Color.accentColor.opacity(glow), radius: isActive ? 28 : 10, x: 0, y: 10)

                // Gentle ripples when active
                if isActive {
                    RippleRing(progress: progress, delay: 0.0)
                    RippleRing(progress: progress, delay: 0.33)
                    RippleRing(progress: progress, delay: 0.66)
                }
            }
            .animation(.linear(duration: 0), value: isActive) // timeline drives motion
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Expanding, fading rings synchronized to `progress`.
    @ViewBuilder
    private func RippleRing(progress: Double, delay: Double) -> some View {
        let p = (progress + delay).truncatingRemainder(dividingBy: 1)
        let ringScale = 1.05 + (0.25 * p)
        let opacity = Double(max(0, 0.35 - 0.35 * p))

        Circle()
            .stroke(Color.accentColor.opacity(opacity), lineWidth: 1.5)
            .scaleEffect(ringScale)
            .blur(radius: 0.5)
    }
}

