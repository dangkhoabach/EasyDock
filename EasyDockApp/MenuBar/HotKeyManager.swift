import AppKit
import Carbon.HIToolbox
import Observation

/// The global shortcuts, same mechanism as FoldAway and KeyCellar.
enum HotKeyAction: String, CaseIterable, Identifiable {
    /// Open or close the menu bar panel from anywhere.
    case togglePanel
    /// Open the clipboard history next to the pointer.
    case clipboardPanel
    /// Start or stop a Keep Awake session.
    case keepAwake
    /// Pick a color from the screen and copy it.
    case pickColor
    /// Pin or unpin the window in front.
    case pinWindow
    /// Show or hide the Drop Zone.
    case dropZone

    var id: Self { self }

    /// ⌃⌥D ("Dock"): not taken by macOS, and away from FoldAway's ⌃⌥⌘ pair.
    var defaultHotKey: HotKey {
        switch self {
        case .togglePanel: HotKey(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(controlKey | optionKey))
        case .clipboardPanel: HotKey(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | shiftKey))
        // ⌃⌥A ("Awake"), next to the panel's ⌃⌥D.
        case .keepAwake: HotKey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | optionKey))
        case .pickColor: HotKey(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(controlKey | optionKey))
        // ⌃⌥T, after PowerToys' Win+Ctrl+T.
        case .pinWindow: HotKey(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(controlKey | optionKey))
        // ⌃⌥Z ("Zone"); ⌃⌥D already opens the panel.
        case .dropZone: HotKey(keyCode: UInt32(kVK_ANSI_Z), carbonModifiers: UInt32(controlKey | optionKey))
        }
    }

    /// Carbon identifies a registered shortcut by a small integer.
    var carbonID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }

    var keyCodeSetting: String { "hotkey.\(rawValue).keyCode" }
    var modifiersSetting: String { "hotkey.\(rawValue).modifiers" }

    /// The same words as the shortcut's row in Settings.
    var title: String {
        switch self {
        case .togglePanel: String(localized: "Open the menu bar panel", bundle: AppLocale.bundle)
        case .clipboardPanel: String(localized: "Open the clipboard history", bundle: AppLocale.bundle)
        case .keepAwake: String(localized: "Turn Keep Awake on or off", bundle: AppLocale.bundle)
        case .pickColor: String(localized: "Pick a color", bundle: AppLocale.bundle)
        case .pinWindow: String(localized: "Pin or unpin the window in front", bundle: AppLocale.bundle)
        case .dropZone: String(localized: "Show or hide the Drop Zone", bundle: AppLocale.bundle)
        }
    }
}

/// A shortcut EasyDock registers: one of the fixed ones, or one of Window
/// Snapping's, keyed "leftHalf", "custom.<UUID>" or "layout.<UUID>".
enum HotKeyTarget: Hashable {
    case app(HotKeyAction)
    case snap(String)
}

/// A key combination: Carbon key code + Carbon modifier mask (ported from
/// KeyCellar).
struct HotKey: Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// From an `NSEvent` in the recorder. `nil` when the press has no
    /// ⌘/⌥/⌃ — a bare letter must never become a global shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    /// "⌃⌥D" for Settings.
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[Int(keyCode)] { return name }
        // Letters/digits/punctuation: ask the current keyboard layout.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(keyCode)" }
        let layout = unsafeBitCast(CFDataGetBytePtr(unsafeBitCast(layoutData, to: CFData.self)), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    // MARK: Persistence

    static func load(_ action: HotKeyAction, from defaults: UserDefaults) -> HotKey {
        guard let code = defaults.object(forKey: action.keyCodeSetting) as? UInt32,
              let mods = defaults.object(forKey: action.modifiersSetting) as? UInt32
        else { return action.defaultHotKey }
        return HotKey(keyCode: code, carbonModifiers: mods)
    }

    func save(_ action: HotKeyAction, to defaults: UserDefaults) {
        defaults.set(keyCode, forKey: action.keyCodeSetting)
        defaults.set(carbonModifiers, forKey: action.modifiersSetting)
    }

    /// A Window Snapping shortcut: `fallback` until the user sets one, and
    /// nil once they clear it.
    static func loadSnap(_ key: String, fallback: HotKey?, from defaults: UserDefaults) -> HotKey? {
        if defaults.bool(forKey: "hotkey.snap.\(key).none") { return nil }
        guard let code = defaults.object(forKey: "hotkey.snap.\(key).keyCode") as? UInt32,
              let mods = defaults.object(forKey: "hotkey.snap.\(key).modifiers") as? UInt32
        else { return fallback }
        return HotKey(keyCode: code, carbonModifiers: mods)
    }

    static func saveSnap(_ hotKey: HotKey?, _ key: String, to defaults: UserDefaults) {
        defaults.set(hotKey == nil, forKey: "hotkey.snap.\(key).none")
        defaults.set(hotKey?.keyCode, forKey: "hotkey.snap.\(key).keyCode")
        defaults.set(hotKey?.carbonModifiers, forKey: "hotkey.snap.\(key).modifiers")
    }

    static func forgetSnap(_ key: String, in defaults: UserDefaults) {
        for suffix in ["none", "keyCode", "modifiers"] { defaults.removeObject(forKey: "hotkey.snap.\(key).\(suffix)") }
    }
}

/// Registers the global shortcuts with Carbon's `RegisterEventHotKey` — no
/// Accessibility permission needed, and they fire whichever app is in
/// front. One handler for the app; each combination can be swapped at
/// runtime from Settings.
@MainActor
@Observable
final class HotKeyManager {
    private(set) var hotKeys: [HotKeyAction: HotKey] = [:]
    /// Carbon refused the combination — another app holds it globally.
    private(set) var failed: Set<HotKeyAction> = []
    private let defaults: UserDefaults
    private let onPress: (HotKeyAction) -> Void
    private var registrations: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    /// What each Window Snapping shortcut is set to, by key, registered or
    /// not: Settings shows it while the feature is off, and no other
    /// shortcut may take it.
    private(set) var snapHotKeys: [String: HotKey] = [:]
    /// Carbon refused these combinations: another app holds them.
    private(set) var snapFailed: [String: HotKey] = [:]
    /// Each key's shortcut before the user changes it, nil for none.
    private var snapFallbacks: [String: HotKey?] = [:]
    /// Registered with Carbon only while the feature is on.
    private var snapActive = false
    private var snapRegistrations: [String: (hotKey: HotKey, ref: EventHotKeyRef)] = [:]
    /// Carbon IDs from 1000, clear of the fixed shortcuts' 1…99; a key keeps
    /// its ID for the session.
    private var snapCarbonIDs: [String: UInt32] = [:]
    private var nextSnapCarbonID: UInt32 = 1000
    var onSnapPress: ((String) -> Void)?

    /// Carbon calls a C function; it can't capture, so it finds us here.
    nonisolated(unsafe) private static var current: HotKeyManager?

    init(defaults: UserDefaults = .standard, onPress: @escaping (HotKeyAction) -> Void) {
        self.defaults = defaults
        self.onPress = onPress
        for action in HotKeyAction.allCases { hotKeys[action] = HotKey.load(action, from: defaults) }
    }

    func hotKey(for action: HotKeyAction) -> HotKey {
        hotKeys[action] ?? action.defaultHotKey
    }

    func start() {
        Self.current = self
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let carbonID = id.id
                Task { @MainActor in
                    guard let manager = HotKeyManager.current else { return }
                    if let action = HotKeyAction.allCases.first(where: { $0.carbonID == carbonID }) {
                        manager.onPress(action)
                    } else if let key = manager.snapCarbonIDs.first(where: { $0.value == carbonID })?.key {
                        manager.onSnapPress?(key)
                    }
                }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        for action in HotKeyAction.allCases { register(action) }
    }

    func update(_ action: HotKeyAction, to newValue: HotKey) {
        hotKeys[action] = newValue
        newValue.save(action, to: defaults)
        register(action)
    }

    // MARK: Window Snapping

    /// The Window Snapping shortcuts there are, each with the one it has
    /// before the user changes it; registered while `active`.
    func setSnapKeys(_ fallbacks: [String: HotKey?], active: Bool) {
        snapFallbacks = fallbacks
        snapActive = active
        var wanted: [String: HotKey] = [:]
        for (key, fallback) in fallbacks {
            if let hotKey = HotKey.loadSnap(key, fallback: fallback, from: defaults) { wanted[key] = hotKey }
        }
        snapHotKeys = wanted
        syncSnapRegistrations()
    }

    func snapHotKey(_ key: String) -> HotKey? {
        snapHotKeys[key]
    }

    /// Nil removes the shortcut.
    func updateSnap(_ key: String, to newValue: HotKey?) {
        HotKey.saveSnap(newValue, key, to: defaults)
        guard snapFallbacks[key] != nil else { return }
        snapHotKeys[key] = newValue
        syncSnapRegistrations()
    }

    /// For a custom size or layout that was deleted.
    func forgetSnap(_ key: String) {
        HotKey.forgetSnap(key, in: defaults)
    }

    /// Which EasyDock shortcut already uses `hotKey`, so a second one can't.
    func owner(of hotKey: HotKey) -> HotKeyTarget? {
        if let action = HotKeyAction.allCases.first(where: { self.hotKey(for: $0) == hotKey }) { return .app(action) }
        return snapHotKeys.first { $0.value == hotKey }.map { .snap($0.key) }
    }

    /// Carbon's registrations made to match `snapHotKeys`: changed ones
    /// again, a combination another app refused not retried until it changes.
    private func syncSnapRegistrations() {
        let wanted = snapActive ? snapHotKeys : [:]
        for (key, registration) in snapRegistrations where wanted[key] != registration.hotKey {
            UnregisterEventHotKey(registration.ref)
            snapRegistrations[key] = nil
        }
        snapFailed = snapFailed.filter { wanted[$0.key] == $0.value }
        for (key, hotKey) in wanted where snapRegistrations[key] == nil && snapFailed[key] == nil {
            let carbonID = snapCarbonIDs[key] ?? {
                defer { nextSnapCarbonID += 1 }
                snapCarbonIDs[key] = nextSnapCarbonID
                return nextSnapCarbonID
            }()
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x45444B59), id: carbonID)
            if RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                snapRegistrations[key] = (hotKey, ref)
            } else {
                snapFailed[key] = hotKey
            }
        }
    }

    private func register(_ action: HotKeyAction) {
        if let old = registrations[action] { UnregisterEventHotKey(old) }
        registrations[action] = nil
        let id = EventHotKeyID(signature: OSType(0x45444B59), id: action.carbonID) // "EDKY"
        let hotKey = hotKey(for: action)
        var ref: EventHotKeyRef?
        if RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr {
            registrations[action] = ref
            failed.remove(action)
        } else {
            failed.insert(action)
        }
    }
}
