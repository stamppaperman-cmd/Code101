import AppKit
import IOKit.ps

/// Menu bar item that shows the battery level as an iOS-style icon with the
/// percent inside: green above 40%, amber 21-40%, red at 20% or below. The
/// amber is deliberately darker than the system's Low Power Mode yellow so
/// the two never look alike. Clicking the icon opens a menu with the power
/// source, an estimate of remaining work time, and charge-now advice.
@MainActor
final class BatteryStatusController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var runLoopSource: CFRunLoopSource?
    private var fallbackTimer: Timer?

    /// Extra item other features append to the bottom of the dropdown
    /// (e.g. the system-stats widget toggle). Rebuilt on every open.
    var extraMenuItemProvider: (() -> NSMenuItem)?

    private static let green = NSColor.systemGreen
    private static let amber = NSColor(srgbRed: 0.80, green: 0.55, blue: 0.02, alpha: 1.0)
    private static let red = NSColor.systemRed

    private struct BatteryInfo {
        var percent: Int
        var charging: Bool
        var onACPower: Bool
        /// Minutes until empty while discharging; nil when unknown/still calculating.
        var minutesToEmpty: Int?
        /// Minutes until fully charged while charging; nil when unknown.
        var minutesToFull: Int?
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let controller = Unmanaged<BatteryStatusController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.refresh() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        // Power-source notifications can be sparse while discharging slowly;
        // poll once a minute so the number never goes stale.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        refresh()
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        fallbackTimer?.invalidate()
    }

    // MARK: - Status icon

    private func refresh() {
        guard let info = Self.readBattery() else {
            statusItem.isVisible = false
            return
        }
        statusItem.isVisible = true

        let color = Self.color(forPercent: info.percent)
        statusItem.button?.image = Self.makeBatteryImage(
            percent: info.percent,
            charging: info.charging,
            color: color
        )
        statusItem.button?.toolTip = info.charging
            ? "Battery \(info.percent)% (charging)"
            : "Battery \(info.percent)%"
    }

    private static func color(forPercent percent: Int) -> NSColor {
        switch percent {
        case let p where p > 40: return green
        case let p where p > 20: return amber
        default: return red
        }
    }

    // MARK: - Dropdown menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let info = Self.readBattery() else { return }

        let header = NSMenuItem()
        header.attributedTitle = NSAttributedString(
            string: "แบตเตอรี่  \(info.percent)%",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        header.isEnabled = true
        menu.addItem(header)

        let source = info.onACPower ? "อะแดปเตอร์ไฟ" : "แบตเตอรี่"
        menu.addItem(Self.infoItem("แหล่งพลังงาน: \(source)"))

        menu.addItem(.separator())

        if info.charging {
            if let minutes = info.minutesToFull {
                menu.addItem(Self.infoItem("⚡ กำลังชาร์จ — อีก \(Self.formatDuration(minutes)) จะเต็ม"))
            } else {
                menu.addItem(Self.infoItem("⚡ กำลังชาร์จ — กำลังคำนวณเวลา…"))
            }
        } else if info.onACPower {
            menu.addItem(Self.infoItem("🔌 เสียบไฟอยู่ (ไม่ได้ใช้แบตเตอรี่)"))
        } else {
            if let minutes = info.minutesToEmpty {
                menu.addItem(Self.infoItem("ใช้งานต่อได้อีกประมาณ \(Self.formatDuration(minutes))"))
            } else {
                menu.addItem(Self.infoItem("กำลังคำนวณเวลาที่เหลือ…"))
            }
        }

        menu.addItem(Self.infoItem(Self.advice(for: info)))

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "การตั้งค่าแบตเตอรี่…",
            action: #selector(openBatterySettings),
            keyEquivalent: ""
        )
        settings.target = self
        settings.isEnabled = true
        menu.addItem(settings)

        if let extra = extraMenuItemProvider?() {
            menu.addItem(.separator())
            menu.addItem(extra)
        }
    }

    /// Charge-now recommendation shown in the dropdown.
    private static func advice(for info: BatteryInfo) -> String {
        if info.charging || info.onACPower {
            return "✅ เสียบชาร์จอยู่แล้ว ไม่ต้องทำอะไรเพิ่ม"
        }
        switch info.percent {
        case let p where p > 40:
            return "🟢 ยังไม่ต้องชาร์จ ใช้งานได้สบายๆ"
        case let p where p > 20:
            return "🟡 ใกล้ต้องชาร์จแล้ว เตรียมสายชาร์จไว้ได้เลย"
        default:
            return "🔴 ควรชาร์จตอนนี้ แบตใกล้หมดแล้ว"
        }
    }

    private static func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        return item
    }

    private static func formatDuration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 && mins > 0 { return "\(hours) ชม. \(mins) นาที" }
        if hours > 0 { return "\(hours) ชม." }
        return "\(mins) นาที"
    }

    @objc private func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Power source reading

    private static func readBattery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                let current = desc[kIOPSCurrentCapacityKey] as? Int,
                let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }

            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let percent = min(Int((Double(current) / Double(max) * 100).rounded()), 100)

            var minutesToEmpty: Int?
            if let toEmpty = desc[kIOPSTimeToEmptyKey] as? Int, toEmpty > 0 {
                minutesToEmpty = toEmpty
            }
            var minutesToFull: Int?
            if let toFull = desc[kIOPSTimeToFullChargeKey] as? Int, toFull > 0 {
                minutesToFull = toFull
            }

            return BatteryInfo(
                percent: percent,
                charging: charging,
                onACPower: onAC,
                minutesToEmpty: minutesToEmpty,
                minutesToFull: minutesToFull
            )
        }
        return nil
    }

    // MARK: - Icon drawing

    /// Draws an iOS-style battery: plain outline with the percent number
    /// centered inside, colored by charge state (green/amber/red) — no fill
    /// bar behind it, so the number stays easy to read. A small bolt is
    /// added to the left while charging.
    private static func makeBatteryImage(percent: Int, charging: Bool, color: NSColor) -> NSImage {
        let bodyWidth: CGFloat = 30
        let bodyHeight: CGFloat = 14
        let nubWidth: CGFloat = 2.5
        let boltWidth: CGFloat = charging ? 10 : 0
        let size = NSSize(width: boltWidth + bodyWidth + nubWidth + 1, height: 22)

        let image = NSImage(size: size, flipped: false) { rect in
            let outline = NSColor.labelColor.withAlphaComponent(0.55)

            let bodyRect = NSRect(
                x: boltWidth,
                y: (rect.height - bodyHeight) / 2,
                width: bodyWidth,
                height: bodyHeight
            )
            let bodyPath = NSBezierPath(
                roundedRect: bodyRect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 3.5,
                yRadius: 3.5
            )
            bodyPath.lineWidth = 1
            outline.setStroke()
            bodyPath.stroke()

            let nubRect = NSRect(x: bodyRect.maxX + 0.5, y: bodyRect.midY - 2, width: nubWidth, height: 4)
            outline.setFill()
            NSBezierPath(roundedRect: nubRect, xRadius: 1.25, yRadius: 1.25).fill()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let text = NSAttributedString(
                string: "\(percent)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ]
            )
            let textHeight = text.size().height
            text.draw(in: NSRect(
                x: bodyRect.minX,
                y: bodyRect.midY - textHeight / 2,
                width: bodyRect.width,
                height: textHeight
            ))

            if charging {
                let bolt = NSAttributedString(
                    string: "\u{26A1}\u{FE0E}",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                        .foregroundColor: NSColor.labelColor,
                    ]
                )
                let boltSize = bolt.size()
                bolt.draw(at: NSPoint(
                    x: (boltWidth - boltSize.width) / 2,
                    y: rect.midY - boltSize.height / 2
                ))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
