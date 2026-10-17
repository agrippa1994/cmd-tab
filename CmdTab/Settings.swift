import AppKit
import ServiceManagement
import SwiftUI

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Key {
        static let isEnabled = "isEnabled"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let shiftNavigatesBack = "shiftNavigatesBack"
        static let showResourceUsage = "showResourceUsage"
    }

    /// When off, the native ⌘⇥ is restored and CmdTab stays idle in the background.
    @Published var isEnabled: Bool { didSet { UserDefaults.standard.set(isEnabled, forKey: Key.isEnabled) } }
    @Published var showMenuBarIcon: Bool { didSet { UserDefaults.standard.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }
    /// Pressing ⇧ while the switcher is open selects the previous window; Tab then always moves forward.
    @Published var shiftNavigatesBack: Bool { didSet { UserDefaults.standard.set(shiftNavigatesBack, forKey: Key.shiftNavigatesBack) } }
    /// Show each app's CPU and memory usage in the switcher rows.
    @Published var showResourceUsage: Bool { didSet { UserDefaults.standard.set(showResourceUsage, forKey: Key.showResourceUsage) } }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [Key.isEnabled: true, Key.showMenuBarIcon: true, Key.shiftNavigatesBack: false, Key.showResourceUsage: true])
        isEnabled = d.bool(forKey: Key.isEnabled)
        showMenuBarIcon = d.bool(forKey: Key.showMenuBarIcon)
        shiftNavigatesBack = d.bool(forKey: Key.shiftNavigatesBack)
        showResourceUsage = d.bool(forKey: Key.showResourceUsage)
    }
}

/// Launch at login via the system Login Items (stored by macOS, not in our defaults).
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable window switcher", isOn: $settings.isEnabled)
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { setLaunchAtLogin($0) }
                ))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Approve CmdTab in Login Items to finish.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                }
            } footer: {
                Text("While disabled, the native ⌘⇥ is restored.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
            } footer: {
                Text("With the icon hidden, open CmdTab again (e.g. from Finder or Spotlight) to show this window.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Press ⇧ to select the previous window", isOn: $settings.shiftNavigatesBack)
            } header: {
                Text("Navigation")
            } footer: {
                Text("While holding ⌘, tap ⇧ to move back instead of pressing ⇧⇥. Tab always moves forward.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show CPU and memory usage", isOn: $settings.showResourceUsage)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Per app, including its helper processes. Sampled every 2 seconds while enabled.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Quit CmdTab") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = LoginItem.status
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = LoginItem.status
    }
}

final class SettingsWindowController {
    private lazy var window: NSWindow = {
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: .shared)))
        w.title = "CmdTab Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }()

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
