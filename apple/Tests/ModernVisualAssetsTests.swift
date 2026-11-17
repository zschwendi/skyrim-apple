import CryptoKit
import Foundation
import Darwin

@main
@MainActor
struct ModernVisualAssetsTests {
    static var checks = 0
    enum Deliberate: Error { case failure }
    static let fm = FileManager.default
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String = #function, line: UInt = #line) throws {
        checks += 1
        guard try value() else { throw ModernVisualAssets.Failure("Check failed \(line): \(message)") }
    }
    static func rejects(_ body: () throws -> Void, line: UInt = #line) throws {
        checks += 1
        do { try body() } catch { return }
        throw ModernVisualAssets.Failure("Expected failure at \(line)")
    }
    static func put(_ data: Data, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func dds(_ seed: UInt8) -> Data {
        var width = 2048, count = 128
        while true { count += max(1, (width + 3) / 4) * max(1, (width + 3) / 4) * 8; if width == 1 { break }; width /= 2 }
        var data = Data(repeating: seed, count: count)
        data.replaceSubrange(0..<128, with: Data(count: 128)); data.replaceSubrange(0..<4, with: Data("DDS ".utf8))
        func word(_ value: UInt32, _ offset: Int) { for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (8*i)) } }
        word(124,4);word(0xA1007,8);word(2048,12);word(2048,16);word(2048*2048/2,20);word(12,28)
        word(32,76);word(4,80);data.replaceSubrange(84..<88, with: Data("DXT1".utf8));word(0x401008,108)
        return data
    }
    static func syntheticPack(_ root: URL) throws -> URL {
        let pack = root.appendingPathComponent("pack")
        var assets: [[String: Any]] = []
        for (i, path) in ModernVisualAssets.destinations.enumerated() {
            let data = dds(UInt8(i+1));try put(data,pack.appendingPathComponent("payload/"+path))
            assets.append(["destination":path,"file":"payload/"+path,"sha256":digest(data),"bytes":data.count,
                           "width":2048,"height":2048,"mips":12,"format":"DXT1","license":"CC0-1.0",
                           "sourceURL":"https://ambientcg.com/get?file=Ground001_2K-PNG.zip","sourceAssetID":"Ground001"])
        }
        try put(JSONSerialization.data(withJSONObject: ["schema":1,"id":"synthetic-terrain-v1","assets":assets]),pack.appendingPathComponent("manifest.json"))
        return pack
    }
    @MainActor final class Box {
        let root: URL, data: URL, support: URL, config: URL
        let pack: URL
        init(_ root: URL, pack: URL) throws {
            self.root=root;data=root.appendingPathComponent("Data");support=root.appendingPathComponent("Support");config=root.appendingPathComponent("config.txt");self.pack=pack
            try fm.createDirectory(at: data, withIntermediateDirectories: true);try fm.createDirectory(at: support,withIntermediateDirectories:true)
        }
        var meta: URL { support.appendingPathComponent("GraphicsProfiles/ModernVisualAssets") }
        func service(fault: ((String) throws -> Void)? = nil, capacity: (() throws -> UInt64)? = nil) throws -> ModernVisualAssets {
            try ModernVisualAssets(dataDirectory:data,supportDirectory:support,packDirectory:pack,testingFault:fault,testingCapacity:capacity)
        }
        func current(_ path: String) throws -> Data? {
            let url=data.appendingPathComponent(path);return fm.fileExists(atPath:url.path) ? try Data(contentsOf:url) : nil
        }
        func originals() throws -> [String:Data] {
            var values:[String:Data]=[:]
            for (i,path) in ModernVisualAssets.destinations.enumerated() where i % 2 == 0 {
                let bytes=Data("original loose user texture \(i)".utf8);try put(bytes,data.appendingPathComponent(path));values[path]=bytes
            }
            try put(Data("classic".utf8),config)
            return values
        }
        func expect(_ values: [String:Data]) throws {
            for path in ModernVisualAssets.destinations { try check(try current(path)==values[path],path) }
        }
        func mode(_ mode: ModernVisualAssets.Mode) throws { try put(Data(mode.rawValue.utf8),config) }
        func apply(_ mode: ModernVisualAssets.Mode) throws -> ModernVisualAssets.ChangeResult {
            let previous=try? Data(contentsOf:config)
            return try service().apply(mode,configuration:{ try self.mode(mode) },rollbackConfiguration:{
                if let previous { try put(previous,self.config) }
            })
        }
    }
    static func malformedPack(_ original:URL,_ root:URL, mutate: (inout [String:Any]) throws -> Void) throws -> URL {
        // Tests with malformed metadata need no payload: failure must happen
        // before ANY game mutation, including when later files are unavailable.
        var document=try JSONSerialization.jsonObject(with:Data(contentsOf:original.appendingPathComponent("manifest.json"))) as! [String:Any]
        try mutate(&document);try put(JSONSerialization.data(withJSONObject:document),root.appendingPathComponent("manifest.json"));return root
    }
    static func run(pack:URL,root:URL) throws {
        let box=try Box(root.appendingPathComponent("roundtrip"),pack:pack),originals=try box.originals()
        let protected:[URL:Data]=[box.data.appendingPathComponent("Skyrim - Textures.bsa"):Data("archive sentinel".utf8),
            box.data.appendingPathComponent("user.esp"):Data("plugin sentinel".utf8),
            box.support.appendingPathComponent("Saves/save.ess"):Data("save sentinel".utf8),
            box.data.appendingPathComponent("textures/user-other.dds"):Data("unmanaged sentinel".utf8)]
        for (url,bytes) in protected { try put(bytes,url) }
        try check(try box.service().status().mode == .classic)
        try check(try box.apply(.modern).changedFiles==6)
        try check(try box.service().status().canLaunch)
        for path in ModernVisualAssets.destinations {
            try check(try box.current(path)==Data(contentsOf:pack.appendingPathComponent("payload/"+path)))
        }
        try check(try box.apply(.modern).changedFiles==0) // don't replace originals with managed payload
        try check(try box.apply(.classic).changedFiles==6);try box.expect(originals)
        try check(try box.service().status().mode == .classic)
        for (url,bytes) in protected { try check(try Data(contentsOf:url)==bytes) }

        let conflict=try Box(root.appendingPathComponent("conflict"),pack:pack);_ = try conflict.originals();_ = try conflict.apply(.modern)
        let foreign=Data("externally edited texture".utf8),target=ModernVisualAssets.destinations[0]
        try put(foreign,conflict.data.appendingPathComponent(target))
        try check(try !conflict.service().status().canLaunch)
        try rejects { _ = try conflict.apply(.classic) };try check(try conflict.current(target)==foreign)
        try check(try conflict.service().status().mode == .modern)

        let disk=try Box(root.appendingPathComponent("disk"),pack:pack),diskBefore=try disk.originals()
        var called=false
        try rejects { _ = try disk.service(capacity:{0}).apply(.modern,configuration:{called=true},rollbackConfiguration:{}) }
        try check(!called);try disk.expect(diskBefore);try check(try !disk.service().status().needsRecovery)

        for phase in ["afterAsset:"+target,"afterConfiguration","afterState"] {
            let failed=try Box(root.appendingPathComponent(UUID().uuidString),pack:pack),before=try failed.originals()
            let service=try failed.service(fault:{ if $0==phase { throw Deliberate.failure } })
            try rejects { _ = try service.apply(.modern,configuration:{try failed.mode(.modern)},rollbackConfiguration:{try failed.mode(.classic)}) }
            try failed.expect(before);try check(try Data(contentsOf:failed.config)==Data("classic".utf8))
            try check(try service.status().mode == .classic && !service.status().needsRecovery)
        }
        let configFailure=try Box(root.appendingPathComponent("config-failure"),pack:pack),configBefore=try configFailure.originals()
        try rejects { _ = try configFailure.service().apply(.modern,configuration:{try configFailure.mode(.modern);throw Deliberate.failure},rollbackConfiguration:{try configFailure.mode(.classic)}) }
        try configFailure.expect(configBefore);try check(try Data(contentsOf:configFailure.config)==Data("classic".utf8))

        let edited=try Box(root.appendingPathComponent("mid-transaction-edit"),pack:pack),editedBefore=try edited.originals()
        let editedService=try edited.service(fault:{ phase in
            if phase=="afterAsset:"+target { try put(foreign,edited.data.appendingPathComponent(target));throw Deliberate.failure }
        })
        try rejects { _ = try editedService.apply(.modern,configuration:{},rollbackConfiguration:{}) }
        try check(try edited.current(target)==foreign);try check(try editedService.status().needsRecovery)
        try rejects { _ = try editedService.recover(configurationMode:.classic) }
        for path in ModernVisualAssets.destinations.dropFirst() { try check(try edited.current(path)==editedBefore[path]) }

        let reentrant=try Box(root.appendingPathComponent("lock"),pack:pack);_ = try reentrant.originals()
        _ = try reentrant.service().apply(.modern,configuration:{try rejects { _ = try reentrant.service().status() }},rollbackConfiguration:{})
        try check(try reentrant.service().status().canLaunch)

        // Case-preserving lookup must keep existing user spelling and restore it.
        let cased=try Box(root.appendingPathComponent("cased"),pack:pack)
        let upper=cased.data.appendingPathComponent("Textures/Landscape/Dirt01.dds"),upperBytes=Data("case original".utf8)
        try put(upperBytes,upper);_ = try cased.apply(.modern);_ = try cased.apply(.classic)
        try check(try Data(contentsOf:upper)==upperBytes)
        let entries=try fm.contentsOfDirectory(atPath:upper.deletingLastPathComponent().path)
        try check(entries==["Dirt01.dds"])

        let link=try Box(root.appendingPathComponent("symlink"),pack:pack)
        let outside=link.root.appendingPathComponent("outside.dds");try put(foreign,outside)
        try fm.createDirectory(at:link.data.appendingPathComponent("textures/landscape"),withIntermediateDirectories:true)
        try fm.createSymbolicLink(at:link.data.appendingPathComponent(target),withDestinationURL:outside)
        try rejects { _ = try link.apply(.modern) };try check(try Data(contentsOf:outside)==foreign)
        let directoryLink=try Box(root.appendingPathComponent("directory-symlink"),pack:pack)
        try fm.createSymbolicLink(at:directoryLink.data.appendingPathComponent("textures"),withDestinationURL:link.root)
        try rejects { _ = try directoryLink.apply(.modern) };try check(try Data(contentsOf:outside)==foreign)

        let backup=try Box(root.appendingPathComponent("missing-backup"),pack:pack),backed=try backup.originals()
        _ = try backup.apply(.modern)
        let ownedBefore=try ModernVisualAssets.destinations.map { try backup.current($0) }
        try fm.removeItem(at:backup.meta.appendingPathComponent("backups/"+digest(backed[target]!)+".dds"))
        try rejects { _ = try backup.apply(.classic) }
        for (i,path) in ModernVisualAssets.destinations.enumerated() { try check(try backup.current(path)==ownedBefore[i]) }

        let sourceManifest=try JSONDecoder().decode(ModernVisualAssets.Manifest.self,from:Data(contentsOf:pack.appendingPathComponent("manifest.json")))
        let asset=sourceManifest.assets[0],sourceDDS=try Data(contentsOf:pack.appendingPathComponent(asset.file))
        for offset in [4,8,12,16,20,28,76,80,84,108,112,124] {
            var damaged=sourceDDS;damaged[offset]^=0x80
            try rejects { try ModernVisualAssets.validateDDS(damaged,asset:asset) }
        }
        try rejects { try ModernVisualAssets.validateDDS(sourceDDS.dropLast(),asset:asset) }
        var extra=sourceDDS;extra.append(0);try rejects { try ModernVisualAssets.validateDDS(extra,asset:asset) }

        let badDDS=root.appendingPathComponent("bad-dds-pack")
        try fm.copyItem(at:pack,to:badDDS)
        var invalidDDS=sourceDDS;invalidDDS[112]=1 // cubemap not a 2D terrain tile
        try put(invalidDDS,badDDS.appendingPathComponent(asset.file))
        var invalidDocument=try JSONSerialization.jsonObject(with:Data(contentsOf:badDDS.appendingPathComponent("manifest.json"))) as! [String:Any]
        var invalidAssets=invalidDocument["assets"] as! [[String:Any]]
        invalidAssets[0]["sha256"]=digest(invalidDDS);invalidDocument["assets"]=invalidAssets
        try put(JSONSerialization.data(withJSONObject:invalidDocument),badDDS.appendingPathComponent("manifest.json"))
        let invalidBox=try Box(root.appendingPathComponent("bad-dds"),pack:badDDS),invalidBefore=try invalidBox.originals()
        try rejects { _ = try invalidBox.apply(.modern) };try invalidBox.expect(invalidBefore)

        let linkPack=root.appendingPathComponent("symlink-pack")
        try fm.copyItem(at:pack,to:linkPack);try fm.removeItem(at:linkPack.appendingPathComponent(asset.file))
        try fm.createSymbolicLink(at:linkPack.appendingPathComponent(asset.file),withDestinationURL:pack.appendingPathComponent(asset.file))
        let linkPackBox=try Box(root.appendingPathComponent("symlink-pack-destination"),pack:linkPack)
        try rejects { _ = try linkPackBox.apply(.modern) }

        for (name,mutation) in [
            ("traversal",{ (a:inout [[String:Any]]) in a[0]["file"]="../outside.dds" }),
            ("absolute",{ (a:inout [[String:Any]]) in a[0]["destination"]="/textures/landscape/dirt01.dds" }),
            ("case",{ (a:inout [[String:Any]]) in a[0]["destination"]="Textures/landscape/dirt01.dds" }),
            ("duplicate",{ (a:inout [[String:Any]]) in a[1]=a[0] }),
            ("native",{ (a:inout [[String:Any]]) in a[0]["destination"]="textures/landscape/payload.dylib" }),
            ("format",{ (a:inout [[String:Any]]) in a[0]["format"]="DX10" }),
            ("license",{ (a:inout [[String:Any]]) in a[0]["license"]="retail" }),
            ("bad-sha",{ (a:inout [[String:Any]]) in a[0]["sha256"]=String(repeating:"0",count:64) })
        ] {
            let invalid=try malformedPack(pack,root.appendingPathComponent("pack-"+name)) { d in var a=d["assets"] as! [[String:Any]];mutation(&a);d["assets"]=a }
            let f=try Box(root.appendingPathComponent("invalid-"+name),pack:invalid),prior=try f.originals()
            try rejects { _ = try f.apply(.modern) };try f.expect(prior);try check(try !f.service().status().needsRecovery)
        }
    }
    static func crashTests(pack:URL,root:URL) throws {
        for phase in ["afterAsset:"+ModernVisualAssets.destinations[0],"afterConfiguration"] {
            let f=try Box(root.appendingPathComponent(UUID().uuidString),pack:pack),prior=try f.originals()
            let child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments=["--crash",f.root.path,pack.path,phase]
            try child.run();child.waitUntilExit();try check(child.terminationStatus==91)
            let service=try f.service();try check(try service.status().needsRecovery)
            let configMode=ModernVisualAssets.Mode(rawValue:String(decoding:try Data(contentsOf:f.config),as:UTF8.self))!
            let recovered=try service.recover(configurationMode:configMode);try check(recovered.canLaunch)
            if phase=="afterConfiguration" { try check(recovered.mode == .modern);_ = try f.apply(.classic) }
            try f.expect(prior)
        }
    }
    static func configurationRollbackRecovery(pack:URL,root:URL) throws {
        for target in [ModernVisualAssets.Mode.modern,.classic] {
            let f=try Box(root.appendingPathComponent("rollback-"+target.rawValue),pack:pack),originals=try f.originals()
            if target == .classic { _ = try f.apply(.modern) }
            let before=try ModernVisualAssets.destinations.map { try f.current($0) }
            let service=try f.service(fault:{if $0=="afterConfiguration" {throw Deliberate.failure}})
            try rejects { _ = try service.apply(target,configuration:{try f.mode(target)},rollbackConfiguration:{throw Deliberate.failure}) }
            for (i,path) in ModernVisualAssets.destinations.enumerated() { try check(try f.current(path)==before[i]) }
            try check(try service.status().needsRecovery)
            try check(try Data(contentsOf:f.config)==Data(target.rawValue.utf8))
            let recovered=try service.recover(configurationMode:target)
            try check(recovered.mode==target && recovered.canLaunch)
            if target == .modern {
                for path in ModernVisualAssets.destinations {
                    try check(try f.current(path)==Data(contentsOf:pack.appendingPathComponent("payload/"+path)))
                }
                _ = try f.apply(.classic)
            }
            try f.expect(originals)
        }

        // ALL paths/payloads must pass before replaying even the first file.
        for problem in ["external-edit","missing-last-blob","no-space"] {
            let f=try Box(root.appendingPathComponent(problem),pack:pack),originals=try f.originals()
            let service=try f.service(fault:{if $0=="afterConfiguration" {throw Deliberate.failure}})
            try rejects { _ = try service.apply(.modern,configuration:{try f.mode(.modern)},rollbackConfiguration:{throw Deliberate.failure}) }
            let last=ModernVisualAssets.destinations.last!,foreign=Data("external edit remains".utf8)
            if problem=="external-edit" { try put(foreign,f.data.appendingPathComponent(last)) }
            if problem=="missing-last-blob" {
                let payload=try Data(contentsOf:pack.appendingPathComponent("payload/"+last))
                try fm.removeItem(at:f.meta.appendingPathComponent("backups/"+digest(payload)+".dds"))
            }
            let recovering=try f.service(capacity:problem=="no-space" ? {0}:nil)
            try rejects { _ = try recovering.recover(configurationMode:.modern) }
            try check(try recovering.status().needsRecovery)
            for path in ModernVisualAssets.destinations {
                try check(try f.current(path)==(problem=="external-edit" && path==last ? foreign:originals[path]))
            }
        }
    }
    static func main() throws {
        if CommandLine.arguments.count==5,CommandLine.arguments[1]=="--crash" {
            let f=try Box(URL(fileURLWithPath:CommandLine.arguments[2]),pack:URL(fileURLWithPath:CommandLine.arguments[3]))
            let event=CommandLine.arguments[4]
            _ = try f.service(fault:{if $0==event {_exit(91)}}).apply(.modern,configuration:{try f.mode(.modern)},rollbackConfiguration:{try f.mode(.classic)})
            _exit(92)
        }
        let root=fm.temporaryDirectory.appendingPathComponent("Skyrim-ModernAssets-\(UUID().uuidString)")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let pack:URL
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--pack" {pack=URL(fileURLWithPath:CommandLine.arguments[2])}
        else {pack=try syntheticPack(root.appendingPathComponent("synthetic"))}
        try run(pack:pack,root:root);try crashTests(pack:pack,root:root);try configurationRollbackRecovery(pack:pack,root:root)
        print("ModernVisualAssets: \(checks) checks PASS; six DDS files, original restore, conflicts, rollback and process-crash recovery; no app/device/game")
    }
}
