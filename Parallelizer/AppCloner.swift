import AppKit
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
        // Renaming is safe for Electron bundles too: Electron reads its
        // internal app name from package.json, not the plist, and clones
        // always run with an explicit --user-data-dir.
        plist["CFBundleName"] = cloneDisplayName
        plist["CFBundleDisplayName"] = cloneDisplayName
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
        installBadgedIcon(in: appURL, plist: &plist, profileName: profileName)
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

    /// Badges the clone's icon with the profile's first letter so clones are
    /// distinguishable from the original in the Dock and Spotlight.
    /// Best-effort: any failure leaves the original icon in place.
    private func installBadgedIcon(
        in appURL: URL,
        plist: inout [String: Any],
        profileName: String
    ) {
        guard
            let letter = profileName.trimmingCharacters(in: .whitespacesAndNewlines).first,
            let baseIcon = loadBaseIcon(appURL: appURL, plist: plist)
        else {
            return
        }

        let iconURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("ParallelizerIcon.icns")

        guard writeBadgedIcon(
            base: baseIcon,
            letter: String(letter).uppercased(),
            color: Self.badgeColor(for: profileName),
            to: iconURL
        ) else {
            return
        }

        plist["CFBundleIconFile"] = "ParallelizerIcon"
        // An asset-catalog icon reference would take precedence over
        // CFBundleIconFile, so drop it.
        plist.removeValue(forKey: "CFBundleIconName")
    }

    private func loadBaseIcon(appURL: URL, plist: [String: Any]) -> NSImage? {
        if let iconFile = plist["CFBundleIconFile"] as? String, !iconFile.isEmpty {
            let fileName = iconFile.hasSuffix(".icns") ? iconFile : "\(iconFile).icns"
            let iconURL = appURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(fileName)

            if let image = NSImage(contentsOf: iconURL) {
                return image
            }
        }

        return nil
    }

    private static func badgeColor(for profileName: String) -> NSColor {
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.20, 0.47, 0.96), // blue
            (0.58, 0.35, 0.95), // purple
            (0.13, 0.65, 0.42), // green
            (0.92, 0.50, 0.15), // orange
            (0.87, 0.26, 0.53), // pink
            (0.11, 0.61, 0.68)  // teal
        ]

        // Stable hash (Swift's hashValue is seeded per launch).
        var hash: UInt64 = 5381
        for scalar in profileName.lowercased().unicodeScalars {
            hash = hash &* 33 &+ UInt64(scalar.value)
        }
        let pick = palette[Int(hash % UInt64(palette.count))]
        return NSColor(calibratedRed: pick.0, green: pick.1, blue: pick.2, alpha: 1)
    }

    private func writeBadgedIcon(base: NSImage, letter: String, color: NSColor, to iconURL: URL) -> Bool {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let destination = CGImageDestinationCreateWithURL(
            iconURL as CFURL,
            "com.apple.icns" as CFString,
            sizes.count,
            nil
        ) else {
            return false
        }

        for size in sizes {
            guard let rep = renderBadgedIcon(base: base, letter: letter, color: color, pixels: size),
                  let cgImage = rep.cgImage else {
                return false
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
        }

        return CGImageDestinationFinalize(destination)
    }

    private func renderBadgedIcon(base: NSImage, letter: String, color: NSColor, pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let canvas = CGFloat(pixels)
        base.draw(
            in: NSRect(x: 0, y: 0, width: canvas, height: canvas),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        // Badge: colored disc with the profile letter, bottom-right.
        let diameter = canvas * 0.42
        let inset = canvas * 0.04
        let badgeRect = NSRect(
            x: canvas - diameter - inset,
            y: inset,
            width: diameter,
            height: diameter
        )

        let ring = NSBezierPath(ovalIn: badgeRect)
        NSColor.white.setFill()
        ring.fill()

        let discRect = badgeRect.insetBy(dx: diameter * 0.06, dy: diameter * 0.06)
        let disc = NSBezierPath(ovalIn: discRect)
        color.setFill()
        disc.fill()

        let font = NSFont.systemFont(ofSize: diameter * 0.58, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: letter, attributes: attributes)
        let textSize = text.size()
        text.draw(at: NSPoint(
            x: discRect.midX - textSize.width / 2,
            y: discRect.midY - textSize.height / 2
        ))

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

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

        # Bootstrap a per-profile keychain so the clone can store credentials.
        # Without it, apps hit "A keychain cannot be found" because the
        # redirected HOME has no keychain. Created once with an empty
        # password and kept unlocked; deleted along with the profile.
        KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
        if [ ! -f "$KEYCHAIN" ]; then
            /bin/mkdir -p "$HOME/Library/Keychains"
            /usr/bin/security create-keychain -p '' "$KEYCHAIN" 2>/dev/null
            /usr/bin/security default-keychain -s "$KEYCHAIN" 2>/dev/null
            /usr/bin/security login-keychain -s "$KEYCHAIN" 2>/dev/null
            /usr/bin/security set-keychain-settings "$KEYCHAIN" 2>/dev/null
        fi
        /usr/bin/security unlock-keychain -p '' "$KEYCHAIN" 2>/dev/null
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
