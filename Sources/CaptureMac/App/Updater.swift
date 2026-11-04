import AppKit
import Foundation
import Observation

struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

struct UpdateError: LocalizedError {
    var errorDescription: String?
}

@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate, installing
        case available(String)
        case failed(String)
    }

    private(set) var state = State.idle
    private var release: Release?
    private var timer: Timer?

    private static let latestURL = URL(string: "https://api.github.com/repos/whoisjonah/CaptureMac/releases/latest")!
    private static let interval: TimeInterval = 6 * 60 * 60

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var availableVersion: String? {
        if case .available(let version) = state { return version }
        return nil
    }

    func start() {
        guard Preferences.shared.checksForUpdates else { return }
        Task { await check() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in
                guard Preferences.shared.checksForUpdates else { return }
                await Updater.shared.check()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func check() async {
        guard state != .checking, state != .installing else { return }
        state = .checking
        do {
            var request = URLRequest(url: Self.latestURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError(errorDescription: "couldn't reach github")
            }
            let latest = try JSONDecoder().decode(Release.self, from: data)
            release = latest
            state = Self.isNewer(latest.version, than: currentVersion) ? .available(latest.version) : .upToDate
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func install() {
        guard let release, state != .installing else { return }
        guard !Recorder.shared.isRecordingSession else {
            state = .failed("finish recording first")
            return
        }
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path),
              let asset = release.assets.first(where: { $0.name == "CaptureMac.zip" }) else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }

        state = .installing
        Task {
            do {
                let app = try await Self.download(asset.browserDownloadURL)
                _ = try FileManager.default.replaceItemAt(bundle, withItemAt: app)
                Self.relaunch(bundle)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        let lhs = version.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func download(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(errorDescription: "the download failed")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("CaptureMac.zip")
        try FileManager.default.moveItem(at: file, to: zip)

        try await Task.detached {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, folder.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                throw UpdateError(errorDescription: "couldn't unzip the update")
            }
        }.value

        let app = folder.appendingPathComponent("CaptureMac.app")
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError(errorDescription: "the update doesn't look right")
        }
        return app
    }

    private static func relaunch(_ bundle: URL) {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", bundle.path]
        try? shell.run()
        NSApp.terminate(nil)
    }
}
