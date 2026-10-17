import AppKit
import Carbon.HIToolbox

enum SwitcherCommand {
    case open(reverse: Bool)
    case next, previous
    case commit, cancel
    case closeWindow, minimizeWindow, hideApp, quitApp
}

/// Disables the Dock's ⌘⇥ and replaces it with a CGEventTap.
final class KeyboardInterceptor {
    var onCommand: ((SwitcherCommand) -> Void)?

    private var tap: CFMachPort?
    /// Touched only from the tap callback (main run loop); decides synchronously whether to swallow.
    private var isActive = false

    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let me = Unmanaged<KeyboardInterceptor>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Private.setNativeSwitcherEnabled(false)
        return true
    }

    func stop() {
        Private.setNativeSwitcherEnabled(true)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            if isActive && !event.flags.contains(.maskCommand) {
                isActive = false
                send(.commit)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let cmd = flags.contains(.maskCommand)
            let shift = flags.contains(.maskShift)
            let others = flags.contains(.maskAlternate) || flags.contains(.maskControl)

            if !isActive {
                guard cmd, !others, key == kVK_Tab else { return Unmanaged.passUnretained(event) }
                isActive = true
                send(.open(reverse: shift))
                return nil
            }

            switch key {
            case kVK_Tab: send(shift ? .previous : .next)
            case kVK_DownArrow, kVK_RightArrow: send(.next)
            case kVK_UpArrow, kVK_LeftArrow: send(.previous)
            case kVK_Escape: isActive = false; send(.cancel)
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: isActive = false; send(.commit)
            case kVK_ANSI_W: send(.closeWindow)
            case kVK_ANSI_M: send(.minimizeWindow)
            case kVK_ANSI_H: send(.hideApp)
            case kVK_ANSI_Q: send(.quitApp)
            default: break
            }
            return nil // swallow everything while the switcher is open

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Called by the controller if the switcher closes for other reasons (e.g. mouse click).
    func reset() { isActive = false }

    private func send(_ cmd: SwitcherCommand) {
        // Keep the tap callback fast; process in order on the main queue.
        DispatchQueue.main.async { self.onCommand?(cmd) }
    }
}
