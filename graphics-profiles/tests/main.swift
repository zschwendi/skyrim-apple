import Foundation

enum CheckFailure: Error { case injected, failed(String) }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure.failed(message) }
}
func expectFailure(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw CheckFailure.failed("Expected failure: " + message)
}

final class RecordingIO: GraphicsProfileFileIO, @unchecked Sendable {
    enum Failure: Equatable { case none, backup, managed, snapshot, journal, preferences, finalState, postWritePreferences, interruptedAfterWrite, externalUnknownChange }
    let preferences: URL
    var failure: Failure = .none
    var events: [String] = []
    var stateWrites = 0
    var preferenceWrites = 0
    init(preferences: URL) { self.preferences = preferences }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func read(_ url: URL) throws -> Data { events.append("read:" + url.lastPathComponent); return try Data(contentsOf: url) }
    func makeDirectory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    func writeAtomic(_ data: Data, to url: URL) throws {
        let name = url.lastPathComponent; events.append("write:" + name)
        if name == "state.json" { stateWrites += 1 }
        if url == preferences { preferenceWrites += 1 }
        if failure == .backup && name == "before.ini" { throw CheckFailure.injected }
        if failure == .managed && name == "managed-before.json" { throw CheckFailure.injected }
        if failure == .snapshot && name == "snapshot.json" { throw CheckFailure.injected }
        if failure == .journal && name == "state.json" { throw CheckFailure.injected }
        if failure == .preferences && url == preferences { throw CheckFailure.injected }
        if failure == .finalState && name == "state.json" && stateWrites == 2 { throw CheckFailure.injected }
        if failure == .interruptedAfterWrite && ((name == "state.json" && stateWrites == 2) || (url == preferences && preferenceWrites == 2)) { throw CheckFailure.injected }
        try data.write(to: url, options: .atomic)
        if failure == .postWritePreferences && url == preferences && preferenceWrites == 1 { throw CheckFailure.injected }
        if failure == .externalUnknownChange && name == "state.json" && stateWrites == 1 {
            var current = try Data(contentsOf: preferences); current.append(Data("\n; externally added\n".utf8)); try current.write(to: preferences, options: .atomic)
        }
    }
}

@main struct GraphicsProfileChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skyrim-graphics-check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var number = 0
        func fixture(_ bytes: Data) throws -> (URL, URL, GraphicsProfileStore) {
            number += 1
            let directory = root.appendingPathComponent(String(number), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let prefs = directory.appendingPathComponent("SkyrimPrefs.ini")
            try bytes.write(to: prefs, options: .atomic)
            let metadata = directory.appendingPathComponent("GraphicsProfiles", isDirectory: true)
            return (prefs, metadata, GraphicsProfileStore(preferencesURL: prefs, metadataDirectory: metadata))
        }
        let original = Data(("; untouched comment\r\n[Display]\r\niSize W=2420\r\niSize H=1668\r\niTexMipMapSkip=0\r\niMultiSample=1\r\niMaxAnisotropy = 8 ; retain comment\r\nfShadowDistance=2000.0000\r\n[Controls]\r\nbGamepadEnable=1\r\nfMouseHeadingSensitivity=0.0125\r\n[AudioMenu]\r\nfAudioMasterVolume=0.7\r\n[Unrecognized]\r\nCloudSyncUserValue=keep\r\nlast option=no final newline").utf8)
        try check(GraphicsProfile.modern.count == 31, "Exactly 31 managed keys")
        try check(!GraphicsProfile.modern.contains { ["isize w","isize h","itexmipmapskip","imultisample"].contains($0.key.name.lowercased()) }, "Native pixels, mips and MSAA unowned")
        let (prefs, metadata, store) = try fixture(original)
        try check(try store.status().mode == .classic, "Initial Classic")
        try store.apply(.modern, gameIsActive: false, isBusy: false)
        let modernBytes = try Data(contentsOf: prefs)
        try check(try GraphicsProfileINI(data: modernBytes).isModern, "All Modern keys read back")
        let modernText = String(decoding: modernBytes, as: UTF8.self)
        for preserved in ["iSize W=2420", "iSize H=1668", "iTexMipMapSkip=0", "iMultiSample=1", "bGamepadEnable=1", "fAudioMasterVolume=0.7", "CloudSyncUserValue=keep", "; retain comment"] {
            try check(modernText.contains(preserved), "Preserved " + preserved)
        }
        let firstBackups = try FileManager.default.contentsOfDirectory(at: metadata, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != "state.json" }
        try check(firstBackups.count == 1, "One baseline transaction")
        let backup = firstBackups[0].appendingPathComponent("before.ini")
        try check(try Data(contentsOf: backup) == original, "Exact verified backup")
        try store.apply(.classic, gameIsActive: false, isBusy: false)
        try check(try Data(contentsOf: prefs) == original, "Exact round trip including missing keys/sections/EOF")
        try check(try Data(contentsOf: backup) == original, "Immutable first baseline")

        let duplicates = Data("; odd formatting\n[display] ; keep section\nIMAXANISOTROPY=2\niMaxAnisotropy = 4 # note\n[DISPLAY]\nimaxanisotropy=8\nunknown=preserve\n".utf8)
        let (duplicatePrefs, _, duplicateStore) = try fixture(duplicates)
        try duplicateStore.apply(.modern, gameIsActive: false, isBusy: false)
        try check(try GraphicsProfileINI(data: Data(contentsOf: duplicatePrefs)).isModern, "Case and all duplicates patched")
        try duplicateStore.apply(.classic, gameIsActive: false, isBusy: false)
        try check(try Data(contentsOf: duplicatePrefs) == duplicates, "Duplicate original lines restored")
        let (eofPrefs, _, eofStore) = try fixture(Data("[Display]\niMaxAnisotropy=8".utf8))
        try eofStore.apply(.modern, gameIsActive: false, isBusy: false)
        var eofText = try String(contentsOf: eofPrefs, encoding: .utf8)
        eofText = eofText.replacingOccurrences(of: "iMaxAnisotropy=16\n", with: "iMaxAnisotropy=16\nNewUnknownOption=stay\n")
        try Data(eofText.utf8).write(to: eofPrefs, options: .atomic)
        try eofStore.apply(.classic, gameIsActive: false, isBusy: false)
        try check(String(decoding: try Data(contentsOf: eofPrefs), as: UTF8.self).contains("iMaxAnisotropy=8\nNewUnknownOption=stay\n"), "Former EOF owned line never joins a new unknown option")

        let (customPrefs, _, customStore) = try fixture(original)
        try customStore.apply(.modern, gameIsActive: false, isBusy: false)
        var custom = try String(contentsOf: customPrefs, encoding: .utf8)
        custom = custom.replacingOccurrences(of: "fShadowDistance=4000.0000", with: "fShadowDistance=8192.0") + "\r\nUserNewOption=keep\r\n"
        try Data(custom.utf8).write(to: customPrefs, options: .atomic)
        let restored = try customStore.apply(.classic, gameIsActive: false, isBusy: false)
        let customClassic = try Data(contentsOf: customPrefs)
        try check(restored.conflicts == ["[Display] fShadowDistance"], "Conflict surfaced")
        let customClassicText = String(decoding: customClassic, as: UTF8.self)
        try check(customClassicText.contains("fShadowDistance=8192.0"), "User changed graphics retained")
        try check(customClassicText.contains("UserNewOption=keep"), "Unknown new option retained")
        try customStore.apply(.modern, gameIsActive: false, isBusy: false)
        try customStore.apply(.classic, gameIsActive: false, isBusy: false)
        try check(try Data(contentsOf: customPrefs) == customClassic, "Next cycle captures current Classic including custom values")

        // Asset transaction rollback must retain the prior Modern baseline and
        // custom values; applying the opposite mode would lose that history.
        let (rollbackPrefs, _, rollbackStore) = try fixture(original)
        try rollbackStore.apply(.modern, gameIsActive: false, isBusy: false)
        var priorModern = try String(contentsOf: rollbackPrefs, encoding: .utf8)
        priorModern = priorModern.replacingOccurrences(of: "fShadowDistance=4000.0000", with: "fShadowDistance=8192.0")
        try Data(priorModern.utf8).write(to: rollbackPrefs, options: .atomic)
        let beforeRollback = try rollbackStore.checkpoint()
        try rollbackStore.apply(.classic, gameIsActive: false, isBusy: false)
        let afterRollback = try rollbackStore.checkpoint()
        var outside = try Data(contentsOf: rollbackPrefs); outside.append(Data("\r\n; unrelated external change survives rollback\r\n".utf8))
        try outside.write(to: rollbackPrefs, options: .atomic)
        try rollbackStore.restore(beforeRollback, replacing: afterRollback, gameIsActive: false, isBusy: false)
        let rolledBack = try Data(contentsOf: rollbackPrefs)
        try check(try rollbackStore.status().mode == .modern, "Exact prior profile mode restored")
        try check(try GraphicsProfileINI(data: rolledBack).records() == GraphicsProfileINI(data: Data(priorModern.utf8)).records(), "Exact prior custom managed values/duplicates restored")
        try check(String(decoding: rolledBack, as: UTF8.self).contains("unrelated external change survives rollback"), "Rollback preserves unowned changes")
        let wanted = try rollbackStore.checkpoint()
        try rollbackStore.apply(.classic, gameIsActive: false, isBusy: false)
        let expecting = try rollbackStore.checkpoint()
        var concurrentManaged = try String(contentsOf: rollbackPrefs, encoding: .utf8)
        concurrentManaged = concurrentManaged.replacingOccurrences(of: "fShadowDistance=8192.0", with: "fShadowDistance=9999")
        let concurrentManagedBytes = Data(concurrentManaged.utf8)
        try concurrentManagedBytes.write(to: rollbackPrefs, options: .atomic)
        try expectFailure("rollback refuses concurrent managed edits") { try rollbackStore.restore(wanted, replacing: expecting, gameIsActive: false, isBusy: false) }
        try check(try Data(contentsOf: rollbackPrefs) == concurrentManagedBytes, "Managed conflict not overwritten by rollback")

        for failure: RecordingIO.Failure in [.backup, .managed, .snapshot, .journal, .preferences, .finalState, .postWritePreferences] {
            let (target, stateRoot, _) = try fixture(original)
            let io = RecordingIO(preferences: target); io.failure = failure
            let failingStore = GraphicsProfileStore(preferencesURL: target, metadataDirectory: stateRoot, io: io)
            try expectFailure("injected " + String(describing: failure)) { try failingStore.apply(.modern, gameIsActive: false, isBusy: false) }
            try check(try Data(contentsOf: target) == original, "Failure preserves original for " + String(describing: failure))
            if [.backup, .managed, .snapshot, .journal].contains(failure) { try check(io.preferenceWrites == 0, "No prefs write before backup+snapshot+journal") }
        }
        let (recordPrefs, recordMetadata, _) = try fixture(original)
        let recording = RecordingIO(preferences: recordPrefs)
        try GraphicsProfileStore(preferencesURL: recordPrefs, metadataDirectory: recordMetadata, io: recording).apply(.modern, gameIsActive: false, isBusy: false)
        let prefsIndex = recording.events.firstIndex(of: "write:SkyrimPrefs.ini")!
        for event in ["write:before.ini", "read:before.ini", "write:managed-before.json", "write:snapshot.json", "read:snapshot.json", "write:state.json"] {
            try check(recording.events.firstIndex(of: event)! < prefsIndex, "Ordering: " + event)
        }

        let (crashPrefs, crashMetadata, _) = try fixture(original)
        let crashIO = RecordingIO(preferences: crashPrefs); crashIO.failure = .interruptedAfterWrite
        try expectFailure("journal recovery") { try GraphicsProfileStore(preferencesURL: crashPrefs, metadataDirectory: crashMetadata, io: crashIO).apply(.modern, gameIsActive: false, isBusy: false) }
        let recovered = GraphicsProfileStore(preferencesURL: crashPrefs, metadataDirectory: crashMetadata)
        try check(try recovered.status().mode == .modern, "Interrupted after-write journal reconciles actual keys")
        try recovered.apply(.classic, gameIsActive: false, isBusy: false)
        try check(try Data(contentsOf: crashPrefs) == original, "Recovered baseline restores")

        let (concurrentPrefs, concurrentMetadata, _) = try fixture(original)
        let concurrentIO = RecordingIO(preferences: concurrentPrefs); concurrentIO.failure = .externalUnknownChange
        let concurrentStore = GraphicsProfileStore(preferencesURL: concurrentPrefs, metadataDirectory: concurrentMetadata, io: concurrentIO)
        try expectFailure("concurrent edit") { try concurrentStore.apply(.modern, gameIsActive: false, isBusy: false) }
        try check(String(decoding: try Data(contentsOf: concurrentPrefs), as: UTF8.self).contains("; externally added"), "Concurrent unknown changes not overwritten")

        for data in [Data([0xFF,0xFE]) + "[Display]\r\niMaxAnisotropy=8\r\n; café".data(using: .utf16LittleEndian)!, Data([0x3B,0x20,0xE9,0x0A]) + Data("[Display]\niMaxAnisotropy=8".utf8)] {
            let (target, _, targetStore) = try fixture(data)
            try targetStore.apply(.modern, gameIsActive: false, isBusy: false); try targetStore.apply(.classic, gameIsActive: false, isBusy: false)
            try check(try Data(contentsOf: target) == data, "Encoding/newlines preserved")
        }

        let (migrationPrefs, _, migrationStore) = try fixture(modernBytes)
        try migrationStore.adoptModernBaseline(originalPreferences: original, gameIsActive: false, isBusy: false)
        try check(try Data(contentsOf: migrationPrefs) == modernBytes, "Migration does not mutate current prefs")
        try check(try migrationStore.status().mode == .modern, "Migration reports actual Modern")
        try expectFailure("immutable migration") { try migrationStore.adoptModernBaseline(originalPreferences: original, gameIsActive: false, isBusy: false) }
        try migrationStore.apply(.classic, gameIsActive: false, isBusy: false)
        try check(try Data(contentsOf: migrationPrefs) == original, "Migrated original is real Classic baseline")

        try expectFailure("active and paused game") { try store.apply(.modern, gameIsActive: true, isBusy: false) }
        try expectFailure("busy") { try store.apply(.modern, gameIsActive: false, isBusy: true) }
        try check(!GraphicsProfile.canApply(runtimeReady: false, supported: true, gameIsActive: false, isBusy: false, changing: false, hasPreferences: true), "Unready runtime blocked")
        try check(!GraphicsProfile.canApply(runtimeReady: true, supported: false, gameIsActive: false, isBusy: false, changing: false, hasPreferences: true), "Unsupported runtime blocked")
        try check(!GraphicsProfile.canApply(runtimeReady: true, supported: true, gameIsActive: false, isBusy: false, changing: true, hasPreferences: true), "Own operation blocked")
        try check(!GraphicsProfile.canApply(runtimeReady: true, supported: true, gameIsActive: false, isBusy: false, changing: false, hasPreferences: false), "Absent preferences blocked")
        for active in [false,true] { for busy in [false,true] {
            try check(GraphicsProfile.canApply(runtimeReady: true, supported: true, gameIsActive: active, isBusy: busy, changing: false, hasPreferences: true) == (!active && !busy), "Actual UI game/busy gate")
        } }
        let directoryURL = URL(fileURLWithPath: prefs.path, isDirectory: true)
        try check(try Data(contentsOf: GraphicsProfile.fileURL(resolved: directoryURL)) == original, "Resolved final component treated as actual file")
        let absent = GraphicsProfileStore(preferencesURL: root.appendingPathComponent("absent.ini"), metadataDirectory: root.appendingPathComponent("absentMetadata"))
        try expectFailure("missing preferences") { _ = try absent.status() }
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("absent.ini").path), "No invented prefs")
        print("GraphicsProfileChecks PASS: roundtrip/native pixels/controls/unknowns/case/duplicates/conflicts/backup ordering/failures/journal/migration/encoding/session guards/file URL")
    }
}
