import Foundation

struct ParallelProfile: Identifiable, Hashable {
    let id = UUID()
    let sourceAppURL: URL
    let clonedAppURL: URL
    let profileRootURL: URL
    let profileHomeURL: URL
    let sourceAppName: String
    let cloneDisplayName: String
    let profileName: String
    let bundleIdentifier: String
}

enum ParallelizerError: LocalizedError {
    case emptyProfileName
    case invalidAppBundle(URL)
    case missingInfoPlist(URL)
    case unreadableInfoPlist(URL)
    case missingExecutable(String)
    case invalidExecutableName
    case invalidBundleIdentifier(String)
    case commandFailed(command: String, status: Int32, output: String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyProfileName:
            return "Enter a profile name before creating a clone."
        case .invalidAppBundle(let url):
            return "The selected app bundle is invalid: \(url.path)"
        case .missingInfoPlist(let url):
            return "The cloned app is missing Info.plist: \(url.path)"
        case .unreadableInfoPlist(let url):
            return "Info.plist could not be read: \(url.path)"
        case .missingExecutable(let name):
            return "The app executable was not found: \(name)"
        case .invalidExecutableName:
            return "The app bundle did not declare a valid executable name."
        case .invalidBundleIdentifier(let value):
            return "A safe bundle identifier could not be generated from '\(value)'."
        case .commandFailed(let command, let status, let output):
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOutput.isEmpty {
                return "\(command) failed with exit code \(status)."
            }
            return "\(command) failed with exit code \(status): \(trimmedOutput)"
        case .launchFailed(let message):
            return "The cloned app could not be launched: \(message)"
        }
    }
}
