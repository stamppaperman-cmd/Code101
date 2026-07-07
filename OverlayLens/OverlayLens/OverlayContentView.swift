import SwiftUI
import Translation

struct OverlayContentView: View {
    @ObservedObject var viewModel: OverlayViewModel

    @State private var configuration = TranslationSession.Configuration(
        source: kSourceLanguage,
        target: kTargetLanguage
    )

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if viewModel.awaitingFirstFrame, isCapturing {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
            }
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
