import AppKit
import SwiftUI
import Translation

struct OverlayContentView: View {
    @ObservedObject var viewModel: OverlayViewModel

    @State private var configuration = TranslationSession.Configuration(
        source: kSourceLanguage,
        target: kTargetLanguage
    )
    @State private var justCopied = false

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
                // Sits in the strip DragContainerView passes through to us;
                // revealed on hover only, QuickTime-style.
                HStack(spacing: 4) {
                    if !viewModel.translatedText.isEmpty {
                        Button {
                            copyTranslation()
                        } label: {
                            Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(justCopied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .help("Copy translation")
                    }
                    Button {
                        viewModel.setLensVisible(false)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Hide the lens (⌥⌘L or the menu bar icon reopens it)")
                }
                .padding(8)
                .opacity(controlsVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: controlsVisible)
            }
            .overlay(alignment: .bottomLeading) {
                if let note = viewModel.translationNote {
                    Label(note, systemImage: "wifi.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                ResizeGrip()
                    .padding(6)
                    .allowsHitTesting(false)
                    .opacity(viewModel.isHovering ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: viewModel.isHovering)
            }
            .translationTask(configuration) { session in
                await viewModel.runTranslationLoop(session)
            }
    }

    private var isCapturing: Bool {
        viewModel.status == .running || viewModel.status == .starting
    }

    private var controlsVisible: Bool {
        viewModel.isHovering || justCopied
    }

    private func copyTranslation() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(viewModel.translatedText, forType: .string)
        justCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            justCopied = false
        }
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
                Text("Enable OverlayLens under Screen & System Audio Recording. If macOS asks, choose \"Quit & Reopen\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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
