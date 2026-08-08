import Foundation

nonisolated final class CodeSigner: Sendable {
    @concurrent func sign(appURL: URL) async throws {
        try removeQuarantineIfPresent(appURL: appURL)

        // A stable identity keeps keychain ACLs and permission grants valid
        // across re-clones; ad-hoc is the fallback if it cannot be created.
        let identity = SigningIdentity.ensureIdentity()
        var arguments = ["--force", "--deep", "--sign", identity?.name ?? "-"]
        if let identity {
            arguments.append(contentsOf: ["--keychain", identity.keychainPath])
        }
        arguments.append(contentsOf: ["--timestamp=none", appURL.path])

        try runProcess(executable: "/usr/bin/codesign", arguments: arguments)

        try runProcess(
            executable: "/usr/bin/codesign",
            arguments: [
                "--verify",
                "--deep",
                "--strict",
                appURL.path
            ]
        )
    }

    private func removeQuarantineIfPresent(appURL: URL) throws {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", appURL.path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return
        }

        let notPresent = output.contains("No such xattr") || output.contains("No such file")
        if !notPresent {
            throw ParallelizerError.commandFailed(
                command: "xattr",
                status: process.terminationStatus,
                output: output
            )
        }
    }

    private func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw ParallelizerError.commandFailed(
                command: URL(fileURLWithPath: executable).lastPathComponent,
                status: process.terminationStatus,
                output: output
            )
        }
    }
}
