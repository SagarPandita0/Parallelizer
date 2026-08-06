import Foundation

nonisolated enum CloneStore {

    @concurrent static func installedClones() async -> [InstalledClone] {
        let fileManager = FileManager.default
        let installRoot = ParallelEngine.cloneInstallRoot(fileManager: fileManager)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: installRoot,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "app" }
            .compactMap { clone(at: $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    @concurrent static func deleteClone(_ clone: InstalledClone, includingProfileData: Bool) async throws {
        let fileManager = FileManager.default
        try fileManager.trashItem(at: clone.appURL, resultingItemURL: nil)

        if includingProfileData, fileManager.fileExists(atPath: clone.profileRootURL.path) {
            try fileManager.trashItem(at: clone.profileRootURL, resultingItemURL: nil)
        }
    }

    private static func clone(at appURL: URL) -> InstalledClone? {
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
            let profileName = plist["ParallelizerProfileName"] as? String,
            let profileRoot = plist["ParallelizerProfileRoot"] as? String,
            let bundleIdentifier = plist["CFBundleIdentifier"] as? String
        else {
            return nil
        }

        let sourceAppName = (plist["ParallelizerSourceApp"] as? String)
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }

        return InstalledClone(
            appURL: appURL,
            displayName: appURL.deletingPathExtension().lastPathComponent,
            profileName: profileName,
            bundleIdentifier: bundleIdentifier,
            profileRootURL: URL(fileURLWithPath: profileRoot, isDirectory: true),
            sourceAppName: sourceAppName
        )
    }
}
