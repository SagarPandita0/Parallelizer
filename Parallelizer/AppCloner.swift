import Foundation

nonisolated final class AppCloner: Sendable {
    @concurrent func cloneApp(originalURL: URL, profileName rawProfileName: String) async throws -> ParallelProfile {
        let fileManager = FileManager.default

        guard originalURL.pathExtension == "app" else {
            throw ParallelizerError.invalidAppBundle(originalURL)
        }

        let profileName = ParallelEngine.sanitizedProfileName(rawProfileName)
        guard !profileName.isEmpty else {
            throw ParallelizerError.emptyProfileName
        }

        let appName = ParallelEngine.appDisplayName(for: originalURL)
        let cloneDisplayName = ParallelEngine.cloneDisplayName(appName: appName, profileName: profileName)
        let installRoot = ParallelEngine.cloneInstallRoot(fileManager: fileManager)
        let profileRootURL = ParallelEngine.profileRoot(appName: appName, profileName: profileName, fileManager: fileManager)
        let profileHomeURL = ParallelEngine.profileHome(profileRoot: profileRootURL)
        let clonedAppURL = installRoot.appendingPathComponent("\(cloneDisplayName).app", isDirectory: true)

        try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)
        // Existing profile data is preserved so re-cloning refreshes the app
        // bundle without losing logins or settings.
        try createProfileDirectories(profileRootURL)

        if fileManager.fileExists(atPath: clonedAppURL.path) {
            try fileManager.removeItem(at: clonedAppURL)
        }

        try fileManager.copyItem(at: originalURL, to: clonedAppURL)

        let bundleIdentifier = try modifyBundle(
            clonedAppURL,
            sourceAppURL: originalURL,
            sourceAppName: appName,
            cloneDisplayName: cloneDisplayName,
            profileName: profileName,
            profileRootURL: profileRootURL,
            profileHomeURL: profileHomeURL
        )

        return ParallelProfile(
            sourceAppURL: originalURL,
            clonedAppURL: clonedAppURL,
            profileRootURL: profileRootURL,
            profileHomeURL: profileHomeURL,
            sourceAppName: appName,
            cloneDisplayName: cloneDisplayName,
            profileName: profileName,
            bundleIdentifier: bundleIdentifier
        )
    }

    private func createProfileDirectories(_ profileRootURL: URL) throws {
        let fileManager = FileManager.default

        for directory in ParallelEngine.bootstrapDirectories(profileRoot: profileRootURL) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func modifyBundle(
        _ appURL: URL,
        sourceAppURL: URL,
        sourceAppName: String,
        cloneDisplayName: String,
        profileName: String,
        profileRootURL: URL,
        profileHomeURL: URL
    ) throws -> String {
        let fileManager = FileManager.default
        let plistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")

        guard fileManager.fileExists(atPath: plistURL.path) else {
            throw ParallelizerError.missingInfoPlist(plistURL)
        }

        let plistData = try Data(contentsOf: plistURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw ParallelizerError.unreadableInfoPlist(plistURL)
        }

        let bundleIdentifier = try ParallelEngine.bundleIdentifier(
            originalBundleIdentifier: plist["CFBundleIdentifier"] as? String,
            appName: sourceAppName,
            profileName: profileName
        )

        let isElectronBundle = isElectronApp(plist: plist, appURL: appURL)

        plist["CFBundleIdentifier"] = bundleIdentifier
        if !isElectronBundle {
            plist["CFBundleName"] = cloneDisplayName
            plist["CFBundleDisplayName"] = cloneDisplayName
        }
        plist["ParallelizerProfileName"] = profileName
        plist["ParallelizerProfileRoot"] = profileRootURL.path
        plist["ParallelizerProfileHome"] = profileHomeURL.path
        plist["ParallelizerSourceApp"] = sourceAppURL.path
        plist["ParallelizerIsElectron"] = isElectronBundle
        try validateExecutable(in: appURL, plist: plist)

        // The clone's main executable becomes a generated shim that exports
        // the profile environment and execs the real binary. launchd strips
        // HOME from LSEnvironment, so a shim is the only way isolation holds
        // for every launch path (Finder, Dock, Spotlight, open).
        let originalExecutable = plist["CFBundleExecutable"] as? String ?? ""
        try installLaunchShim(
            in: appURL,
            originalExecutable: originalExecutable,
            profileRootURL: profileRootURL,
            profileHomeURL: profileHomeURL,
            isElectronBundle: isElectronBundle
        )
        plist["ParallelizerOriginalExecutable"] = originalExecutable
        plist["CFBundleExecutable"] = Self.shimExecutableName
        try updateNestedHelperBundles(
            in: appURL,
            mainBundleIdentifier: bundleIdentifier,
            rewriteHelperDisplayNames: !isElectronBundle
        )

        let updatedPlistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        )

        try updatedPlistData.write(to: plistURL, options: .atomic)
        return bundleIdentifier
    }

    static let shimExecutableName = "parallelizer-launcher"

    private func installLaunchShim(
        in appURL: URL,
        originalExecutable: String,
        profileRootURL: URL,
        profileHomeURL: URL,
        isElectronBundle: Bool
    ) throws {
        let macOSDirectory = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        let shimURL = macOSDirectory.appendingPathComponent(Self.shimExecutableName)

        let overrides = ParallelEngine.launchEnvironmentOverrides(
            profileRoot: profileRootURL,
            profileHome: profileHomeURL
        )
        let exports = overrides
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellQuoted($0.value))" }
            .joined(separator: "\n")

        var launchLine = "exec \"$SCRIPT_DIR\"/\(shellQuoted(originalExecutable))"
        var electronSetup = ""
        if isElectronBundle {
            let userDataDirectory = profileRootURL.appendingPathComponent("electron-user-data", isDirectory: true)
            electronSetup = "/bin/mkdir -p \(shellQuoted(userDataDirectory.path))\n"
            launchLine += " --user-data-dir=\(shellQuoted(userDataDirectory.path))"
        }
        launchLine += " \"$@\""

        let script = """
        #!/bin/zsh
        # Generated by Parallelizer. Applies the profile environment for every
        # launch path, then hands off to the real executable.
        \(exports)
        /bin/mkdir -p "$HOME" "$TMPDIR"
        \(electronSetup)SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        \(launchLine)
        """

        try script.write(to: shimURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func validateExecutable(
        in appURL: URL,
        plist: [String: Any]
    ) throws {
        let fileManager = FileManager.default
        guard let executableName = plist["CFBundleExecutable"] as? String, !executableName.isEmpty else {
            throw ParallelizerError.invalidExecutableName
        }

        let macOSDirectory = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        let executableURL = macOSDirectory.appendingPathComponent(executableName)

        guard fileManager.fileExists(atPath: executableURL.path) else {
            throw ParallelizerError.missingExecutable(executableURL.path)
        }
    }

    private func updateNestedHelperBundles(
        in appURL: URL,
        mainBundleIdentifier: String,
        rewriteHelperDisplayNames: Bool
    ) throws {
        let frameworksURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: frameworksURL.path) else {
            return
        }

        let helperApps = try fileManager.contentsOfDirectory(
            at: frameworksURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "app" }

        for helperAppURL in helperApps {
            try updateHelperBundle(
                helperAppURL: helperAppURL,
                mainBundleIdentifier: mainBundleIdentifier,
                rewriteDisplayNames: rewriteHelperDisplayNames
            )
        }
    }

    private func updateHelperBundle(
        helperAppURL: URL,
        mainBundleIdentifier: String,
        rewriteDisplayNames: Bool
    ) throws {
        let plistURL = helperAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: plistURL.path) else {
            return
        }

        let plistData = try Data(contentsOf: plistURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw ParallelizerError.unreadableInfoPlist(plistURL)
        }

        let helperSuffix = helperBundleSuffix(for: helperAppURL.deletingPathExtension().lastPathComponent)
        let helperBundleIdentifier = "\(mainBundleIdentifier).\(ParallelEngine.slug(helperSuffix).replacingOccurrences(of: "-", with: "."))"

        plist["CFBundleIdentifier"] = helperBundleIdentifier
        if rewriteDisplayNames {
            let helperBaseName = appNameBase(fromBundleIdentifier: mainBundleIdentifier)
            let helperDisplayName = "\(helperBaseName) \(helperSuffix)"
            plist["CFBundleName"] = helperDisplayName
            plist["CFBundleDisplayName"] = helperDisplayName
        }

        let updatedPlistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        )

        try updatedPlistData.write(to: plistURL, options: .atomic)
    }

    private func helperBundleSuffix(for helperAppName: String) -> String {
        let helperPrefix = " Helper"
        guard let range = helperAppName.range(of: helperPrefix) else {
            return helperAppName
        }

        let suffix = String(helperAppName[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? "Helper" : suffix
    }

    private func isElectronApp(plist: [String: Any], appURL: URL) -> Bool {
        if plist["ElectronAsarIntegrity"] != nil {
            return true
        }

        let frameworksURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: frameworksURL.path) else {
            return false
        }

        return contents.contains { $0.hasSuffix(" Helper.app") || $0.contains(" Helper (") }
    }

    private func appNameBase(fromBundleIdentifier bundleIdentifier: String) -> String {
        let component = bundleIdentifier
            .split(separator: ".")
            .dropFirst()
            .dropLast()
            .joined(separator: ".")

        if component.isEmpty {
            return bundleIdentifier
        }

        return component
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
