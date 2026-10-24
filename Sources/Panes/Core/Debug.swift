import Foundation

/// Opt-in diagnostics: `defaults write local.thomas.panes PanesDebug -bool YES`,
/// then read with `log stream --predicate 'process == "Panes"'`.
enum Debug {
    /// Read once at launch (restart Panes after changing it): checking defaults on
    /// every mouse event would cost more than the logging itself.
    static let enabled = UserDefaults.standard.bool(forKey: "PanesDebug")

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("Panes: %@", message())
    }
}
