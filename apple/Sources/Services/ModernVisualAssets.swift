import CryptoKit
import Foundation
import Darwin

/// Six bundled CC0 loose landscape textures, with verified originals and crash
/// recovery outside Saves. Call synchronously while holding the launcher's idle
/// gate. A pending journal or conflict must block Play, not just show a hint.
final class ModernVisualAssets {
    enum Mode: String, Codable, Sendable { case classic, modern }
    struct ChangeResult: Sendable { let mode: Mode; let changedFiles: Int }
    struct Status: Sendable {
        let mode: Mode
        let packID: String?
        let needsRecovery: Bool
        let conflicts: [String]
        var canLaunch: Bool { !needsRecovery && conflicts.isEmpty }
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }
    struct Manifest: Codable {
        let schema: Int
        let id: String
        let assets: [Asset]
    }
    struct Asset: Codable {
        let destination: String
        let file: String
        let sha256: String
        let bytes: Int
        let width: Int
        let height: Int
        let mips: Int
        let format: String
        let license: String
        let sourceURL: String
        let sourceAssetID: String
    }
    private struct Fingerprint: Codable, Equatable {
        let sha256: String
        let bytes: Int
        init(_ data: Data) {
            sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            bytes = data.count
        }
        var blob: String { "backups/\(sha256).dds" }
    }
    private struct Entry: Codable {
        let destination: String
        let installed: Fingerprint
        let original: Fingerprint?
    }
    private struct State: Codable { let schema: Int; let packID: String; let entries: [Entry] }
    private struct Change: Codable {
        let destination: String
        let before: Fingerprint?
        let after: Fingerprint?
    }
    private struct Journal: Codable {
        let schema: Int
        let id: String
        let target: Mode
        var configurationMayHaveChanged: Bool
        let before: State?
        let after: State?
        let changes: [Change]
    }
    private struct Pack { let manifest: Manifest; let contents: [String: Data] }

    static let destinations = ["dirt01", "dirtpath01", "pineforest01"].flatMap {
        ["textures/landscape/\($0).dds", "textures/landscape/\($0)_n.dds"]
    }.sorted()
    private static let maximumFileBytes = 64 * 1024 * 1024
    private let dataTree: Tree
    private let metadata: Tree
    private let packDirectory: URL?
    private let fault: ((String) throws -> Void)?
    private let capacityOverride: (() throws -> UInt64)?

    /// supportDirectory is SkyrimSaveLocations.supportDirectory, NOT Saves.
    /// packDirectory is the bundled directory containing manifest.json/payload.
    init(dataDirectory: URL, supportDirectory: URL, packDirectory: URL?,
         testingFault: ((String) throws -> Void)? = nil,
         testingCapacity: (() throws -> UInt64)? = nil) throws {
        dataTree = try Tree(root: dataDirectory, create: false)
        let support = try Tree(root: supportDirectory, create: true)
        let metaURL = try support.directory("GraphicsProfiles/ModernVisualAssets", create: true)
        metadata = try Tree(root: metaURL, create: false)
        let a = dataTree.root.path + "/", b = metadata.root.path + "/"
        guard !a.hasPrefix(b), !b.hasPrefix(a) else { throw Failure("Texture data and profile backups must be separate folders.") }
        self.packDirectory = packDirectory
        fault = testingFault
        capacityOverride = testingCapacity
    }

    func status() throws -> Status {
        try locked {
            let state = try readState()
            let pending = try readJournal() != nil
            return Status(mode: state == nil ? .classic : .modern, packID: state?.packID,
                          needsRecovery: pending, conflicts: try conflicts(state))
        }
    }

    /// Assets are prepared first, then the caller commits its INI/profile mode.
    /// Supply a real profile snapshot/restore closure; a changed user INI must
    /// cause that closure to throw rather than overwriting a conflicting value.
    /// No success is returned until assets AND configuration are committed.
    func apply(_ mode: Mode, configuration: () throws -> Void,
               rollbackConfiguration: () throws -> Void) throws -> ChangeResult {
        try locked {
            guard try readJournal() == nil else { throw Failure("A texture transaction needs recovery before changing graphics mode.") }
            let before = try readState()
            let currentConflicts = try conflicts(before)
            guard currentConflicts.isEmpty else { throw conflictFailure(currentConflicts) }
            let pack = mode == .modern ? try loadPack() : nil
            var contents: [String: Data] = [:]
            var entries: [Entry] = []
            var changes: [Change] = []
            for destination in Self.destinations {
                let currentData = try dataTree.read(destination, maximum: Self.maximumFileBytes)
                let current = currentData.map(Fingerprint.init)
                let old = before?.entries.first { $0.destination == destination }
                if mode == .modern || old != nil, let currentData, let current { contents[current.sha256] = currentData }
                if let original = old?.original { contents[original.sha256] = try blob(original) }
                let after: Fingerprint?
                if let pack {
                    guard let data = pack.contents[destination] else { throw Failure("Bundled texture pack is incomplete.") }
                    let fingerprint = Fingerprint(data)
                    contents[fingerprint.sha256] = data
                    entries.append(Entry(destination: destination, installed: fingerprint, original: old?.original ?? current))
                    // When upgrading a managed file whose original was absent,
                    // do not adopt the old managed payload as a user original.
                    if let old, old.original == nil {
                        entries[entries.count - 1] = Entry(destination: destination, installed: fingerprint, original: nil)
                    }
                    after = fingerprint
                } else if let old {
                    after = old.original
                    if let original = old.original { contents[original.sha256] = try blob(original) }
                } else {
                    after = current // Classic never touches unmanaged files.
                }
                if current != after { changes.append(Change(destination: destination, before: current, after: after)) }
            }
            let after = pack.map { State(schema: 1, packID: $0.manifest.id, entries: entries) }
            // Full payload/backup and disk preflight precedes any Data mutation.
            // Reserve a second full content copy for atomic writes/rollback plus
            // 8MiB for journals and filesystem overhead, on BOTH volumes.
            let contentBytes = contents.values.reduce(UInt64(0)) { $0 + UInt64($1.count) }
            let required = contentBytes * 2 + 8 * 1024 * 1024
            try ensureCapacity(required)
            for (hash, data) in contents { try saveBlob(data, expected: Fingerprint(data), hash: hash) }
            var journal = Journal(schema: 1, id: UUID().uuidString.lowercased(), target: mode,
                                  configurationMayHaveChanged: false, before: before, after: after, changes: changes)
            try writeJournal(journal)
            do {
                for change in changes {
                    try fault?("beforeAsset:\(change.destination)")
                    try changeFile(change.destination, from: change.before, to: change.after)
                    try fault?("afterAsset:\(change.destination)")
                }
                journal.configurationMayHaveChanged = true
                try writeJournal(journal) // BEFORE the callback can commit config.
                try fault?("beforeConfiguration")
                try configuration()
                try fault?("afterConfiguration")
                try writeState(after)
                try fault?("afterState")
                try metadata.remove("journal.json")
                return ChangeResult(mode: mode, changedFiles: changes.count)
            } catch {
                let originalError = error
                var failures: [String] = []
                do { try rollback(journal) } catch { failures.append(error.localizedDescription) }
                if journal.configurationMayHaveChanged {
                    do { try rollbackConfiguration() } catch { failures.append(error.localizedDescription) }
                }
                if failures.isEmpty {
                    try metadata.remove("journal.json")
                    throw originalError
                }
                throw Failure("Graphics change is pending recovery. \(originalError.localizedDescription) \(failures.joined(separator: " "))")
            }
        }
    }

    /// First recover GraphicsProfileStore, then pass its VERIFIED current mode.
    /// Do not pass a UI preference if the profile store reports conflicts.
    /// If config reached the requested mode, finish only known before/after
    /// journal values. This also repairs our asset rollback when configuration
    /// rollback failed. Any unrelated value remains untouched and blocks launch.
    @discardableResult
    func recover(configurationMode: Mode) throws -> Status {
        try locked {
            if let journal = try readJournal() {
                if journal.configurationMayHaveChanged && configurationMode == journal.target {
                    var forward: [Change] = []
                    var found: [String] = []
                    for change in journal.changes {
                        let actual = try fingerprint(change.destination)
                        if actual == change.after { continue }
                        if actual == change.before { forward.append(change) }
                        else { found.append(change.destination) }
                    }
                    // Preflight ALL destinations and ALL required payloads
                    // before a single forward write; never turn a later user
                    // conflict or missing backup into another partial repair.
                    guard found.isEmpty else { throw conflictFailure(found) }
                    for change in forward {
                        if let after = change.after { _ = try blob(after) }
                    }
                    if let largest = forward.compactMap({ $0.after?.bytes }).max(), largest > 0 {
                        try ensureCapacity(UInt64(largest) * 2 + 8 * 1024 * 1024)
                    }
                    for change in forward {
                        try changeFile(change.destination, from: change.before, to: change.after)
                    }
                    for change in journal.changes {
                        guard try fingerprint(change.destination) == change.after else {
                            throw conflictFailure([change.destination])
                        }
                    }
                    try writeState(journal.after)
                } else {
                    try rollback(journal)
                }
                try metadata.remove("journal.json")
            }
            let state = try readState()
            let found = try conflicts(state)
            return Status(mode: state == nil ? .classic : .modern, packID: state?.packID,
                          needsRecovery: false, conflicts: found)
        }
    }

    private func rollback(_ journal: Journal) throws {
        // A failed write may be before OR after its atomic rename. Validate all
        // destinations before reversing any; preserve third-party edits.
        var affected: [Change] = []
        var found: [String] = []
        for change in journal.changes {
            let actual = try fingerprint(change.destination)
            if actual == change.before { continue }
            if actual == change.after { affected.append(change) } else { found.append(change.destination) }
        }
        guard found.isEmpty else { throw conflictFailure(found) }
        for change in affected.reversed() { try changeFile(change.destination, from: change.after, to: change.before) }
        try writeState(journal.before)
    }

    private func changeFile(_ destination: String, from expected: Fingerprint?, to result: Fingerprint?) throws {
        guard try fingerprint(destination) == expected else { throw conflictFailure([destination]) }
        if let result {
            let data = try blob(result)
            try dataTree.write(destination, data: data)
            guard try fingerprint(destination) == result else { throw Failure("Texture verification failed after writing \(destination).") }
        } else {
            try dataTree.remove(destination)
            guard try fingerprint(destination) == nil else { throw Failure("Texture removal failed for \(destination).") }
        }
    }
    private func fingerprint(_ destination: String) throws -> Fingerprint? {
        try dataTree.read(destination, maximum: Self.maximumFileBytes).map(Fingerprint.init)
    }
    private func conflicts(_ state: State?) throws -> [String] {
        guard let state else { return [] }
        return try state.entries.compactMap { entry in
            try fingerprint(entry.destination) == entry.installed ? nil : entry.destination
        }
    }
    private func conflictFailure(_ paths: [String]) -> Failure {
        Failure("Preserved changed texture files: \(paths.sorted().joined(separator: ", ")). Resolve these files before switching modes.")
    }
    private func ensureCapacity(_ required: UInt64) throws {
        let available = try capacityOverride?() ?? min(dataTree.capacity(), metadata.capacity())
        guard available >= required else { throw Failure("Modern textures need \(required / 1024 / 1024 + 1) MB free for verified backups and rollback.") }
    }
    private func saveBlob(_ data: Data, expected: Fingerprint, hash: String) throws {
        guard hash == expected.sha256 else { throw Failure("Invalid backup identity.") }
        if let prior = try metadata.read(expected.blob, maximum: Self.maximumFileBytes) {
            guard Fingerprint(prior) == expected else { throw Failure("An existing texture backup changed; it was preserved.") }
        } else {
            try metadata.write(expected.blob, data: data)
        }
        guard Fingerprint(try blob(expected)) == expected else { throw Failure("Texture backup verification failed.") }
    }
    private func blob(_ fingerprint: Fingerprint) throws -> Data {
        guard valid(fingerprint), let data = try metadata.read(fingerprint.blob, maximum: Self.maximumFileBytes),
              Fingerprint(data) == fingerprint else { throw Failure("A verified texture backup is missing or changed.") }
        return data
    }
    private func valid(_ value: Fingerprint) -> Bool {
        value.bytes >= 0 && value.bytes <= Self.maximumFileBytes && value.sha256.count == 64 &&
        value.sha256.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private func validate(_ state: State?) throws {
        guard let state else { return }
        guard state.schema == 1, validID(state.packID), state.entries.map(\.destination).sorted() == Self.destinations,
              state.entries.allSatisfy({ valid($0.installed) && ($0.original.map(valid) ?? true) }) else {
            throw Failure("Texture ownership metadata is invalid; no game files were changed.")
        }
    }
    private func readState() throws -> State? {
        guard let data = try metadata.read("state.json", maximum: 128 * 1024) else { return nil }
        let state = try JSONDecoder().decode(State.self, from: data); try validate(state); return state
    }
    private func writeState(_ state: State?) throws {
        try validate(state)
        if let state { try metadata.write("state.json", data: JSONEncoder().encode(state)) }
        else { try metadata.remove("state.json") }
    }
    private func readJournal() throws -> Journal? {
        guard let data = try metadata.read("journal.json", maximum: 256 * 1024) else { return nil }
        let j = try JSONDecoder().decode(Journal.self, from: data)
        try validate(j.before); try validate(j.after)
        let destinations = j.changes.map(\.destination)
        guard j.schema == 1, UUID(uuidString: j.id) != nil, Set(destinations).count == destinations.count,
              Set(destinations).isSubset(of: Set(Self.destinations)),
              j.changes.allSatisfy({ ($0.before.map(valid) ?? true) && ($0.after.map(valid) ?? true) }),
              (j.target == .modern) == (j.after != nil) else { throw Failure("Texture recovery journal is invalid; no files were changed.") }
        return j
    }
    private func writeJournal(_ journal: Journal) throws { try metadata.write("journal.json", data: JSONEncoder().encode(journal)) }
    private func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.allSatisfy { "abcdefghijklmnopqrstuvwxyz0123456789._-".contains($0) }
    }
    private func loadPack() throws -> Pack {
        guard let packDirectory else { throw Failure("The bundled Modern texture pack is unavailable.") }
        let tree = try Tree(root: packDirectory, create: false)
        guard let json = try tree.read("manifest.json", maximum: 128 * 1024) else { throw Failure("The Modern texture manifest is missing.") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: json)
        guard manifest.schema == 1, validID(manifest.id), manifest.assets.count == Self.destinations.count,
              manifest.assets.map(\.destination).sorted() == Self.destinations else {
            throw Failure("The Modern texture manifest contains unsupported or duplicate destinations.")
        }
        var contents: [String: Data] = [:]
        var sourcePaths = Set<String>()
        for asset in manifest.assets {
            guard asset.file == "payload/" + asset.destination,
                  sourcePaths.insert(asset.file.lowercased()).inserted,
                  asset.license == "CC0-1.0", asset.format == "DXT1", asset.width == 2048, asset.height == 2048, asset.mips == 12,
                  let source = URL(string: asset.sourceURL), source.scheme == "https", source.host?.lowercased() == "ambientcg.com",
                  !asset.sourceAssetID.isEmpty, asset.sourceAssetID.count <= 80,
                  asset.sourceAssetID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  let data = try tree.read(asset.file, maximum: Self.maximumFileBytes) else {
                throw Failure("Unsupported or missing bundled texture \(asset.destination).")
            }
            let actual = Fingerprint(data)
            guard actual.bytes == asset.bytes, actual.sha256 == asset.sha256 else { throw Failure("Bundled texture verification failed for \(asset.destination).") }
            try Self.validateDDS(data, asset: asset)
            contents[asset.destination] = data
        }
        return Pack(manifest: manifest, contents: contents)
    }
    static func validateDDS(_ data: Data, asset: Asset) throws {
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
        }
        guard asset.width == 2048, asset.height == 2048, asset.mips == 12, asset.format == "DXT1",
              data.count >= 128, data.prefix(4) == Data("DDS ".utf8) else { throw Failure("Modern textures must be legacy 2K DDS images.") }
        let flags = word(8)
        guard word(4) == 124, flags == 0xA1007,
              word(12) == UInt32(asset.height), word(16) == UInt32(asset.width), word(24) == 0,
              word(28) == UInt32(asset.mips), word(76) == 32, word(80) == 4,
              data[84..<88] == Data("DXT1".utf8), word(88) == 0,
              (92...104).filter({ $0 % 4 == 0 }).allSatisfy({ word($0) == 0 }),
              word(108) == 0x401008,
              [112, 116, 120, 124].allSatisfy({ word($0) == 0 }) else {
            throw Failure("Unsupported DDS header in \(asset.destination).")
        }
        var width = asset.width, height = asset.height, bytes = 128, levels = 0
        while true {
            bytes += max(1, (width + 3) / 4) * max(1, (height + 3) / 4) * 8
            levels += 1
            if width == 1 && height == 1 { break }
            width = max(1, width / 2); height = max(1, height / 2)
        }
        guard levels == asset.mips, data.count == bytes, word(20) == UInt32(asset.width / 4 * (asset.height / 4) * 8) else {
            throw Failure("Incomplete or invalid DDS mip chain in \(asset.destination).")
        }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let descriptor = try metadata.lockFile()
        defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Another graphics asset change is in progress.") }
        return try body()
    }

    /// Directory-relative POSIX operations: every child directory/file is opened
    /// NOFOLLOW. Case-insensitive lookup follows the game's Windows semantics
    /// while rejecting duplicate spellings on case-sensitive volumes.
    private final class Tree {
        let root: URL
        private let fd: Int32
        init(root: URL, create: Bool) throws {
            guard root.isFileURL else { throw Failure("Graphics files require local folders.") }
            if create && !FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
            var info = stat()
            guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure("A graphics root is missing, a symlink, or not a folder.") }
            self.root = root.standardizedFileURL.resolvingSymlinksInPath()
            fd = open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure("Cannot open graphics folder.") }
        }
        deinit { close(fd) }
        private func components(_ path: String) throws -> [String] {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.count <= 128 &&
                $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) }) else {
                throw Failure("Unsafe graphics asset path.")
            }
            return parts
        }
        private func spelling(_ name: String, in directory: Int32) throws -> String {
            // dup() would share the directory cursor and make later lookups
            // silently miss existing differently-cased entries.
            let fresh = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fresh >= 0 else { throw Failure("Cannot inspect graphics folder.") }
            guard let stream = fdopendir(fresh) else { close(fresh); throw Failure("Cannot inspect graphics folder.") }
            defer { closedir(stream) }
            var matches: [String] = []
            errno = 0
            while let entry = readdir(stream) {
                var raw = entry.pointee.d_name
                let capacity = MemoryLayout.size(ofValue: raw)
                let value = withUnsafePointer(to: &raw) {
                    $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
                }
                if value.lowercased() == name.lowercased() { matches.append(value) }
            }
            guard errno == 0, matches.count <= 1 else { throw Failure("Ambiguous case or unreadable graphics path \(name).") }
            return matches.first ?? name
        }
        private func parent(_ path: String, create: Bool) throws -> (Int32, String, [String]) {
            let parts = try components(path)
            var directory = dup(fd), actual: [String] = []
            guard directory >= 0 else { throw Failure("Cannot open graphics directory.") }
            do {
                for component in parts.dropLast() {
                    let name = try spelling(component, in: directory)
                    if create && mkdirat(directory, name, 0o700) != 0 && errno != EEXIST { throw Failure("Cannot create graphics subfolder.") }
                    let next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard next >= 0 else {
                        if errno == ENOENT && !create { close(directory); return (-1, parts.last!, []) }
                        throw Failure("A graphics subfolder is unreadable or a symlink.")
                    }
                    close(directory); directory = next; actual.append(name)
                }
                return (directory, try spelling(parts.last!, in: directory), actual)
            } catch { close(directory); throw error }
        }
        func directory(_ path: String, create: Bool) throws -> URL {
            let (parent, name, actual) = try parent(path + "/sentinel", create: create)
            guard parent >= 0 else { throw Failure("Graphics directory is missing.") }
            close(parent)
            _ = name
            return actual.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        }
        func read(_ path: String, maximum: Int) throws -> Data? {
            let (parent, name, _) = try parent(path, create: false)
            guard parent >= 0 else { return nil }
            defer { close(parent) }
            let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if file < 0 {
                if errno == ENOENT { return nil }
                throw Failure("Cannot read graphics file \(path); symlinks are unsupported.")
            }
            defer { close(file) }
            var before = stat(), after = stat()
            guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= maximum else {
                throw Failure("Unsupported or oversized graphics file \(path).")
            }
            var data = Data(count: Int(before.st_size))
            try data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.read(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw Failure("Graphics file changed while reading \(path).") }
                    offset += count
                }
            }
            guard fstat(file, &after) == 0, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure("Graphics file changed while reading \(path).") }
            return data
        }
        func write(_ path: String, data: Data) throws {
            let (parent, name, _) = try parent(path, create: true)
            defer { close(parent) }
            // Reject a symlink/special file even though rename would replace it.
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG else { throw Failure("Refusing to replace a nonregular graphics file.") }
            } else if errno != ENOENT { throw Failure("Cannot inspect graphics destination.") }
            let temporary = ".modern-\(UUID().uuidString.lowercased()).tmp"
            let file = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw Failure("Cannot stage graphics file.") }
            defer { close(file); _ = unlinkat(parent, temporary, 0) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw Failure("Cannot write graphics file.") }
                    offset += count
                }
            }
            guard fsync(file) == 0, renameat(parent, temporary, parent, name) == 0, fsync(parent) == 0 else {
                throw Failure("Cannot commit graphics file atomically.")
            }
        }
        func remove(_ path: String) throws {
            let (parent, name, _) = try parent(path, create: false)
            guard parent >= 0 else { return }
            defer { close(parent) }
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return }
                throw Failure("Cannot inspect graphics file for removal.")
            }
            guard info.st_mode & S_IFMT == S_IFREG, unlinkat(parent, name, 0) == 0, fsync(parent) == 0 else {
                throw Failure("Refusing to remove an unsupported graphics file.")
            }
        }
        func lockFile() throws -> Int32 {
            let file = openat(fd, "transaction.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            var info = stat()
            guard file >= 0, fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                if file >= 0 { close(file) }; throw Failure("Cannot acquire graphics transaction lock.")
            }
            return file
        }
        func capacity() throws -> UInt64 {
            var volume = statfs()
            guard fstatfs(fd, &volume) == 0 else { throw Failure("Cannot check free space for graphics backups.") }
            return UInt64(volume.f_bavail) * UInt64(volume.f_bsize)
        }
    }
}
