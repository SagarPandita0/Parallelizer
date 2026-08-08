import Foundation

/// A private self-signed code-signing identity shared by all clones.
///
/// Ad-hoc signatures change on every re-clone, which makes macOS treat the
/// refreshed clone as a different app: keychain item ACLs and TCC grants
/// stop matching and the user is re-prompted. Signing every clone with one
/// stable identity keeps those approvals valid across re-clones and app
/// updates. The identity lives in its own empty-password keychain so
/// signing never prompts.
nonisolated enum SigningIdentity {
    static let identityName = "Parallelizer Signing"

    private static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Parallelizer", isDirectory: true)
    }

    private static var keychainURL: URL {
        supportDirectory.appendingPathComponent("signing.keychain-db")
    }

    /// Returns the stable identity, creating it on first use.
    /// Returns nil when creation fails; callers fall back to ad-hoc.
    static func ensureIdentity() -> (name: String, keychainPath: String)? {
        let keychainPath = keychainURL.path

        if identityExists(keychainPath: keychainPath) {
            _ = try? run("/usr/bin/security", ["unlock-keychain", "-p", "", keychainPath])
            return (identityName, keychainPath)
        }

        do {
            try createIdentity(keychainPath: keychainPath)
            return (identityName, keychainPath)
        } catch {
            return nil
        }
    }

    private static func identityExists(keychainPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: keychainPath) else {
            return false
        }

        // No -v: a self-signed certificate is not "valid" to trust
        // evaluation, but codesign can still sign with it.
        guard let output = try? run(
            "/usr/bin/security",
            ["find-identity", "-p", "codesigning", keychainPath]
        ) else {
            return false
        }

        return output.contains(identityName)
    }

    private static func createIdentity(keychainPath: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: keychainPath) {
            try fileManager.removeItem(atPath: keychainPath)
        }

        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("parallelizer-signing-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let keyPath = workDirectory.appendingPathComponent("key.pem").path
        let certificatePath = workDirectory.appendingPathComponent("cert.pem").path
        let identityBundlePath = workDirectory.appendingPathComponent("identity.p12").path
        // Transient p12 transport password; the bundle is deleted right
        // after import and the key then lives in the empty-password keychain.
        let transportPassword = "parallelizer"

        _ = try run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
            "-keyout", keyPath,
            "-out", certificatePath,
            "-subj", "/CN=\(identityName)",
            "-addext", "keyUsage=digitalSignature",
            "-addext", "extendedKeyUsage=codeSigning",
            "-addext", "basicConstraints=critical,CA:false"
        ])
        _ = try run("/usr/bin/openssl", [
            "pkcs12", "-export",
            "-out", identityBundlePath,
            "-inkey", keyPath,
            "-in", certificatePath,
            "-passout", "pass:\(transportPassword)"
        ])
        _ = try run("/usr/bin/security", ["create-keychain", "-p", "", keychainPath])
        _ = try run("/usr/bin/security", ["set-keychain-settings", keychainPath])
        _ = try run("/usr/bin/security", ["unlock-keychain", "-p", "", keychainPath])
        _ = try run("/usr/bin/security", [
            "import", identityBundlePath,
            "-k", keychainPath,
            "-f", "pkcs12",
            "-P", transportPassword,
            "-T", "/usr/bin/codesign"
        ])
        // Lets Apple's tools use the key without a confirmation prompt.
        _ = try run("/usr/bin/security", [
            "set-key-partition-list",
            "-S", "apple-tool:,apple:,codesign:",
            "-s", "-k", "", keychainPath
        ])
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw ParallelizerError.commandFailed(
                command: URL(fileURLWithPath: executable).lastPathComponent,
                status: process.terminationStatus,
                output: output
            )
        }

        return output
    }
}
