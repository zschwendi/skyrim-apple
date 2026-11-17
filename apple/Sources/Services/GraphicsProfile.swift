import Foundation

/// Public, device-local graphics profiles. Values are an owned overlay, never a
/// replacement SkyrimPrefs.ini. Resolution, mips, MSAA and non-graphics options
/// are deliberately outside this list. Optional asset overlays can reconcile the
/// returned Mode later; this service installs no textures, meshes or shaders.
enum GraphicsProfile {
    enum Mode: String, Codable, Sendable { case classic, modern }
    struct Key: Codable, Hashable, Sendable {
        let section: String
        let name: String
        var identity: String { section.lowercased() + "/" + name.lowercased() }
        var title: String { "[\(section)] \(name)" }
    }
    struct Setting: Sendable { let key: Key; let value: String }
    static let modern: [Setting] = [
        ("Display", "iMaxAnisotropy", "16"), ("Display", "iActorShadowCountInt", "4"),
        ("Display", "fSpecularLODStartFade", "1000.0000"), ("Display", "fLightLODStartFade", "2500.0000"),
        ("Display", "iShadowMapResolution", "2048"), ("Display", "fShadowBiasScale", "0.2500"),
        ("Display", "iShadowMaskQuarter", "4"), ("Display", "iBlurDeferredShadowMask", "3"),
        ("Display", "fTreesMidLODSwitchDist", "5000.0000"), ("Display", "fShadowDistance", "4000.0000"),
        ("Display", "iMaxDecalsPerFrame", "30"), ("Display", "iMaxSkinDecalsPerFrame", "10"),
        ("LOD", "fLODFadeOutMultActors", "6.0000"), ("LOD", "fLODFadeOutMultObjects", "7.5000"),
        ("LOD", "fLODFadeOutMultItems", "4.5000"), ("TerrainManager", "fTreeLoadDistance", "25000.0000"),
        ("TerrainManager", "fBlockMaximumDistance", "100000.0000"), ("TerrainManager", "fBlockLevel1Distance", "32768.0000"),
        ("TerrainManager", "fBlockLevel0Distance", "20480.0000"), ("TerrainManager", "fSplitDistanceMult", "0.7500"),
        ("Grass", "b30GrassVS", "1"), ("Grass", "fGrassStartFadeDistance", "5000.0000"),
        ("Water", "bReflectLODLand", "1"), ("Water", "iWaterReflectHeight", "1024"),
        ("Water", "iWaterReflectWidth", "1024"), ("BlurShaderHDR", "bDoHighDynamicRange", "1"),
        ("Decals", "bDecals", "1"), ("Decals", "bSkinnedDecals", "1"),
        ("Decals", "uMaxDecals", "250"), ("Decals", "uMaxSkinDecals", "50"),
        ("Decals", "uMaxSkinDecalPerActor", "40")
    ].map { Setting(key: Key(section: $0.0, name: $0.1), value: $0.2) }

    struct Status: Sendable {
        let mode: Mode
        let conflicts: [String]
    }
    typealias ChangeResult = Status
    static func fileURL(resolved: URL) -> URL { URL(fileURLWithPath: resolved.path, isDirectory: false) }
    static func canApply(runtimeReady: Bool, supported: Bool, gameIsActive: Bool, isBusy: Bool, changing: Bool, hasPreferences: Bool) -> Bool {
        runtimeReady && supported && !gameIsActive && !isBusy && !changing && hasPreferences
    }

    enum Issue: LocalizedError {
        case missingPreferences, gameActive, busy, unsupportedEncoding, invalidMetadata
        case changedDuringWrite, verificationFailed, interruptedWithChanges, alreadyConfigured
        var errorDescription: String? {
            switch self {
            case .missingPreferences: "Launch Skyrim once to create its graphics preferences, then quit the game."
            case .gameActive: "Quit Skyrim before changing graphics. A paused game is still running."
            case .busy: "Wait for the current launcher operation to finish."
            case .unsupportedEncoding: "SkyrimPrefs.ini could not be read safely. Its original file was kept."
            case .invalidMetadata: "The saved graphics-profile record is invalid. Preferences were kept; the local GraphicsProfiles backups are available."
            case .changedDuringWrite: "Skyrim preferences changed during this operation. They were kept; try again while the game is closed."
            case .verificationFailed: "The graphics change could not be verified. The original preferences are backed up locally."
            case .interruptedWithChanges: "A graphics change was interrupted and preferences have since changed. They were kept; the local GraphicsProfiles backups need review."
            case .alreadyConfigured: "This graphics profile already has a saved baseline. It was kept."
            }
        }
    }
}

/// Small injectable filesystem seam lets checks prove that backup/snapshot failure
/// cannot reach a preference write. Normal writes are same-directory atomic writes.
protocol GraphicsProfileFileIO: Sendable {
    func exists(_ url: URL) -> Bool
    func read(_ url: URL) throws -> Data
    func makeDirectory(_ url: URL) throws
    func writeAtomic(_ data: Data, to url: URL) throws
}
struct LocalGraphicsProfileFileIO: GraphicsProfileFileIO {
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func makeDirectory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    func writeAtomic(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

/// Call synchronously while the main-actor launcher is idle, so Play cannot race
/// a profile mutation. Every operation also checks the supplied activity flags.
/// Journal + verified immutable per-operation backup precede the atomic INI write.
final class GraphicsProfileStore: @unchecked Sendable {
    private let lock = NSLock()
    let preferencesURL: URL
    let metadataDirectory: URL
    private let io: any GraphicsProfileFileIO
    private var stateURL: URL { metadataDirectory.appendingPathComponent("state.json") }
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; return value }()
    private let decoder = JSONDecoder()

    init(preferencesURL: URL, metadataDirectory: URL, io: any GraphicsProfileFileIO = LocalGraphicsProfileFileIO()) {
        self.preferencesURL = preferencesURL; self.metadataDirectory = metadataDirectory; self.io = io
    }

    struct Record: Codable, Equatable, Sendable {
        let key: GraphicsProfile.Key
        let lines: [GraphicsProfileINI.Line]
    }
    struct Snapshot: Codable, Sendable {
        let backupID: String
        let original: [Record]
        let applied: [Record]
        let createdSections: [String]
        let originalLastLine: String?
        let originalEndsWithNewline: Bool
    }
    private struct Pending: Codable {
        let before: [Record]
        let after: [Record]
        let target: GraphicsProfile.Mode
        let snapshot: Snapshot?
        let conflicts: [String]
    }
    private struct State: Codable {
        var version = 1
        var mode: GraphicsProfile.Mode = .classic
        var snapshot: Snapshot?
        var conflicts: [String] = []
        var pending: Pending?
    }
    struct Checkpoint {
        fileprivate let location: URL
        fileprivate let document: GraphicsProfileINI
        fileprivate let stateBytes: Data
        let mode: GraphicsProfile.Mode
    }

    /// Optional asset-overlay transaction seam. Retains the exact prior managed
    /// values and baseline metadata, without making the INI a public asset.
    func checkpoint() throws -> Checkpoint {
        try lock.withLock {
            let (_, document) = try readPreferences()
            let state = try reconciledState(document: document)
            return Checkpoint(location: preferencesURL.standardizedFileURL, document: document,
                stateBytes: try encoder.encode(state), mode: state.mode)
        }
    }

    /// Roll back ONLY an exact expected profile result. Other writers' managed
    /// changes cause a conflict; unknown options are always retained. This is
    /// safer than applying the opposite mode, which would create a new baseline.
    @discardableResult
    func restore(_ checkpoint: Checkpoint, replacing expected: Checkpoint, gameIsActive: Bool, isBusy: Bool) throws -> GraphicsProfile.Status {
        try lock.withLock {
            guard !gameIsActive else { throw GraphicsProfile.Issue.gameActive }
            guard !isBusy else { throw GraphicsProfile.Issue.busy }
            guard checkpoint.location == preferencesURL.standardizedFileURL, expected.location == checkpoint.location else { throw GraphicsProfile.Issue.invalidMetadata }
            let (before, document) = try readPreferences()
            var state = try reconciledState(document: document)
            let previousState = state
            guard document.records() == expected.document.records(), try encoder.encode(state) == expected.stateBytes else { throw GraphicsProfile.Issue.changedDuringWrite }
            let target = try decoder.decode(State.self, from: checkpoint.stateBytes)
            var updated = document; updated.restoreOwned(from: checkpoint.document)
            let after = try updated.encoded()
            let backupID = try backup(before, records: document.records())
            try immutableSnapshot(makeSnapshot(backupID: backupID, original: document, applied: updated), id: backupID)
            state.pending = Pending(before: document.records(), after: updated.records(), target: target.mode, snapshot: target.snapshot, conflicts: target.conflicts)
            do {
                try writeState(state)
                guard try io.read(preferencesURL) == before else { throw GraphicsProfile.Issue.changedDuringWrite }
                if after != before { try io.writeAtomic(after, to: preferencesURL) }
                guard try io.read(preferencesURL) == after else { throw GraphicsProfile.Issue.verificationFailed }
                try writeState(target)
            } catch {
                if (try? io.read(preferencesURL)) == after { try? io.writeAtomic(before, to: preferencesURL) }
                if (try? io.read(preferencesURL)) == before { try? writeState(previousState) }
                throw error
            }
            return .init(mode: target.mode, conflicts: target.conflicts)
        }
    }

    func status() throws -> GraphicsProfile.Status {
        try lock.withLock {
            let (_, document) = try readPreferences()
            let state = try reconciledState(document: document)
            return GraphicsProfile.Status(mode: state.mode, conflicts: state.conflicts)
        }
    }

    @discardableResult
    func apply(_ mode: GraphicsProfile.Mode, gameIsActive: Bool, isBusy: Bool) throws -> GraphicsProfile.ChangeResult {
        try lock.withLock {
            guard !gameIsActive else { throw GraphicsProfile.Issue.gameActive }
            guard !isBusy else { throw GraphicsProfile.Issue.busy }
            let (before, document) = try readPreferences()
            var state = try reconciledState(document: document)
            let previousState = state
            if state.mode == mode { return .init(mode: state.mode, conflicts: state.conflicts) }
            var updated = document
            var snapshot: Snapshot?
            var conflicts: [String] = []
            if mode == .modern {
                updated.applyModern()
                let backupID = try backup(before, records: document.records())
                snapshot = makeSnapshot(backupID: backupID, original: document, applied: updated)
                // A separately readable owned-key snapshot exists before any INI mutation.
                try immutableSnapshot(snapshot!, id: backupID)
            } else {
                guard let baseline = state.snapshot else { throw GraphicsProfile.Issue.invalidMetadata }
                try validate(baseline)
                conflicts = updated.restore(baseline)
                let backupID = try backup(before, records: document.records())
                try immutableSnapshot(baseline, id: backupID)
            }
            let after = try updated.encoded()
            state.pending = Pending(before: document.records(), after: updated.records(), target: mode, snapshot: snapshot, conflicts: conflicts)
            do {
                try writeState(state) // write-ahead journal: no mutation without recovery metadata
                guard try io.read(preferencesURL) == before else { throw GraphicsProfile.Issue.changedDuringWrite }
                if after != before { try io.writeAtomic(after, to: preferencesURL) }
                guard try io.read(preferencesURL) == after else { throw GraphicsProfile.Issue.verificationFailed }
                state.mode = mode; state.snapshot = snapshot; state.conflicts = conflicts; state.pending = nil
                try writeState(state)
            } catch {
                // A final metadata failure must not strand a successful-looking
                // preference change. Roll back only our exact bytes, never a file
                // another writer has changed. The journal survives failed recovery.
                if (try? io.read(preferencesURL)) == after { try? io.writeAtomic(before, to: preferencesURL) }
                if (try? io.read(preferencesURL)) == before { try? writeState(previousState) }
                throw error
            }
            return .init(mode: mode, conflicts: conflicts)
        }
    }

    /// Migration seam for an existing manually upgraded device. Original bytes
    /// remain private local input. Requires ALL managed current occurrences to be
    /// Modern, verifies the baseline first, and never modifies SkyrimPrefs.ini.
    func adoptModernBaseline(originalPreferences: Data, gameIsActive: Bool, isBusy: Bool) throws {
        try lock.withLock {
            guard !gameIsActive else { throw GraphicsProfile.Issue.gameActive }
            guard !isBusy else { throw GraphicsProfile.Issue.busy }
            guard !io.exists(stateURL) else { throw GraphicsProfile.Issue.alreadyConfigured }
            let (currentBytes, current) = try readPreferences()
            guard current.isModern else { throw GraphicsProfile.Issue.changedDuringWrite }
            let original = try GraphicsProfileINI(data: originalPreferences)
            var overlay = original; overlay.applyModern()
            // A different duplicate structure cannot be safely mapped to original lines.
            guard zip(overlay.records(), current.records()).allSatisfy({ $0.lines.count == $1.lines.count }) else { throw GraphicsProfile.Issue.changedDuringWrite }
            let id = try backup(originalPreferences, records: original.records())
            let snapshot = makeSnapshot(backupID: id, original: original, applied: current)
            try immutableSnapshot(snapshot, id: id)
            guard try io.read(preferencesURL) == currentBytes else { throw GraphicsProfile.Issue.changedDuringWrite }
            var state = State(); state.mode = .modern; state.snapshot = snapshot
            try writeState(state)
        }
    }

    private func readPreferences() throws -> (Data, GraphicsProfileINI) {
        guard io.exists(preferencesURL) else { throw GraphicsProfile.Issue.missingPreferences }
        let bytes = try io.read(preferencesURL)
        return (bytes, try GraphicsProfileINI(data: bytes))
    }
    private func makeSnapshot(backupID: String, original: GraphicsProfileINI, applied: GraphicsProfileINI) -> Snapshot {
        Snapshot(backupID: backupID, original: original.records(), applied: applied.records(),
            createdSections: Array(applied.sections.subtracting(original.sections)).sorted(),
            originalLastLine: original.lines.last?.text, originalEndsWithNewline: original.lines.last?.ending.isEmpty == false)
    }
    private func backup(_ bytes: Data, records: [Record]) throws -> String {
        try io.makeDirectory(metadataDirectory)
        let id = UUID().uuidString
        let directory = metadataDirectory.appendingPathComponent(id, isDirectory: true)
        guard !io.exists(directory) else { throw GraphicsProfile.Issue.verificationFailed }
        try io.makeDirectory(directory)
        let backup = directory.appendingPathComponent("before.ini")
        try io.writeAtomic(bytes, to: backup)
        guard try io.read(backup) == bytes else { throw GraphicsProfile.Issue.verificationFailed }
        try io.writeAtomic(try encoder.encode(records), to: directory.appendingPathComponent("managed-before.json"))
        return id
    }
    private func immutableSnapshot(_ snapshot: Snapshot, id: String) throws {
        let url = metadataDirectory.appendingPathComponent(id).appendingPathComponent("snapshot.json")
        guard !io.exists(url) else { throw GraphicsProfile.Issue.verificationFailed }
        let bytes = try encoder.encode(snapshot)
        try io.writeAtomic(bytes, to: url)
        guard try io.read(url) == bytes else { throw GraphicsProfile.Issue.verificationFailed }
    }
    private func writeState(_ state: State) throws {
        try io.makeDirectory(metadataDirectory)
        let bytes = try encoder.encode(state)
        try io.writeAtomic(bytes, to: stateURL)
        guard try io.read(stateURL) == bytes else { throw GraphicsProfile.Issue.verificationFailed }
    }
    private func validate(_ snapshot: Snapshot) throws {
        guard UUID(uuidString: snapshot.backupID) != nil,
              snapshot.original.map(\.key.identity) == GraphicsProfile.modern.map({ $0.key.identity }),
              snapshot.applied.map(\.key.identity) == GraphicsProfile.modern.map({ $0.key.identity }),
              snapshot.original.allSatisfy({ $0.lines.count < 1024 }),
              snapshot.applied.allSatisfy({ !$0.lines.isEmpty && $0.lines.count < 1024 }),
              snapshot.createdSections.allSatisfy({ section in GraphicsProfile.modern.contains { $0.key.section.lowercased() == section.lowercased() } }),
              zip(snapshot.original, snapshot.applied).allSatisfy({ original, applied in applied.lines.count == max(1, original.lines.count) }),
              snapshot.original.allSatisfy(GraphicsProfileINI.validRecord),
              snapshot.applied.allSatisfy(GraphicsProfileINI.validRecord)
        else { throw GraphicsProfile.Issue.invalidMetadata }
        let backup = metadataDirectory.appendingPathComponent(snapshot.backupID).appendingPathComponent("before.ini")
        guard let bytes = try? io.read(backup), let document = try? GraphicsProfileINI(data: bytes), document.records() == snapshot.original else { throw GraphicsProfile.Issue.invalidMetadata }
    }
    private func reconciledState(document: GraphicsProfileINI) throws -> State {
        guard io.exists(stateURL) else { return State() }
        let bytes = try io.read(stateURL)
        guard bytes.count <= 4_194_304, var state = try? decoder.decode(State.self, from: bytes), state.version == 1 else { throw GraphicsProfile.Issue.invalidMetadata }
        if let snapshot = state.snapshot { try validate(snapshot) }
        if let pending = state.pending {
            if let snapshot = pending.snapshot { try validate(snapshot) }
            let current = document.records()
            if current == pending.after {
                state.mode = pending.target; state.snapshot = pending.snapshot; state.conflicts = pending.conflicts
            } else if current != pending.before { throw GraphicsProfile.Issue.interruptedWithChanges }
            state.pending = nil
            try writeState(state)
        }
        if state.mode == .modern && state.snapshot == nil { throw GraphicsProfile.Issue.invalidMetadata }
        return state
    }
}

/// Lossless line editing: section/key matching is case-insensitive, duplicates
/// are all patched, and unknown lines/ordering/encoding/newline style survive.
struct GraphicsProfileINI {
    struct Line: Codable, Equatable, Sendable { var text: String; var ending: String }
    private enum Encoding { case utf8, utf8BOM, utf16LE, utf16BE, latin1 }
    private let encoding: Encoding
    var lines: [Line]
    private var newline: String { lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\r\n" }
    var sections: Set<String> { Set(lines.compactMap { Self.section($0.text) }) }
    init(data: Data) throws {
        guard data.count <= 4_194_304 else { throw GraphicsProfile.Issue.unsupportedEncoding }
        let text: String?
        if data.starts(with: [0xEF,0xBB,0xBF]) { encoding = .utf8BOM; text = String(data: data.dropFirst(3), encoding: .utf8) }
        else if data.starts(with: [0xFF,0xFE]) { encoding = .utf16LE; text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xFE,0xFF]) { encoding = .utf16BE; text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else if let decoded = String(data: data, encoding: .utf8) { encoding = .utf8; text = decoded }
        else { encoding = .latin1; text = String(data: data, encoding: .isoLatin1) }
        guard let text, !text.contains("\0") else { throw GraphicsProfile.Issue.unsupportedEncoding }
        lines = []; var start = text.startIndex; var index = start
        while index < text.endIndex {
            let next = text.index(after: index), character = text[index]
            if character == "\n" || character == "\r" || character == "\r\n" {
                lines.append(Line(text: String(text[start..<index]), ending: String(character))); start = next
            }
            index = next
        }
        if start < text.endIndex { lines.append(Line(text: String(text[start...]), ending: "")) }
    }
    func encoded() throws -> Data {
        let text = lines.map { $0.text + $0.ending }.joined()
        let format: String.Encoding; let prefix: Data
        switch encoding {
        case .utf8: format = .utf8; prefix = Data()
        case .utf8BOM: format = .utf8; prefix = Data([0xEF,0xBB,0xBF])
        case .utf16LE: format = .utf16LittleEndian; prefix = Data([0xFF,0xFE])
        case .utf16BE: format = .utf16BigEndian; prefix = Data([0xFE,0xFF])
        case .latin1: format = .isoLatin1; prefix = Data()
        }
        guard let body = text.data(using: format) else { throw GraphicsProfile.Issue.unsupportedEncoding }
        return prefix + body
    }
    private static func section(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") else { return nil }
        let tail = trimmed[trimmed.index(after: end)...].trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix(";") || tail.hasPrefix("#") else { return nil }
        return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end]).trimmingCharacters(in: .whitespaces).lowercased()
    }
    private static func assignment(_ text: String) -> (key: String, prefix: String, value: String, suffix: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"), let equals = text.firstIndex(of: "=") else { return nil }
        let key = text[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        var start = text.index(after: equals)
        while start < text.endIndex && text[start].isWhitespace { start = text.index(after: start) }
        let comment = text[start...].firstIndex(where: { $0 == ";" || $0 == "#" }) ?? text.endIndex
        var end = comment
        while end > start && text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        return (key, String(text[..<start]), String(text[start..<end]), String(text[end...]))
    }
    private func indices(_ key: GraphicsProfile.Key) -> [Int] {
        var section = ""; var result: [Int] = []
        for (index, line) in lines.enumerated() {
            if let name = Self.section(line.text) { section = name }
            else if section == key.section.lowercased(), Self.assignment(line.text)?.key == key.name.lowercased() { result.append(index) }
        }
        return result
    }
    func records() -> [GraphicsProfileStore.Record] {
        GraphicsProfile.modern.map { setting in .init(key: setting.key, lines: indices(setting.key).map { lines[$0] }) }
    }
    static func validRecord(_ record: GraphicsProfileStore.Record) -> Bool {
        record.lines.allSatisfy { line in
            !line.text.contains(where: { $0.isNewline }) && ["", "\n", "\r", "\r\n"].contains(line.ending) &&
                assignment(line.text)?.key == record.key.name.lowercased()
        }
    }
    private static func sameValue(_ line: Line, _ expected: String) -> Bool {
        guard let value = assignment(line.text)?.value else { return false }
        if let number = Double(value), let target = Double(expected), number.isFinite && target.isFinite { return number == target }
        return value == expected
    }
    var isModern: Bool { GraphicsProfile.modern.allSatisfy { setting in
        let positions = indices(setting.key)
        return !positions.isEmpty && positions.allSatisfy { Self.sameValue(lines[$0], setting.value) }
    } }
    mutating func applyModern() {
        for setting in GraphicsProfile.modern {
            let positions = indices(setting.key)
            if positions.isEmpty { insert(setting) }
            else { for index in positions { if let value = Self.assignment(lines[index].text) { lines[index].text = value.prefix + setting.value + value.suffix } } }
        }
    }
    private mutating func insert(_ setting: GraphicsProfile.Setting) {
        let ending = newline
        let header = lines.firstIndex { Self.section($0.text) == setting.key.section.lowercased() }
        let position: Int
        if let header {
            position = lines.indices.first(where: { $0 > header && Self.section(lines[$0].text) != nil }) ?? lines.count
        } else {
            if !lines.isEmpty && lines[lines.count-1].ending.isEmpty { lines[lines.count-1].ending = ending }
            lines.append(Line(text: "[\(setting.key.section)]", ending: ending)); position = lines.count
        }
        if position > 0 && lines[position-1].ending.isEmpty { lines[position-1].ending = ending }
        lines.insert(Line(text: "\(setting.key.name)=\(setting.value)", ending: ending), at: position)
    }
    mutating func restore(_ snapshot: GraphicsProfileStore.Snapshot) -> [String] {
        var conflicts: [String] = []
        for (offset, setting) in GraphicsProfile.modern.enumerated() {
            let positions = indices(setting.key)
            guard positions.count == snapshot.applied[offset].lines.count,
                  positions.allSatisfy({ Self.sameValue(lines[$0], setting.value) }) else {
                conflicts.append(setting.key.title); continue
            }
            let original = snapshot.original[offset].lines
            if original.isEmpty { for index in positions.reversed() { lines.remove(at: index) } }
            else { for (index, line) in zip(positions, original) { lines[index] = line } }
        }
        // Remove only newly-created sections that still contain no user content.
        for section in snapshot.createdSections {
            let headers = lines.indices.filter { Self.section(lines[$0].text) == section }
            guard headers.count == 1, let header = headers.first else { continue }
            let end = lines.indices.first(where: { $0 > header && Self.section(lines[$0].text) != nil }) ?? lines.count
            if lines[(header+1)..<end].allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { lines.removeSubrange(header..<end) }
        }
        if !snapshot.originalEndsWithNewline, lines.last?.text == snapshot.originalLastLine, !lines.isEmpty { lines[lines.count-1].ending = "" }
        // A formerly-final owned key may now precede a user's newly added option.
        // Its saved empty EOF ending must never join that unknown option to it.
        if lines.count > 1 {
            let separator = newline
            for index in 0..<(lines.count-1) where lines[index].ending.isEmpty { lines[index].ending = separator }
        }
        return conflicts
    }
    mutating func restoreOwned(from target: GraphicsProfileINI) {
        for setting in GraphicsProfile.modern {
            let current = indices(setting.key), wanted = target.indices(setting.key).map { target.lines[$0] }
            if current.count == wanted.count {
                for (index, line) in zip(current, wanted) { lines[index] = line }
            } else {
                for index in current.reversed() { lines.remove(at: index) }
                guard !wanted.isEmpty else { continue }
                insert(setting)
                let slot = indices(setting.key)[0]
                lines.replaceSubrange(slot...slot, with: wanted)
            }
        }
        for section in sections.subtracting(target.sections) {
            let headers = lines.indices.filter { Self.section(lines[$0].text) == section }
            guard headers.count == 1, let header = headers.first else { continue }
            let end = lines.indices.first(where: { $0 > header && Self.section(lines[$0].text) != nil }) ?? lines.count
            if lines[(header+1)..<end].allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { lines.removeSubrange(header..<end) }
        }
        if target.lines.last?.ending.isEmpty == true, lines.last?.text == target.lines.last?.text, !lines.isEmpty { lines[lines.count-1].ending = "" }
        if lines.count > 1 {
            let separator = newline
            for index in 0..<(lines.count-1) where lines[index].ending.isEmpty { lines[index].ending = separator }
        }
    }
}
