import Foundation

/// Keeps the graphics INI and bundled texture ownership in one idle-only operation.
/// This layer never changes saves, archive lists, resolution or game bindings.
final class GraphicsVisualModeCoordinator {
    let profile: GraphicsProfileStore
    private let dataDirectory: URL?
    private let supportDirectory: URL
    private let packDirectory: URL?

    @MainActor
    static func forLauncher(_ model: LauncherModel) -> GraphicsVisualModeCoordinator {
        let resolved = SkyrimSaveLocations.resolve(["Documents", "My Games", "Skyrim", "SkyrimPrefs.ini"], in: SkyrimSaveLocations.runtimeRoot)
        let store = GraphicsProfileStore(preferencesURL: GraphicsProfile.fileURL(resolved: resolved),
            metadataDirectory: SkyrimSaveLocations.supportDirectory.appendingPathComponent("GraphicsProfiles", isDirectory: true))
        let game = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Skyrim", isDirectory: true)
        let data = model.runtime == .nativeDevice ? SkyrimSaveLocations.resolve(["Data"], in: game) : nil
        return GraphicsVisualModeCoordinator(profile: store, dataDirectory: data,
            supportDirectory: SkyrimSaveLocations.supportDirectory,
            packDirectory: Bundle.main.url(forResource: "pack", withExtension: nil))
    }

    init(profile: GraphicsProfileStore, dataDirectory: URL?, supportDirectory: URL, packDirectory: URL?) {
        self.profile = profile
        self.dataDirectory = dataDirectory
        self.supportDirectory = supportDirectory
        self.packDirectory = packDirectory
    }

    private func assets() throws -> ModernVisualAssets? {
        guard let dataDirectory else { return nil }
        return try ModernVisualAssets(dataDirectory: dataDirectory, supportDirectory: supportDirectory,
                                      packDirectory: packDirectory)
    }

    private func textureMode(_ mode: GraphicsProfile.Mode) -> ModernVisualAssets.Mode {
        mode == .modern ? .modern : .classic
    }

    func status(gameIsActive: Bool, isBusy: Bool) throws -> GraphicsProfile.Status {
        try idle(gameIsActive, isBusy)
        let current = try profile.status()
        if let assets = try assets() {
            let recovered = try assets.recover(configurationMode: textureMode(current.mode))
            guard recovered.canLaunch else {
                throw ModernVisualAssets.Failure("Graphics textures need attention: " + recovered.conflicts.joined(separator: ", "))
            }
        }
        return current
    }

    @discardableResult
    func apply(_ mode: GraphicsProfile.Mode, gameIsActive: Bool, isBusy: Bool) throws -> GraphicsProfile.Status {
        try idle(gameIsActive, isBusy)
        if mode == .modern { try checkLooseTexturePolicy() }
        guard let assets = try assets() else {
            return try profile.apply(mode, gameIsActive: gameIsActive, isBusy: isBusy)
        }
        let before = try profile.checkpoint()
        let recovered = try assets.recover(configurationMode: textureMode(before.mode))
        guard recovered.canLaunch else { throw ModernVisualAssets.Failure("A previous texture change needs recovery before switching profiles.") }
        var configured = false
        var after: GraphicsProfileStore.Checkpoint?
        _ = try assets.apply(textureMode(mode), configuration: {
            _ = try self.profile.apply(mode, gameIsActive: gameIsActive, isBusy: isBusy)
            configured = true
            after = try self.profile.checkpoint()
        }, rollbackConfiguration: {
            guard configured else { return }
            guard let after else { throw ModernVisualAssets.Failure("Graphics settings need recovery before Skyrim can launch.") }
            _ = try self.profile.restore(before, replacing: after, gameIsActive: gameIsActive, isBusy: isBusy)
        })
        return try profile.status()
    }

    /// Called once before the real launch, never from the frame/status loop.
    /// Also installs the bundled pack for a verified, migrated Modern profile.
    @discardableResult
    func prepareForLaunch() throws -> GraphicsProfile.Mode {
        let current: GraphicsProfile.Status
        do { current = try profile.status() }
        catch GraphicsProfile.Issue.missingPreferences {
            // The original game creates its preferences on its first launch.
            let state = profile.metadataDirectory.appendingPathComponent("state.json")
            guard !FileManager.default.fileExists(atPath: state.path) else { throw GraphicsProfile.Issue.missingPreferences }
            if let assets = try assets() {
                let initial = try assets.status()
                guard initial.mode == .classic, initial.canLaunch else { throw GraphicsProfile.Issue.missingPreferences }
            }
            return .classic
        }
        if current.mode == .modern { try checkLooseTexturePolicy() }
        if let assets = try assets() {
            let recovered = try assets.recover(configurationMode: textureMode(current.mode))
            guard recovered.canLaunch else { throw ModernVisualAssets.Failure("Graphics texture recovery must finish before Skyrim can launch.") }
            if recovered.mode != textureMode(current.mode) {
                _ = try apply(current.mode, gameIsActive: false, isBusy: false)
            }
        }
        return current.mode
    }

    private func idle(_ active: Bool, _ busy: Bool) throws {
        if active { throw GraphicsProfile.Issue.gameActive }
        if busy { throw GraphicsProfile.Issue.busy }
    }

    private func checkLooseTexturePolicy() throws {
        guard dataDirectory != nil else { return }
        // Classic 1.9.32 defaults: bInvalidateOlderFiles=1 and a prefix list
        // containing TEXTURES\. No SSE/FO4 sResourceDataDirsFinal key exists.
        let directory = profile.preferencesURL.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let matches = names.filter { $0.caseInsensitiveCompare("Skyrim.ini") == .orderedSame }
        guard matches.count <= 1 else { throw ModernVisualAssets.Failure("Multiple Skyrim settings files need attention before Modern can apply.") }
        guard let name = matches.first else { return }
        let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
        let unicodeBOM = bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF])
        let decoded = unicodeBOM ? String(data: bytes, encoding: .utf16) :
            (String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252))
        guard let text = decoded else {
            throw ModernVisualAssets.Failure("Skyrim's texture-loading settings could not be read safely.")
        }
        var section = "", values: [String: String] = [:]
        let unmarked = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        for raw in unmarked.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                section = String(line[line.index(after: line.startIndex)..<end]).trimmingCharacters(in: .whitespaces).lowercased(); continue
            }
            guard section == "archive", let split = line.firstIndex(of: "=") else { continue }
            let key = line[..<split].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "binvalidateolderfiles" || key == "sresourceprefixlist" else { continue }
            let value = line[line.index(after: split)...]
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = values[key], existing != normalized {
                throw ModernVisualAssets.Failure("Conflicting Skyrim texture-loading settings need attention before Modern can apply.")
            }
            values[key] = normalized
        }
        if let value = values["binvalidateolderfiles"] {
            guard let number = Int32(value), number != 0 else {
                throw ModernVisualAssets.Failure("Custom Skyrim settings disable replacement textures. Restore the game's default file-loading settings or choose Classic.")
            }
        }
        if let prefixes = values["sresourceprefixlist"], !prefixes.split(separator: ",").contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "\\").uppercased() == "TEXTURES\\"
        }) {
            throw ModernVisualAssets.Failure("Custom Skyrim settings exclude replacement textures. Restore the game's default file-loading settings or choose Classic.")
        }
    }
}
