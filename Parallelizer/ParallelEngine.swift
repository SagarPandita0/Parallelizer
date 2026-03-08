import Foundation

enum ParallelEngine {

    static func sanitizedProfileName(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    static func appDisplayName(for appURL: URL) -> String {
        appURL.deletingPathExtension().lastPathComponent
    }

    static func slug(_ value: String) -> String {
        let lowercase = value.lowercased()
        let scalars = lowercase.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }

            return "-"
        }

        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")

        return collapsed.isEmpty ? "profile" : collapsed
    }

    static func bundleIdentifier(originalBundleIdentifier: String?, appName: String, profileName: String) throws -> String {
        let baseSource = originalBundleIdentifier?.isEmpty == false ? originalBundleIdentifier! : appName
        let base = slug(baseSource.replacingOccurrences(of: ".", with: "-"))
        let profile = slug(profileName)
        let identifier = "parallelizer.\(base).\(profile)"

        if identifier.split(separator: ".").contains(where: \.isEmpty) {
            throw ParallelizerError.invalidBundleIdentifier(identifier)
        }

        return identifier
    }

    static func cloneDisplayName(appName: String, profileName: String) -> String {
        "\(appName) \(profileName)"
    }

    static func cloneInstallRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Parallelizer", isDirectory: true)
    }

    static func profileRoot(appName: String, profileName: String, fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("ParallelizerProfiles", isDirectory: true)
            .appendingPathComponent(slug(appName), isDirectory: true)
            .appendingPathComponent(slug(profileName), isDirectory: true)
    }

    static func profileHome(profileRoot: URL) -> URL {
        profileRoot.appendingPathComponent("home", isDirectory: true)
    }

    static func bootstrapDirectories(profileRoot: URL) -> [URL] {
        let home = profileHome(profileRoot: profileRoot)

        return [
            profileRoot,
            home,
            profileRoot.appendingPathComponent("tmp", isDirectory: true),
            home.appendingPathComponent("Library", isDirectory: true),
            home.appendingPathComponent("Library/Application Support", isDirectory: true),
            home.appendingPathComponent("Library/Caches", isDirectory: true),
            home.appendingPathComponent("Library/Logs", isDirectory: true),
            home.appendingPathComponent("Library/Preferences", isDirectory: true),
            home.appendingPathComponent(".config", isDirectory: true),
            home.appendingPathComponent(".cache", isDirectory: true)
        ]
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
