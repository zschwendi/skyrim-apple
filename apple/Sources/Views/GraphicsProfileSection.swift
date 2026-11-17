import SwiftUI

/// One public Classic/Modern choice, local to this device's real runtime profile.
/// The synchronous idle-only mutation prevents Play from racing a preference write.
struct GraphicsProfileSection: View {
    @ObservedObject var model: LauncherModel
    @State private var status: GraphicsProfile.Status?
    @State private var problem: String?
    @State private var changing = false

    private var supported: Bool { model.runtime == .nativeDevice || model.runtime == .macBridge }
    private var store: GraphicsProfileStore {
        // Resolve the runtime's case-insensitive Windows path, then mark its final
        // component as a file rather than the resolver's default directory URL.
        let resolved = SkyrimSaveLocations.resolve(["Documents", "My Games", "Skyrim", "SkyrimPrefs.ini"], in: SkyrimSaveLocations.runtimeRoot)
        return GraphicsProfileStore(preferencesURL: GraphicsProfile.fileURL(resolved: resolved),
            metadataDirectory: SkyrimSaveLocations.supportDirectory.appendingPathComponent("GraphicsProfiles", isDirectory: true))
    }
    private var coordinator: GraphicsVisualModeCoordinator { .forLauncher(model) }
    private var locked: Bool { !GraphicsProfile.canApply(runtimeReady: model.runtimeReady, supported: supported,
        gameIsActive: model.isGameActive, isBusy: model.isBusy, changing: changing, hasPreferences: status != nil) }

    var body: some View {
        Section {
            Picker("Graphics profile", selection: Binding(get: { status?.mode ?? .classic }, set: apply)) {
                Text("Classic").tag(GraphicsProfile.Mode.classic)
                Text("Modern").tag(GraphicsProfile.Mode.modern)
            }
            .pickerStyle(.segmented)
            .disabled(locked)
            if changing { ProgressView("Applying graphics…") }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.secondary)
            } else if let status, !status.conflicts.isEmpty {
                Text("Classic restored. Kept \(status.conflicts.count) customized graphics value\(status.conflicts.count == 1 ? "" : "s"): \(status.conflicts.joined(separator: ", ")).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Graphics Profile")
        } footer: {
            Text(explanation)
        }
        .onAppear(perform: refresh)
        .onChange(of: model.isGameActive) { _, active in if !active { refresh() } }
        .onChange(of: model.runtimeReady) { _, _ in refresh() }
    }

    private var explanation: String {
        if model.isGameActive { return "Quit Skyrim to change profiles. Changes apply the next time you launch; a paused game is still running." }
        if !supported || !model.runtimeReady { return "A verified native runtime and an existing SkyrimPrefs.ini are required." }
        return "Modern improves shadows, distant detail, grass, water and filtering. Native device builds also include 2K ground textures and matching normal maps. Classic restores your previous graphics values and textures. Native resolution and your other settings stay as they are. Changes apply next launch."
    }
    private func refresh() {
        guard !model.isGameActive, !changing else { return }
        guard supported, model.runtimeReady else { status = nil; problem = nil; return }
        do { status = try coordinator.status(gameIsActive: model.isGameActive, isBusy: model.isBusy); problem = nil }
        catch { status = nil; problem = error.localizedDescription }
    }
    private func apply(_ mode: GraphicsProfile.Mode) {
        guard !locked else { return }
        changing = true; defer { changing = false }
        do {
            status = try coordinator.apply(mode, gameIsActive: model.isGameActive, isBusy: model.isBusy)
            problem = nil
        } catch {
            problem = error.localizedDescription
            if let actual = try? store.status() { status = actual }
        }
    }
}
