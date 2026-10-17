import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: SwitcherController?
    private var statusItem: NSStatusItem?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        installSignalHandlers()

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

    private func startSwitcher() {
        let c = SwitcherController()
        guard c.start() else {
            NSLog("CmdTab: failed to create event tap")
            return
        }
        controller = c
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "command", accessibilityDescription: "CmdTab")
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit CmdTab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

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
