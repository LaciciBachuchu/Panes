import Foundation

/// Opt-in diagnostics: `defaults write local.thomas.panes PanesDebug -bool YES`,
/// restart Panes, then read ~/Library/Logs/Panes.log.
enum Debug {
    /// Read once at launch: checking defaults on every mouse event would cost
    /// more than the logging itself.
    static let enabled = UserDefaults.standard.bool(forKey: "PanesDebug")

    private static let handle: FileHandle? = {
        guard enabled else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Panes.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled, let handle else { return }
        let line = "\(time.string(from: Date())) \(message())\n"
        handle.write(Data(line.utf8))
    }
}
