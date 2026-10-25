import AppKit
import Carbon.HIToolbox

/// Registers global hotkeys through Carbon (no extra permission needed).
/// Hotkeys are dropped while an excluded app is frontmost so keystrokes pass
/// through to it — e.g. remote-desktop and VM clients.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private var suspended = false
    /// Set while the shortcut recorder is capturing, so presses don't fire actions.
    var paused = false { didSet { reload() } }

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKeyManager.shared.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let excluded = Settings.shared.isExcluded(app?.bundleIdentifier)
            if excluded != self?.suspended {
                self?.suspended = excluded
                self?.reload()
            }
        }
    }

    func reload() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll(); handlers.removeAll(); nextID = 1
        guard !suspended, !paused else { return }

        let s = Settings.shared.data
        for action in s.actions {
            guard let sc = action.shortcut, Settings.shared.isEnabled(action.kind) else { continue }
            register(sc) { WindowManager.shared.perform(action) }
        }
        for layout in s.layouts {
            guard let sc = layout.shortcut else { continue }
            register(sc) { LayoutManager.shared.restore(layout) }
        }
    }

    private func register(_ sc: Shortcut, _ handler: @escaping () -> Void) {
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x504E4553), id: id) // 'PNES'
        let err = RegisterEventHotKey(sc.keyCode, sc.modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if err == noErr, let ref {
            refs.append(ref)
            handlers[id] = handler
        } else {
            NSLog("Panes: could not register \(sc.displayString) (\(err)) — probably taken by another app")
        }
    }
}
