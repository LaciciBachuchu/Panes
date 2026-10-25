import AppKit
import ApplicationServices

/// Observes a handful of AX notifications for one app; tears down on deinit.
final class AXWatch {
    private var observer: AXObserver?
    private let handler: (String) -> Void

    init?(pid: pid_t, notifications: [String], handler: @escaping (String) -> Void) {
        self.handler = handler
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, name, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AXWatch>.fromOpaque(refcon).takeUnretainedValue()
            me.handler(name as String)
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return nil }
        observer = obs
        let app = AXUIElementCreateApplication(pid)
        let ref = Unmanaged.passUnretained(self).toOpaque()
        for n in notifications { AXObserverAddNotification(obs, app, n as CFString, ref) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    deinit {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
    }
}

