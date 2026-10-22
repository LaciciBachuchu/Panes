import Foundation

/// Opt-in diagnostics: `defaults write local.thomas.panes PanesDebug -bool YES`,
/// then read with `log stream --predicate 'process == "Panes"'`.
enum Debug {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "PanesDebug") }

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        NSLog("Panes: %@", message())
    }
}
