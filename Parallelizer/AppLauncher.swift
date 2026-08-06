import AppKit
import Foundation

final class AppLauncher {
    nonisolated init() {}

    func launch(appURL: URL) async throws {
        let bundleMetadata = try loadBundleMetadata(appURL: appURL)
        let process = Process()
        process.executableURL = bundleMetadata.executableURL
        process.currentDirectoryURL = bundleMetadata.executableURL.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ParallelizerError.launchFailed(error.localizedDescription)
        }

        try await activateLaunchedApp(bundleIdentifier: bundleMetadata.bundleIdentifier, fallbackProcess: process)
    }

    private func loadBundleMetadata(appURL: URL) throws -> BundleMetadata {
        let plistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")

        guard
            let plistData = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
            ) as? [String: Any],
            let executableName = plist["CFBundleExecutable"] as? String,
            !executableName.isEmpty,
            let bundleIdentifier = plist["CFBundleIdentifier"] as? String
        else {
            throw ParallelizerError.unreadableInfoPlist(plistURL)
        }

        let executableURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName)

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw ParallelizerError.missingExecutable(executableURL.path)
        }

        return BundleMetadata(
            bundleIdentifier: bundleIdentifier,
            executableURL: executableURL
        )
    }

    private func activateLaunchedApp(bundleIdentifier: String, fallbackProcess: Process) async throws {
        for _ in 0..<20 {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                app.activate()
                return
            }

            if !fallbackProcess.isRunning {
                return
            }

            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private struct BundleMetadata {
        let bundleIdentifier: String
        let executableURL: URL
    }
}
