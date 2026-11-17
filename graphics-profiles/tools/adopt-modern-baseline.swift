import Foundation

/// Host-side migration for an existing manually upgraded profile. Use copied
/// preferences from a fully closed game; this tool never talks to a device.
@main struct AdoptModernBaseline {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            FileHandle.standardError.write(Data("Usage: adopt-modern-baseline CURRENT_PREFS METADATA_DIRECTORY ORIGINAL_PREFS\nUse host-side copies from a fully closed game. Current preferences are never changed.\n".utf8))
            exit(64)
        }
        do {
            let store = GraphicsProfileStore(preferencesURL: URL(fileURLWithPath: arguments[1], isDirectory: false),
                metadataDirectory: URL(fileURLWithPath: arguments[2], isDirectory: true))
            try store.adoptModernBaseline(originalPreferences: Data(contentsOf: URL(fileURLWithPath: arguments[3], isDirectory: false)),
                gameIsActive: false, isBusy: false)
            print("Verified Modern baseline adopted. Current preferences are unchanged.")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
