import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var profileManager = ProfileManager()
    @State private var appURL: URL?
    @State private var profileName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Parallelizer")
                .font(.title2.weight(.semibold))

            Text("Clone a macOS app into a separately signed instance with its own profile home.")
                .foregroundStyle(.secondary)

            Button("Select App") {
                selectApp()
            }

            Text(appURL?.path ?? "No app selected")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            TextField("Profile Name", text: $profileName)
                .textFieldStyle(.roundedBorder)

            Button(profileManager.isWorking ? "Creating..." : "Create Parallel App") {
                guard let appURL else { return }

                Task {
                    await profileManager.createProfile(
                        appURL: appURL,
                        profileName: profileName
                    )
                }
            }
            .disabled(profileManager.isWorking || appURL == nil || profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let statusMessage = profileManager.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            }

            if let errorMessage = profileManager.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let profile = profileManager.lastCreatedProfile {
                Group {
                    Text("Cloned app: \(profile.clonedAppURL.path)")
                    Text("Profile home: \(profile.profileHomeURL.path)")
                    Text("Bundle ID: \(profile.bundleIdentifier)")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 560, height: 320)
    }

    private func selectApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK {
            appURL = panel.url
        }
    }
}
