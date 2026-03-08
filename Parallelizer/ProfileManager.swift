import Combine
import Foundation

@MainActor
final class ProfileManager: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var lastCreatedProfile: ParallelProfile?
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let cloner: AppCloner
    private let signer: CodeSigner
    private let launcher: AppLauncher

    init(
        cloner: AppCloner = AppCloner(),
        signer: CodeSigner = CodeSigner(),
        launcher: AppLauncher = AppLauncher()
    ) {
        self.cloner = cloner
        self.signer = signer
        self.launcher = launcher
    }

    func createProfile(appURL: URL, profileName: String) async {
        guard !isWorking else { return }

        isWorking = true
        statusMessage = nil
        errorMessage = nil

        defer { isWorking = false }

        do {
            let profile = try cloner.cloneApp(originalURL: appURL, profileName: profileName)
            try signer.sign(appURL: profile.clonedAppURL)
            try await launcher.launch(appURL: profile.clonedAppURL)

            lastCreatedProfile = profile
            statusMessage = "Created \(profile.cloneDisplayName) with isolated data at \(profile.profileRootURL.path)."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
