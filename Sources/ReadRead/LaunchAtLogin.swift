import Foundation
import ServiceManagement

/// Launch at login (R4-15), as the system reports it.
enum LoginItemStatus: Equatable, Sendable {
    case enabled
    /// Registered, but the user has to allow it in System Settings › General › Login Items & Extensions.
    case requiresApproval
    case disabled
    /// Not an app bundle (`swift run`, `swift test`): SMAppService is not asked.
    case unavailable
}

/// The login item behind a protocol: the app uses `SMAppService.mainApp`, tests a fake.
@MainActor
protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    /// System Settings › General › Login Items & Extensions (where `requiresApproval` is resolved).
    func openSystemSettings()
}

/// `SMAppService.mainApp`: the app bundle itself as a login item (macOS 13+, no helper).
@MainActor
final class MainAppLoginItem: LoginItemControlling {
    private var service: SMAppService { .mainApp }

    var status: LoginItemStatus {
        // Outside a .app (swift run) the service refers to nothing useful.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        return Self.status(for: service.status)
    }

    /// The system's status in ReadRead's terms. `.notFound` is no error: it is what an app the
    /// system knows nothing about yet reports (a fresh install, never registered), and what it
    /// reports again after the user removes it in System Settings › Login Items. Both are off,
    /// and `register()` turns it on (Apple DTS: developer.apple.com/forums/thread/721737 and
    /// /thread/760186).
    nonisolated static func status(for status: SMAppService.Status) -> LoginItemStatus {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
