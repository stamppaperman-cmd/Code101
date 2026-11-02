import Foundation
import ServiceManagement

/// "Open StampLab at login" via SMAppService — no helper app or LaunchAgent.
/// The switch reads the real registration state, so turning it off in
/// System Settings > General > Login Items shows up here too.
enum LaunchAtLogin {
    private static let defaultAppliedKey = "launchAtLoginDefaultApplied"

    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// macOS sometimes wants the user to approve it in System Settings first.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("StampLab: launch at login \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    /// On by default, once: after that the user's choice in the switch wins.
    static func applyDefaultOnce() {
        guard !UserDefaults.standard.bool(forKey: defaultAppliedKey) else { return }
        UserDefaults.standard.set(true, forKey: defaultAppliedKey)
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            break
        default:
            // .notRegistered — or .notFound, which a never-registered app
            // reports on some systems.
            set(on: true)
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
