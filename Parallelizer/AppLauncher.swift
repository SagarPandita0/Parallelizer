import AppKit
import Foundation

final class AppLauncher {
    nonisolated init() {}

    func launch(appURL: URL) async throws {
        let bundleMetadata = try loadBundleMetadata(appURL: appURL)
        let process = Process()
        process.executableURL = bundleMetadata.executableURL
        process.currentDirectoryURL = bundleMetadata.executableURL.deletingLastPathComponent()
        process.environment = launchEnvironment(metadata: bundleMetadata)
        process.arguments = launchArguments(metadata: bundleMetadata)
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
            let bundle = Bundle(url: appURL),
            let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
            !executableName.isEmpty,
            let bundleIdentifier = bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String,
            let profileRoot = bundle.object(forInfoDictionaryKey: "ParallelizerProfileRoot") as? String,
            let profileHome = bundle.object(forInfoDictionaryKey: "ParallelizerProfileHome") as? String
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
            executableURL: executableURL,
            profileRootURL: URL(fileURLWithPath: profileRoot, isDirectory: true),
            profileHomeURL: URL(fileURLWithPath: profileHome, isDirectory: true),
            isElectron: bundle.object(forInfoDictionaryKey: "ElectronAsarIntegrity") != nil
        )
    }

    private func launchEnvironment(metadata: BundleMetadata) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = metadata.profileHomeURL.path
        environment["CFFIXED_USER_HOME"] = metadata.profileHomeURL.path
        environment["XDG_CONFIG_HOME"] = metadata.profileHomeURL.appendingPathComponent(".config", isDirectory: true).path
        environment["XDG_CACHE_HOME"] = metadata.profileHomeURL.appendingPathComponent(".cache", isDirectory: true).path
        environment["TMPDIR"] = metadata.profileRootURL.appendingPathComponent("tmp", isDirectory: true).path
        environment["PARALLELIZER_PROFILE_ROOT"] = metadata.profileRootURL.path
        return environment
    }

    private func launchArguments(metadata: BundleMetadata) -> [String] {
        guard metadata.isElectron else {
            return []
        }

        let userDataDirectory = metadata.profileRootURL.appendingPathComponent("electron-user-data", isDirectory: true)
        try? FileManager.default.createDirectory(at: userDataDirectory, withIntermediateDirectories: true)
        return ["--user-data-dir=\(userDataDirectory.path)"]
    }

    private func activateLaunchedApp(bundleIdentifier: String, fallbackProcess: Process) async throws {
        for _ in 0..<20 {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                app.activate(options: [.activateIgnoringOtherApps])
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
        let profileRootURL: URL
        let profileHomeURL: URL
        let isElectron: Bool
    }
}
