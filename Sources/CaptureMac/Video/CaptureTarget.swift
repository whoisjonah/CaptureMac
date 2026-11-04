import AppKit
import ScreenCaptureKit

enum CaptureTarget: Codable, Hashable {
    case display(CGDirectDisplayID)
    case app(bundleID: String, name: String)
    case window(title: String, bundleID: String, name: String)

    var title: String {
        switch self {
        case .display(let id):
            NSScreen.screens.first { $0.displayID == id }?.localizedName ?? "Display"
        case .app(_, let name):
            name
        case .window(let title, _, let name):
            title.isEmpty ? name : title
        }
    }

    var bundleID: String? {
        switch self {
        case .display: nil
        case .app(let bundleID, _), .window(_, let bundleID, _): bundleID
        }
    }

    var symbol: String {
        switch self {
        case .display: "display"
        case .app: "app.dashed"
        case .window: "macwindow"
        }
    }
}

struct ResolvedTarget {
    let filter: SCContentFilter
    let pixelSize: CGSize
    let app: AppIdentity?
    let windowID: CGWindowID?
}

struct ShareableSources {
    var displays: [SCDisplay] = []
    var apps: [SCRunningApplication] = []
    var windows: [SCWindow] = []

    static func load() async throws -> ShareableSources {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = content.windows.filter { window in
            guard let app = window.owningApplication, app.processID != ownPID else { return false }
            return window.windowLayer == 0 && window.frame.width >= 200 && window.frame.height >= 150 && !app.bundleIdentifier.isEmpty
        }
        let owners = Set(windows.compactMap { $0.owningApplication?.processID })
        let apps = content.applications
            .filter { owners.contains($0.processID) }
            .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
        return ShareableSources(displays: content.displays, apps: apps, windows: windows)
    }

    func resolve(_ target: CaptureTarget) -> ResolvedTarget? {
        switch target {
        case .display(let id):
            guard let display = displays.first(where: { $0.displayID == id }) ?? displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            return ResolvedTarget(filter: filter, pixelSize: Self.pixelSize(of: display), app: nil, windowID: nil)

        case .app(let bundleID, _):
            guard let window = mainWindow(bundleID: bundleID) else { return nil }
            return resolved(window)

        case .window(let title, let bundleID, _):
            let candidates = windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
            guard let window = candidates.first(where: { $0.title == title && $0.isOnScreen }) ?? mainWindow(bundleID: bundleID) else { return nil }
            return resolved(window)
        }
    }

    private func mainWindow(bundleID: String) -> SCWindow? {
        windows
            .filter { $0.owningApplication?.bundleIdentifier == bundleID }
            .max { lhs, rhs in
                if lhs.isOnScreen != rhs.isOnScreen { return !lhs.isOnScreen }
                return lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
    }

    private func resolved(_ window: SCWindow) -> ResolvedTarget {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let size = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
        let app = window.owningApplication.map {
            AppIdentity(bundleID: $0.bundleIdentifier, pid: $0.processID, name: $0.applicationName)
        }
        return ResolvedTarget(filter: filter, pixelSize: size, app: app, windowID: window.windowID)
    }

    private static func pixelSize(of display: SCDisplay) -> CGSize {
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        return CGSize(width: display.width * 2, height: display.height * 2)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
