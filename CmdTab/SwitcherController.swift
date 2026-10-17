import AppKit
import Combine
import SwiftUI

final class SwitcherController {
    private let store = WindowStore()
    private let keyboard = KeyboardInterceptor()
    private let model = SwitcherModel()
    private let resources = ResourceMonitor()
    private var subscriptions = Set<AnyCancellable>()
    private lazy var panel = makePanel()
    private var isOpen = false
    private var showWork: DispatchWorkItem?
    private var isEnabled = true

    /// Quick ⌘⇥ taps switch without flashing the UI, like the native switcher.
    private let showDelay: TimeInterval = 0.08

    func start() -> Bool {
        model.onClick = { [weak self] index in
            self?.model.selection = index
            self?.keyboard.reset()
            self?.commit()
        }
        keyboard.onCommand = { [weak self] in self?.handle($0) }
        resources.onUpdate = { [weak self] usage in
            guard let self, self.isOpen else { return }
            self.model.usage = usage
        }
        Settings.shared.$showResourceUsage.sink { [weak self] show in
            self?.updateResourceMonitor(showUsage: show)
        }.store(in: &subscriptions)
        return keyboard.start()
    }

    func stop() {
        keyboard.stop()
        resources.stop()
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled { close() }
        isEnabled = enabled
        keyboard.setEnabled(enabled)
        updateResourceMonitor()
    }

    /// Samples only while the switcher can actually show the numbers.
    private func updateResourceMonitor(showUsage: Bool = Settings.shared.showResourceUsage) {
        if isEnabled && showUsage { resources.start() } else { resources.stop() }
        model.usage = resources.usage
    }

    private func handle(_ cmd: SwitcherCommand) {
        switch cmd {
        case .open(let reverse): open(reverse: reverse)
        case .next: model.move(1)
        case .previous: model.move(-1)
        case .commit: commit()
        case .cancel: close()
        case .closeWindow: actOnSelection { item in
            let button: AXUIElement? = item.element?.attribute(kAXCloseButtonAttribute)
            button?.perform(kAXPressAction)
        }
        case .minimizeWindow: actOnSelection { $0.element?.set(kAXMinimizedAttribute, !$0.isMinimized as CFBoolean) }
        case .hideApp: actOnSelection { _ = $0.isHidden ? $0.app.unhide() : $0.app.hide() }
        case .quitApp: actOnSelection { _ = $0.app.terminate() }
        }
    }

    private func open(reverse: Bool) {
        guard !isOpen else { return }
        isOpen = true
        model.items = store.snapshot()
        model.usage = resources.usage
        model.selection = 0
        model.move(reverse ? -1 : 1)

        let work = DispatchWorkItem { [weak self] in self?.showPanel() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    private func showPanel() {
        guard isOpen else { return }
        let size = CGSize(width: SwitcherLayout.width, height: SwitcherLayout.height(for: model.items.count))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func close() {
        isOpen = false
        showWork?.cancel()
        panel.orderOut(nil)
    }

    private func commit() {
        guard isOpen else { return }
        let item = model.items.indices.contains(model.selection) ? model.items[model.selection] : nil
        close()
        if let item { focus(item) }
    }

    private func focus(_ item: SwitcherItem) {
        let app = item.app
        if app.isHidden { app.unhide() }
        guard let el = item.element, let wid = item.windowID else {
            app.activate()
            return
        }
        if item.isMinimized { el.set(kAXMinimizedAttribute, kCFBooleanFalse) }
        store.markUsed(wid)
        Private.focus(pid: app.processIdentifier, wid: wid)
        el.perform(kAXRaiseAction)
    }

    /// Runs an action on the selected item, then refreshes the list in place.
    private func actOnSelection(_ action: (SwitcherItem) -> Void) {
        guard model.items.indices.contains(model.selection) else { return }
        action(model.items[model.selection])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isOpen else { return }
            let sel = self.model.selection
            self.model.items = self.store.snapshot()
            self.model.selection = min(sel, max(self.model.items.count - 1, 0))
            self.showPanel()
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = NSHostingView(rootView: SwitcherView(model: model))
        return p
    }
}
