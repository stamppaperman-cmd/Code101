import SwiftUI

/// The one row shape every line of the StampLab menu shares: a grey SF Symbol,
/// a one-line title (optionally a grey subtitle), and a single trailing item —
/// a shortcut hint or a switch. A status line appears under a row only when
/// there is something to act on; explanations live in `.help` tooltips.
/// (The menu used to mix bold 14–15 pt rows, coloured icons, a prominent blue
/// button and two-line descriptions, and read as clutter.)
enum MenuStyle {
    // AppKit's label colours, not SwiftUI's .primary/.secondary: inside the
    // vibrant popover those came out inverted (titles 0.21 grey, subtitles
    // 0.03 black, measured from screenshots), while AppKit colours draw like
    // the footer buttons do and still follow light/dark mode.
    static let title = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)

    static let iconWidth: CGFloat = 20
    static let spacing: CGFloat = 10
    static let rowHeight: CGFloat = 30
    static let inset: CGFloat = 8
    /// Status lines start under the title, not under the icon.
    static let statusIndent: CGFloat = inset + iconWidth + spacing
}

struct MenuIcon: View {
    let name: String
    /// Only for live states (recording); everything else stays grey.
    var tint: Color? = nil

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(tint ?? MenuStyle.secondary)
            .frame(width: MenuStyle.iconWidth)
    }
}

struct MenuTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).foregroundStyle(MenuStyle.title).lineLimit(1)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MenuStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

struct MenuShortcut: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 12.5))
            .foregroundStyle(MenuStyle.tertiary)
    }
}

/// Row padding, height and the hover highlight of a real menu item.
struct MenuRowFrame: ViewModifier {
    var highlights = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, MenuStyle.inset)
            .frame(minHeight: MenuStyle.rowHeight)
            // Only while hovered: a permanent (even clear) layer under the
            // text breaks the popover's vibrancy and greys the titles out.
            .background {
                if highlights && hovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A row that does one thing when clicked (opens a tool).
struct MenuActionRow: View {
    let icon: String
    var tint: Color? = nil
    let title: String
    var subtitle: String? = nil
    /// Small count after the title (items waiting on the Drop Shelf).
    var badge: Int = 0
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MenuStyle.spacing) {
                MenuIcon(name: icon, tint: tint)
                MenuTitle(title: title, subtitle: subtitle)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(MenuStyle.secondary.opacity(0.2)))
                }
                Spacer(minLength: 8)
                MenuShortcut(keys: shortcut)
            }
            .modifier(MenuRowFrame())
        }
        .buttonStyle(.plain)
    }
}

/// A row ending in a switch (or another control). Not clickable itself, so a
/// stray click beside the switch changes nothing.
struct MenuControlRow<Control: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: MenuStyle.spacing) {
            MenuIcon(name: icon)
            MenuTitle(title: title)
            Spacer(minLength: 8)
            control()
        }
        .modifier(MenuRowFrame(highlights: false))
    }
}

/// The small line under a row — only when there is something to act on.
struct MenuStatus<Content: View>: View {
    var warning = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 11.5))
            .foregroundStyle(warning ? Color.orange : MenuStyle.secondary)
            .buttonStyle(.link)
            .padding(.leading, MenuStyle.statusIndent)
            .padding(.trailing, MenuStyle.inset)
            .padding(.bottom, 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The menu's switches: one size everywhere.
struct MenuSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}
