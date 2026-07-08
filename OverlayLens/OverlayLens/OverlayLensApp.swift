import SwiftUI

@main
struct OverlayLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("OverlayLens", systemImage: "text.magnifyingglass") {
            MenuBarControlsView(viewModel: appDelegate.viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Quick controls shown when clicking the menu bar icon: lens on/off toggle,
/// glass opacity slider, and Quit.
struct MenuBarControlsView: View {
    @ObservedObject var viewModel: OverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Show lens", isOn: Binding(
                    get: { viewModel.isLensVisible },
                    set: { viewModel.setLensVisible($0) }
                ))
                .toggleStyle(.switch)
                Spacer()
                Text("⌥⌘L")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Online translation", isOn: $viewModel.useOnlineTranslation)
                    .toggleStyle(.switch)
                Text("Better quality; falls back to on-device translation when offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Glass opacity")
                    Spacer()
                    Text("\(Int(viewModel.glassOpacity * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
                Slider(value: $viewModel.glassOpacity, in: 0.15...1.0)
            }

            Divider()

            Button("Quit OverlayLens") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 240)
    }
}
