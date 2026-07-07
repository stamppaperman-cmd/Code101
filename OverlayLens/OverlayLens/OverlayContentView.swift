import SwiftUI
import Translation

struct OverlayContentView: View {
    @ObservedObject var viewModel: OverlayViewModel

    @State private var configuration = TranslationSession.Configuration(
        source: kSourceLanguage,
        target: kTargetLanguage
    )

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if viewModel.awaitingFirstFrame, isCapturing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                // Sits in the corner DragContainerView passes through to us.
                Button {
                    viewModel.setLensVisible(false)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Hide the lens (reopen from the menu bar icon)")
            }
            .overlay(alignment: .bottomTrailing) {
                ResizeGrip()
                    .padding(6)
                    .allowsHitTesting(false)
            }
            .translationTask(configuration) { session in
                await viewModel.runTranslationLoop(session)
            }
    }

    private var isCapturing: Bool {
        viewModel.status == .running || viewModel.status == .starting
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.status {
        case .needsPermission:
            VStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Screen recording permission required")
                    .font(.callout.weight(.semibold))
                Text("Enable OverlayLens in System Settings > Privacy & Security > Screen & System Audio Recording, then click the lens again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(16)

        case .failed(let message):
            VStack(spacing: 0) {
                translationBody
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

        case .starting, .running, .paused:
            translationBody
        }
    }

    private var translationBody: some View {
        ScrollView {
            Text(viewModel.translatedText.isEmpty ? placeholder : viewModel.translatedText)
                .font(.system(size: 14))
                .foregroundStyle(viewModel.translatedText.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private var placeholder: String {
        viewModel.status == .paused ? "Repositioning…" : "Point the lens at English text…"
    }
}

/// Visual hint for the bottom-right resize corner handled by
/// DragContainerView.
private struct ResizeGrip: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 12, y: 4))
            path.addLine(to: CGPoint(x: 4, y: 12))
            path.move(to: CGPoint(x: 12, y: 9))
            path.addLine(to: CGPoint(x: 9, y: 12))
        }
        .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .frame(width: 14, height: 14)
        .opacity(0.7)
    }
}
