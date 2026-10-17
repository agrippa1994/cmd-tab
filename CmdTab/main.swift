import AppKit
import ApplicationServices
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: SwitcherController?
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?
    private let settings = Settings.shared
    private let settingsWindow = SettingsWindowController()
    private var enabledMenuItem: NSMenuItem?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        installSignalHandlers()
        observeSettings()

        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            startSwitcher()
        } else {
            // Wait until the user grants Accessibility in System Settings.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard AXIsProcessTrusted() else { return }
                t.invalidate()
                self?.startSwitcher()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        Private.setNativeSwitcherEnabled(true)
    }

    /// Launching the app again (Finder, Spotlight, `open`) shows the settings — the only way in when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func startSwitcher() {
        let c = SwitcherController()
        guard c.start() else {
            NSLog("CmdTab: failed to create event tap")
            return
        }
        c.setEnabled(settings.isEnabled)
        controller = c
    }

    private func observeSettings() {
        settings.$isEnabled.sink { [weak self] enabled in
            self?.controller?.setEnabled(enabled)
            self?.enabledMenuItem?.state = enabled ? .on : .off
            self?.statusItem?.button?.appearsDisabled = !enabled
        }.store(in: &subscriptions)
        settings.$showMenuBarIcon.sink { [weak self] show in
            self?.statusItem?.isVisible = show
        }.store(in: &subscriptions)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "command", accessibilityDescription: "CmdTab")
        let menu = NSMenu()
        enabledMenuItem = menu.addItem(withTitle: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledMenuItem?.target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CmdTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleEnabled() { settings.isEnabled.toggle() }

    @objc private func showSettings() { settingsWindow.show() }

    /// Always give ⌘⇥ back to the Dock, even when killed from a terminal.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { _ in
                Private.setNativeSwitcherEnabled(true)
                exit(0)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
