import AppKit
import SwiftUI
import Translation

/// Contents of lens 1 (the clear viewfinder). Deliberately almost empty: the
/// interior has to stay see-through so the text underneath is readable and
/// capturable. Only AR patches, permission/error states, and hover controls
/// draw anything. The block translation lives in `ReaderContentView`.
struct OverlayContentView: View {
    @ObservedObject var viewModel: OverlayViewModel

    // Three fixed-direction Apple sessions kept alive for the on-device
    // fallback; effectivePair() picks which one a given piece of text uses.
    // They live here (not in the reader) because this view is mounted whenever
    // the lens is on, whether or not the reader window is open.
    @State private var configEnToThai = TranslationSession.Configuration(
        source: kEnglishLanguage,
        target: kThaiLanguage
    )
    @State private var configThaiToEn = TranslationSession.Configuration(
        source: kThaiLanguage,
        target: kEnglishLanguage
    )
    @State private var configZhToThai = TranslationSession.Configuration(
        source: kChineseLanguage,
        target: kThaiLanguage
    )

    /// Corner radius must match the panel container's, or the border drawn
    /// here won't line up with the window's clipping.
    private let cornerRadius: CGFloat = 14
    /// Invisible but hit-testable ring: gives the resize edges something to
    /// grab without making the interior opaque. Must comfortably cover
    /// DragContainerView's 14pt corner margin.
    private let grabBandWidth: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Two rings, both edge-only so the middle stays click-through.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.04), lineWidth: grabBandWidth)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(signalColor, style: borderStroke)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .center) { content }
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .padding(6)
                .allowsHitTesting(false)
                .opacity(viewModel.isHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: viewModel.isHovering)
        }
            .translationTask(configEnToThai) { session in
                viewModel.attachSession(session, source: "en", target: "th")
                await viewModel.keepSessionAlive()
            }
            .translationTask(configThaiToEn) { session in
                viewModel.attachSession(session, source: "th", target: "en")
                await viewModel.keepSessionAlive()
            }
            .translationTask(configZhToThai) { session in
                viewModel.attachSession(session, source: "zh", target: "th")
                await viewModel.keepSessionAlive()
            }
    }

    private var isCapturing: Bool {
        viewModel.status == .running || viewModel.status == .starting
    }

    // MARK: - Header

    /// Always-visible strip along the top edge: the one obvious place to grab
    /// the frame, plus what state it's in and a way into the settings without
    /// hunting for the menu bar icon.
    private var header: some View {
        HStack(spacing: 6) {
            // The mascot doubles as the status light — it changes colour with
            // capture state instead of a plain dot.
            MascotShape()
                .fill(signalColor, style: FillStyle(eoFill: true))
                .frame(width: 13 * Brand.aspect, height: 13)
            Text(signalLabel)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 4)

            // Kept inside the strip DragContainerView passes to SwiftUI;
            // everything left of it drags the frame.
            Button {
                viewModel.openSettingsHandler?()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help("ตั้งค่า")

            Button {
                viewModel.setLensVisible(false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help("ปิดเลนส์")
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Color.black.opacity(0.62))
    }

    private var signalColor: Color {
        switch viewModel.lensSignal {
        case .translating: return Brand.clay
        case .idle, .noText: return .secondary
        case .warning: return .red
        }
    }

    /// "No text found" isn't an error, it's a search in progress — a dashed
    /// border says that without burning a second alert colour next to clay.
    private var borderStroke: StrokeStyle {
        viewModel.lensSignal == .noText
            ? StrokeStyle(lineWidth: 2, dash: [6, 4])
            : StrokeStyle(lineWidth: 2)
    }

    private var signalLabel: String {
        switch viewModel.lensSignal {
        case .translating:
            return "กำลังแปล · \(viewModel.recognizedLineCount) บรรทัด"
        case .idle:
            return viewModel.status == .paused ? "หยุดชั่วคราว" : "กำลังเริ่ม…"
        case .noText:
            return "ไม่พบข้อความ"
        case .warning:
            if case .needsPermission = viewModel.status { return "ต้องการสิทธิ์บันทึกหน้าจอ" }
            return "มีปัญหา — ดูหน้าต่างคำแปล"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.status {
        case .needsPermission:
            // The one state that needs a solid backing — an unreadable
            // permission prompt over a see-through panel helps nobody.
            VStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Screen recording permission required")
                    .font(.callout.weight(.semibold))
                Text("Enable StampLab under Screen & System Audio Recording. If macOS asks, choose \"Quit & Reopen\".")
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)

        case .starting, .running, .paused, .failed:
            // Nothing is ever drawn over the source text: translations belong
            // to the reader window. Keeping this empty is what makes the frame
            // usable as a viewfinder.
            Color.clear
        }
    }
}

/// Contents of lens 2 (the reader window): the translated text, plus copy and
/// close controls on hover.
struct ReaderContentView: View {
    @ObservedObject var viewModel: OverlayViewModel

    @State private var justCopied = false

    var body: some View {
        ScrollView {
            Text(viewModel.translatedText.isEmpty ? placeholder : viewModel.translatedText)
                .font(.system(size: 14 * viewModel.textScale))
                .foregroundStyle(viewModel.translatedText.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.32))
                .padding(4)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                if !viewModel.translatedText.isEmpty {
                    Button(action: copyTranslation) {
                        Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(justCopied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help("คัดลอกคำแปล")
                }
                Button {
                    viewModel.setReaderVisible(false)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("ปิดหน้าต่างคำแปล (เลนส์ยังทำงานอยู่)")
            }
            .padding(8)
            .opacity(controlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: controlsVisible)
        }
        .overlay(alignment: .bottomLeading) {
            if let note = statusNote {
                Label(note, systemImage: "wifi.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .padding(6)
                .allowsHitTesting(false)
                .opacity(viewModel.isReaderHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: viewModel.isReaderHovering)
        }
    }

    private var controlsVisible: Bool {
        viewModel.isReaderHovering || justCopied
    }

    /// Capture failures used to show inside the lens; with the lens clear,
    /// this window is the only place left to surface them.
    private var statusNote: String? {
        if case .failed(let message) = viewModel.status { return message }
        return viewModel.translationNote
    }

    private var placeholder: String {
        switch viewModel.status {
        case .needsPermission: return "รอสิทธิ์บันทึกหน้าจอ…"
        case .paused: return "Repositioning…"
        default:
            return viewModel.isLensVisible
                ? "เลื่อนกรอบใสไปครอบข้อความที่อยากแปล…"
                : "เปิดเลนส์จากเมนูบาร์เพื่อเริ่มแปล"
        }
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
}

/// Visual hint for the bottom-right resize corner handled by
/// DragContainerView.
struct ResizeGrip: View {
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
