#if GRAPHICS_COORDINATOR_HOST_TESTS
import Foundation
import CryptoKit

// Compile the entire production coordinator, including its launcher factory;
// only app-specific factory types are stubbed. The factory is not executed.
struct LauncherModel { enum Runtime { case nativeDevice, other }; var runtime: Runtime = .other }
enum SkyrimSaveLocations {
    static let runtimeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("factory-not-executed")
    static let supportDirectory = runtimeRoot
    static func resolve(_ parts: [String], in root: URL) -> URL { parts.reduce(root) { $0.appendingPathComponent($1) } }
}
@main @MainActor struct GraphicsVisualModeCoordinatorTests {
    static let fm = FileManager.default
    static let pack = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    static var checks = 0
    struct Failed: Error, CustomStringConvertible { let description: String }
    static let baseline = Data("; preserved\r\n[Display]\r\niMaxAnisotropy=2\r\niShadowMapResolution=1024\r\niSize W=2420\r\niSize H=1668\r\niTexMipMapSkip=0\r\n[Controls]\r\nbGamepadEnable=1\r\n".utf8)
    static let archive = Data("[Archive]\r\nsResourceArchiveList=Skyrim - Textures.bsa\r\nsResourceArchiveList2=Skyrim - Voices.bsa\r\n".utf8)
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: UInt = #line) throws {
        checks += 1; if try !condition() { throw Failed(description: "line \(line): \(message)") }
    }
    static func rejects(_ body: () throws -> Void, _ message: String, line: UInt = #line) throws {
        checks += 1; do { try body() } catch { return }; throw Failed(description: "line \(line): accepted \(message)")
    }
    static func put(_ bytes: Data, _ url: URL) throws { try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try bytes.write(to:url,options:.atomic) }
    final class FaultIO: GraphicsProfileFileIO, @unchecked Sendable {
        enum Fault { case none, backup, finalStateOnce, afterCommitRead }
        let local = LocalGraphicsProfileFileIO(); var fault: Fault = .none; var tripped = false; var armReadFailure = false
        func exists(_ url:URL)->Bool {local.exists(url)}
        func read(_ url:URL)throws->Data {
            if armReadFailure && !tripped && url.lastPathComponent == "SkyrimPrefs.ini" {tripped=true;throw Failed(description:"injected post-commit checkpoint read failure")}
            return try local.read(url)
        }
        func makeDirectory(_ url:URL)throws {try local.makeDirectory(url)}
        func writeAtomic(_ data:Data,to url:URL)throws {
            if !tripped && fault == .backup && url.lastPathComponent == "before.ini" {tripped=true;throw Failed(description:"injected backup failure")}
            if !tripped && fault == .finalStateOnce && url.lastPathComponent == "state.json", let state=try? JSONSerialization.jsonObject(with:data) as? [String:Any], state["mode"] as? String == "modern", state["pending"] == nil {tripped=true;throw Failed(description:"injected final profile metadata failure")}
            try local.writeAtomic(data,to:url)
            if fault == .afterCommitRead && url.lastPathComponent == "state.json", let state=try? JSONSerialization.jsonObject(with:data) as? [String:Any], state["mode"] as? String == "modern", state["pending"] == nil {armReadFailure=true}
        }
    }
    @MainActor final class Fixture {
        let root:URL, data:URL, support:URL, prefs:URL, ini:URL, io:FaultIO
        let profile:GraphicsProfileStore
        let coordinator:GraphicsVisualModeCoordinator
        init(_ name:String, prefsPresent:Bool=true, packOverride:URL?=nil, iniBytes:Data?=archive) throws {
            root=fm.temporaryDirectory.appendingPathComponent("skyrim-coordinator-"+name+"-"+UUID().uuidString,isDirectory:true)
            data=root.appendingPathComponent("Data");support=root.appendingPathComponent("Support");prefs=root.appendingPathComponent("User/SkyrimPrefs.ini");ini=root.appendingPathComponent("User/Skyrim.ini");io=FaultIO()
            try fm.createDirectory(at:data,withIntermediateDirectories:true);try fm.createDirectory(at:support,withIntermediateDirectories:true);try fm.createDirectory(at:prefs.deletingLastPathComponent(),withIntermediateDirectories:true)
            if prefsPresent {try put(baseline,prefs)};if let iniBytes {try put(iniBytes,ini)}
            profile=GraphicsProfileStore(preferencesURL:prefs,metadataDirectory:support.appendingPathComponent("GraphicsProfiles"),io:io)
            coordinator=GraphicsVisualModeCoordinator(profile:profile,dataDirectory:data,supportDirectory:support,packDirectory:packOverride ?? pack)
        }
        deinit {try? FileManager.default.removeItem(at:root)}
        func assets()throws->ModernVisualAssets {try ModernVisualAssets(dataDirectory:data,supportDirectory:support,packDirectory:pack)}
        func current(_ destination:String)throws->Data? {let u=data.appendingPathComponent(destination);return fm.fileExists(atPath:u.path) ? try Data(contentsOf:u) : nil}
        func expectPack()throws {for p in ModernVisualAssets.destinations {try check(try current(p)==Data(contentsOf:pack.appendingPathComponent("payload/"+p)),"installed "+p)}}
        func expectEmpty()throws {for p in ModernVisualAssets.destinations {try check(try current(p)==nil,"removed "+p)}}
    }
    static func roundtrip()throws {
        let f=try Fixture("roundtrip");var originals:[String:Data]=[:]
        for (i,p) in ModernVisualAssets.destinations.enumerated() where i%2==0 {let d=Data("custom original \(i)".utf8);try put(d,f.data.appendingPathComponent(p));originals[p]=d}
        let sentinel=f.support.appendingPathComponent("Saves/preserved.ess");try put(Data("save sentinel".utf8),sentinel)
        try check(try f.coordinator.prepareForLaunch() == .classic,"initial classic")
        try check(try f.coordinator.apply(.modern,gameIsActive:false,isBusy:false).mode == .modern,"modern selected");try f.expectPack()
        try check(try f.coordinator.prepareForLaunch() == .modern,"modern launch ready")
        try check(try Data(contentsOf:f.ini)==archive,"Archive INI unchanged")
        try check(try f.coordinator.apply(.classic,gameIsActive:false,isBusy:false).mode == .classic,"classic selected")
        for p in ModernVisualAssets.destinations {try check(try f.current(p)==originals[p],"original restored "+p)}
        try check(try Data(contentsOf:f.prefs)==baseline,"exact original preferences restored")
        try check(try Data(contentsOf:sentinel)==Data("save sentinel".utf8),"save untouched")
    }
    static func adoption()throws {
        let f=try Fixture("adopt");var modern=try GraphicsProfileINI(data:baseline);modern.applyModern();try put(try modern.encoded(),f.prefs)
        try f.profile.adoptModernBaseline(originalPreferences:baseline,gameIsActive:false,isBusy:false)
        try check(try f.assets().status().mode == .classic,"no texture state before adoption launch")
        try check(try f.coordinator.prepareForLaunch() == .modern,"adopted modern reconciled");try f.expectPack()
        _=try f.coordinator.apply(.classic,gameIsActive:false,isBusy:false)
        try check(try Data(contentsOf:f.prefs)==baseline,"adopted baseline survives asset install");try f.expectEmpty()
    }
    static func firstLaunchAndMissingManaged()throws {
        let first=try Fixture("first",prefsPresent:false)
        try check(try first.coordinator.prepareForLaunch() == .classic,"unmanaged missing prefs allow first launch");try first.expectEmpty()
        let managed=try Fixture("missing-managed");_=try managed.coordinator.apply(.modern,gameIsActive:false,isBusy:false);try fm.removeItem(at:managed.prefs)
        try rejects({_ = try managed.coordinator.prepareForLaunch()},"managed missing preferences");try managed.expectPack()
        let damaged=try Fixture("unknown-record",prefsPresent:false)
        try put(Data("not JSON".utf8),damaged.profile.metadataDirectory.appendingPathComponent("state.json"))
        try rejects({_ = try damaged.coordinator.prepareForLaunch()},"unknown profile record without preferences")
    }
    static func guards()throws {
        let f=try Fixture("guards")
        for (active,busy) in [(true,false),(false,true),(true,true)] {
            try rejects({_ = try f.coordinator.apply(.modern,gameIsActive:active,isBusy:busy)},"active/busy apply")
            try rejects({_ = try f.coordinator.status(gameIsActive:active,isBusy:busy)},"active/busy status")
        }
        try check(try Data(contentsOf:f.prefs)==baseline,"guards preserve preferences");try f.expectEmpty()
    }
    static func failures()throws {
        for fault in [FaultIO.Fault.backup,.finalStateOnce] {
            let f=try Fixture("config-failure");f.io.fault=fault
            try rejects({_ = try f.coordinator.apply(.modern,gameIsActive:false,isBusy:false)},"profile IO failure")
            try check(f.io.tripped,"injected production profile path reached")
            try check(try f.profile.status().mode == .classic,"profile rollback classic")
            let assets=try f.assets().status();try check(assets.mode == .classic && assets.canLaunch,"asset rollback matching classic");try f.expectEmpty()
            try check(try Data(contentsOf:f.prefs)==baseline,"failed config exact bytes restored")
        }
        let broken=fm.temporaryDirectory.appendingPathComponent("bad-pack-"+UUID().uuidString);defer {try? fm.removeItem(at:broken)}
        try put(Data("{}".utf8),broken.appendingPathComponent("manifest.json"));let f=try Fixture("asset-failure",packOverride:broken)
        try rejects({_ = try f.coordinator.apply(.modern,gameIsActive:false,isBusy:false)},"invalid pack")
        try check(try f.profile.status().mode == .classic,"pack failure leaves config classic");try f.expectEmpty()
        try check(try Data(contentsOf:f.ini)==archive,"failed apply Archive INI unchanged")
    }
    static func postCommitCheckpointRecovery()throws {
        let f=try Fixture("post-checkpoint-failure");f.io.fault = .afterCommitRead
        try rejects({_ = try f.coordinator.apply(.modern,gameIsActive:false,isBusy:false)},"post-commit checkpoint read failure")
        try check(f.io.tripped,"after commit checkpoint failure reached")
        let recovered=try f.coordinator.prepareForLaunch()
        let state=try f.assets().status()
        try check(state.canLaunch && state.mode.rawValue == recovered.rawValue,"transient checkpoint failure can recover to matching modes")
        if recovered == .modern {try f.expectPack()} else {try f.expectEmpty()}
    }
    static func conflicts()throws {
        let f=try Fixture("classic-custom");_=try f.coordinator.apply(.modern,gameIsActive:false,isBusy:false)
        let customized=String(decoding:try Data(contentsOf:f.prefs),as:UTF8.self).replacingOccurrences(of:"iShadowMapResolution=2048",with:"iShadowMapResolution=1536")
        try put(Data(customized.utf8),f.prefs)
        let result=try f.coordinator.apply(.classic,gameIsActive:false,isBusy:false)
        try check(!result.conflicts.isEmpty && result.mode == .classic,"safe customized classic reported")
        try check(try f.coordinator.prepareForLaunch() == .classic,"custom numeric classic remains launchable");try f.expectEmpty()
        try check(String(decoding:try Data(contentsOf:f.prefs),as:UTF8.self).contains("iShadowMapResolution=1536"),"custom graphics retained")
        let a=try Fixture("asset-conflict");_=try a.coordinator.apply(.modern,gameIsActive:false,isBusy:false)
        let destination=ModernVisualAssets.destinations[0];try put(Data("foreign user file".utf8),a.data.appendingPathComponent(destination))
        try rejects({_ = try a.coordinator.prepareForLaunch()},"foreign asset mutation")
        try rejects({_ = try a.coordinator.apply(.classic,gameIsActive:false,isBusy:false)},"conflicting asset restore")
        try check(try a.current(destination)==Data("foreign user file".utf8),"foreign file retained")
    }
    static func archivePolicy()throws {
        let bad:[String] = [
            "[Archive]\nbInvalidateOlderFiles=0\n",
            "[ Archive ]\nbInvalidateOlderFiles=0\n",
            "[aRcHiVe]\n bInVaLiDaTeOlDeRfIlEs = false\n",
            "[Archive]\nbInvalidateOlderFiles=0junk\n",
            "[Archive]\nbInvalidateOlderFiles=\n",
            "[Archive]\nbInvalidateOlderFiles=0\nbInvalidateOlderFiles=1\n",
            "[Archive]\nsResourcePrefixList=MESHES\\, SOUND\\\n",
            "[Archive]\nsResourcePrefixList=TEXTURES\\ ;inline is literal\n",
            "[Archive]\nsResourcePrefixList=\n"
        ]
        for (i,ini) in bad.enumerated() {
            let bytes=Data(ini.utf8),f=try Fixture("bad-policy-\(i)",iniBytes:bytes)
            try rejects({_ = try f.coordinator.apply(.modern,gameIsActive:false,isBusy:false)},"disabled/ambiguous Archive case\(i)")
            try check(try Data(contentsOf:f.ini)==bytes,"custom Archive kept");try f.expectEmpty()
        }
        var latin1=Data([0x3B,0xE9,0x0A]);latin1.append(Data("[Archive]\nbInvalidateOlderFiles=0\n".utf8))
        if latin1.count % 2 != 0 {latin1.append(0x0A)}
        let legacy=try Fixture("latin1-custom-policy",iniBytes:latin1)
        try rejects({_ = try legacy.coordinator.apply(.modern,gameIsActive:false,isBusy:false)},"Latin1 comment must not hide ASCII disabled policy")
        try legacy.expectEmpty()
        let valid="[ Archive ]\nbInvalidateOlderFiles=1\nsResourcePrefixList= Textures\\ , MESHES\\\n"
        let f=try Fixture("valid-custom-policy",iniBytes:Data(valid.utf8))
        _=try f.coordinator.apply(.modern,gameIsActive:false,isBusy:false);try f.expectPack()
        try check(try Data(contentsOf:f.ini)==Data(valid.utf8),"valid custom policy unchanged")
        let absent=try Fixture("absent-ini",iniBytes:nil)
        _=try absent.coordinator.apply(.modern,gameIsActive:false,isBusy:false);try absent.expectPack()
        try check(!fm.fileExists(atPath:absent.ini.path),"missing Archive INI not manufactured")
    }
    static func main() {
        let suites:[(String,()throws->Void)] = [("roundtrip",roundtrip),("adopted personal Modern",adoption),("first launch / managed missing",firstLaunchAndMissingManaged),("paused / busy",guards),("config and pack failures",failures),("post-commit checkpoint recovery",postCommitCheckpointRecovery),("safe Classic customization / asset conflict",conflicts),("Archive lexical policy",archivePolicy)]
        var failures:[String]=[]
        for (name,test) in suites {do {try test();print("PASS "+name)}catch {failures.append(name+": "+String(describing:error));print("FAIL "+failures.last!)}}
        print("combined production checks: \(checks), suites passed \(suites.count-failures.count)/\(suites.count)")
        if !failures.isEmpty {exit(1)}
    }
}

#endif
