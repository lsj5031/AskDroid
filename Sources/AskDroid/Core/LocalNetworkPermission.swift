import AppKit
import Foundation
import Network

/// One-time primer for the macOS Local Network privacy prompt.
/// A new build is a new binary from the system's point of view — the first
/// local-network connection hides its permission dialog behind the HUD and the
/// first turn fails with `Connection error.` (see `askdroid.log` 19:44:58).
/// Prime *before* the first turn, with the HUD hidden, so the dialog is frontmost.
enum LocalNetworkPermission {
    private static var primedKey: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "hasPrimedLocalNetwork_\(version)_\(build)"
    }

    static var shouldPrime: Bool {
        // Don't pause turns in tests — XCTest shares UserDefaults and the
        // prime would either block every first submit or pollute the flag.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        if NSClassFromString("XCTestCase") != nil { return false }
        return !UserDefaults.standard.bool(forKey: primedKey)
    }

    /// Fire a throw-away local-network connection. The system shows its
    /// "Allow AskDroid to find devices on your local network?" prompt on the
    /// first such connection. No data is sent; the connection is cancelled after ~1s.
    static func prime() {
        guard shouldPrime else { return }
        UserDefaults.standard.set(true, forKey: primedKey)
        let conn = NWConnection(host: NWEndpoint.Host("192.168.1.1"), port: NWEndpoint.Port(integerLiteral: 80), using: .tcp)
        conn.stateUpdateHandler = { _ in }
        conn.start(queue: .global(qos: .utility))
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
            conn.cancel()
        }
        AskLog.line("local network prime triggered \(primedKey)")
    }

    /// Opens System Settings directly on the Local Network pane.
    static func openSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                AskLog.line("opened local network settings \(raw)")
                return
            }
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!)
    }
}
