// Windows Panes has parked past the screen edge (scroll strip, slide over) must
// never be left there. Their frames to go back to are written to disk while parked;
// quitting (or SIGTERM/SIGINT/SIGHUP) puts them back at once, and the next launch
// restores whatever a crash left behind.
// Pattern adapted from WindowShade (MIT, https://github.com/surfine/WindowShade):
// prototype/Recovery/Journal.swift.

import AppKit

enum ParkedJournal {
    struct Entry: Codable {
        var owner: String            // which feature parked it
        var pid: Int32
        var bundleID: String?
        var windowID: UInt32
        var x: Double, y: Double, w: Double, h: Double
    }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Panes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("parked-windows.json")
    }

    private static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func store(_ entries: [Entry]) {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Replaces one feature's entries.
    static func record(_ owner: String, _ windows: [(AXWindow, CGRect)]) {
        var all = load().filter { $0.owner != owner }
        for (w, f) in windows {
            guard let id = w.cgWindowID else { continue }
            all.append(Entry(owner: owner, pid: w.pid, bundleID: w.bundleID, windowID: id,
                             x: f.minX, y: f.minY, w: f.width, h: f.height))
        }
        store(all)
    }

    static func clear(_ owner: String) {
        store(load().filter { $0.owner != owner })
    }

    /// At launch: put back whatever the last run left parked.
    static func recover() {
        let entries = load()
        guard !entries.isEmpty else { return }
        for e in entries {
            guard let app = NSRunningApplication(processIdentifier: e.pid), !app.isTerminated,
                  app.bundleIdentifier == e.bundleID,
                  let w = AXWindow.windows(of: e.pid).first(where: { $0.cgWindowID == e.windowID }) else { continue }
            w.setFrame(CGRect(x: e.x, y: e.y, width: e.w, height: e.h))
            Debug.log("parked: recovered \(e.bundleID ?? "?") (\(e.owner))")
        }
        store([])
    }

    private static var signalSources: [DispatchSourceSignal] = []

    /// Quit and termination signals restore parked windows before Panes goes away.
    static func installTerminationHandlers(restore: @escaping () -> Void) {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                restore()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}
