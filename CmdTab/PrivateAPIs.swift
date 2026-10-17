import AppKit
import ApplicationServices

// Private SkyLight / HIServices symbols, the same set AltTab imports.
// Resolved at runtime via dlsym so we don't need to link a private framework.

typealias CGSConnectionID = UInt32

private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private let hiServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)

private func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as _: T.Type) -> T? {
    guard let p = dlsym(handle, name) else {
        NSLog("CmdTab: missing private symbol \(name)")
        return nil
    }
    return unsafeBitCast(p, to: T.self)
}

enum Private {
    // CGS / SLS
    private static let _mainConnectionID = sym(skyLight, "CGSMainConnectionID", as: (@convention(c) () -> CGSConnectionID).self)
    private static let _setSymbolicHotKeyEnabled = sym(skyLight, "CGSSetSymbolicHotKeyEnabled", as: (@convention(c) (Int32, Bool) -> CGError).self)
    private static let _copySpacesForWindows = sym(skyLight, "CGSCopySpacesForWindows", as: (@convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?).self)
    private static let _copyManagedDisplaySpaces = sym(skyLight, "CGSCopyManagedDisplaySpaces", as: (@convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?).self)
    private static let _setFrontProcessWithOptions = sym(skyLight, "_SLPSSetFrontProcessWithOptions", as: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError).self)
    private static let _postEventRecordTo = sym(skyLight, "SLPSPostEventRecordTo", as: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError).self)

    // HIServices
    private static let _axGetWindow = sym(hiServices, "_AXUIElementGetWindow", as: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
    private static let _axCreateWithRemoteToken = sym(hiServices, "_AXUIElementCreateWithRemoteToken", as: (@convention(c) (CFData) -> Unmanaged<AXUIElement>?).self)
    private static let _getProcessForPID = sym(hiServices, "GetProcessForPID", as: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus).self)

    static var connection: CGSConnectionID { _mainConnectionID?() ?? 0 }

    // Symbolic hotkey IDs used by the Dock's app switcher.
    enum SymbolicHotKey: Int32, CaseIterable {
        case commandTab = 1
        case commandShiftTab = 2
    }

    static func setNativeSwitcherEnabled(_ enabled: Bool) {
        for key in SymbolicHotKey.allCases {
            _ = _setSymbolicHotKeyEnabled?(key.rawValue, enabled)
        }
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        guard _axGetWindow?(element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    /// Brute-forces AX element IDs to find windows the app doesn't report in
    /// kAXWindowsAttribute (i.e. windows on other Spaces). Token layout:
    /// pid (4) | 0 (4) | 'coco' (4) | element id (8).
    static func windowsViaRemoteToken(pid: pid_t, maxID: UInt64 = 1000) -> [AXUIElement] {
        guard let create = _axCreateWithRemoteToken else { return [] }
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: pid, toByteOffset: 0, as: pid_t.self)
            buf.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            buf.storeBytes(of: Int32(0x636f_636f), toByteOffset: 8, as: Int32.self)
        }
        var result: [AXUIElement] = []
        for id in 0..<maxID {
            token.withUnsafeMutableBytes { $0.storeBytes(of: id, toByteOffset: 12, as: UInt64.self) }
            guard let el = create(token as CFData)?.takeRetainedValue() else { continue }
            if let subrole: String = el.attribute(kAXSubroleAttribute),
               subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole {
                result.append(el)
            }
        }
        return result
    }

    /// Space IDs of all spaces, in Mission Control order (across displays).
    static func orderedSpaceIDs() -> [UInt64] {
        guard let displays = _copyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return displays.flatMap { display -> [UInt64] in
            (display["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        }
    }

    static func spaceIDs(for wid: CGWindowID) -> [UInt64] {
        let mask: Int32 = 0x7 // current | other | user spaces
        guard let arr = _copySpacesForWindows?(connection, mask, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return arr.map(\.uint64Value)
    }

    /// Brings a specific window of a process to front (yabai/AltTab technique).
    static func focus(pid: pid_t, wid: CGWindowID) {
        var psn = ProcessSerialNumber()
        guard _getProcessForPID?(pid, &psn) == noErr else { return }
        _ = _setFrontProcessWithOptions?(&psn, wid, 0x200) // kCPSUserGenerated
        makeKeyWindow(&psn, wid)
    }

    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) {
        guard let post = _postEventRecordTo else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: wid) { w in
            for i in 0..<4 { bytes[0x3c + i] = w[i] }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { post(&psn, $0.baseAddress!) }
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { post(&psn, $0.baseAddress!) }
    }
}

extension AXUIElement {
    func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func set(_ name: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }

    func perform(_ action: String) {
        AXUIElementPerformAction(self, action as CFString)
    }
}
