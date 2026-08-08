import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var profileManager = ProfileManager()
    @State private var appURL: URL?
    @State private var profileName = ""
    @State private var cloneToDelete: InstalledClone?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            createSection
            Divider()
            clonesSection
            footer
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
        .task {
            await profileManager.refreshClones()
        }
        .confirmationDialog(
            "Delete \(cloneToDelete?.displayName ?? "clone")?",
            isPresented: Binding(
                get: { cloneToDelete != nil },
                set: { if !$0 { cloneToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete App, Keep Profile Data") {
                deletePendingClone(includingProfileData: false)
            }
            Button("Delete App and Profile Data", role: .destructive) {
                deletePendingClone(includingProfileData: true)
            }
            Button("Cancel", role: .cancel) {
                cloneToDelete = nil
            }
        } message: {
            Text("The clone is moved to the Trash. Profile data holds the clone's logins and settings.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Parallelizer")
                .font(.title2.weight(.semibold))
            Text("Run multiple independent copies of the same macOS app, each with its own profile home.")
                .foregroundStyle(.secondary)
        }
    }

    private var createSection: some View {
        GroupBox("New Clone") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button("Select App…") {
                        selectApp()
                    }
                    Text(appURL.map { ParallelEngine.appDisplayName(for: $0) } ?? "No app selected — or drop an app here")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 12) {
                    TextField("Profile name (e.g. Work, Personal)", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .onSubmit(createClone)

                    Button(action: createClone) {
                        if profileManager.isWorking {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Working…")
                            }
                        } else {
                            Text("Create Parallel App")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private var clonesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installed Clones")
                .font(.headline)

            if profileManager.clones.isEmpty {
                Text("No clones yet. Select an app and give it a profile name to create one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List(profileManager.clones) { clone in
                    cloneRow(clone)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func cloneRow(_ clone: InstalledClone) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: clone.appURL.path))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(clone.displayName)
                    .fontWeight(.medium)
                Text(clone.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if clone.updateAvailable, let cloneVersion = clone.cloneVersion, let sourceVersion = clone.sourceVersion {
                    Text("Update available: \(cloneVersion) → \(sourceVersion)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button {
                Task { await profileManager.launchClone(clone) }
            } label: {
                Label("Launch", systemImage: "play.fill")
            }
            .disabled(profileManager.isWorking)

            Button {
                Task { await profileManager.refreshClone(clone) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-clone from the original app, keeping profile data. Use this to update a clone.")
            .disabled(profileManager.isWorking || clone.sourceAppURL == nil)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([clone.appURL])
            } label: {
                Label("Reveal", systemImage: "magnifyingglass")
            }

            Button(role: .destructive) {
                cloneToDelete = clone
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(profileManager.isWorking)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var footer: some View {
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
    }

    private var canCreate: Bool {
        !profileManager.isWorking
            && appURL != nil
            && !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func deletePendingClone(includingProfileData: Bool) {
        guard let clone = cloneToDelete else { return }
        cloneToDelete = nil

        Task {
            await profileManager.deleteClone(clone, includingProfileData: includingProfileData)
        }
    }

    private func createClone() {
        guard canCreate, let appURL else { return }

        Task {
            await profileManager.createProfile(
                appURL: appURL,
                profileName: profileName
            )
        }
    }

    private func selectApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        if panel.runModal() == .OK {
            appURL = panel.url
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension == "app" else { return }
            Task { @MainActor in
                appURL = url
            }
        }
        return true
    }
}
