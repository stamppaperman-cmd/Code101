import SwiftUI

/// Shared "smoked" Liquid Glass look used by the desktop widgets, modeled on
/// Apple's Batteries widget: dark, see-through glass with bright white type.
/// Callers should also force `.environment(\.colorScheme, .dark)`.
extension View {
    @ViewBuilder
    func smokeGlass<S: InsettableShape>(_ shape: S, darkness: Double = 0.32) -> some View {
        if #available(macOS 26.0, *) {
            self
                .background(shape.fill(Color.black.opacity(darkness)))
                .glassEffect(Glass.clear.tint(Color.black.opacity(0.18)), in: shape)
                .overlay(GlassRim(shape: shape))
        } else {
            self
                .background(shape.fill(Color.black.opacity(darkness + 0.08)))
                .background(.ultraThinMaterial, in: shape)
                .overlay(GlassRim(shape: shape))
        }
    }
}

/// Specular edge: bright at the top, fading toward the bottom.
struct GlassRim<S: InsettableShape>: View {
    let shape: S
    var strength: Double = 1

    var body: some View {
        shape
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.42 * strength),
                        Color.white.opacity(0.06 * strength),
                        Color.white.opacity(0.16 * strength),
                    ],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
    }
}

/// Batteries-widget style ring: a dim track with a bright rounded arc.
struct GlassRing<Content: View>: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 9
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.05))
                .padding(lineWidth / 2)
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(min(fraction, 1), 0.005))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.45), radius: 4)
                .animation(.easeOut(duration: 0.35), value: fraction)
            content
        }
        .padding(lineWidth / 2)
    }
}
