# Reversible bundled Modern textures

`ModernVisualAssets` owns exactly six loose `textures/landscape` DDS files:
`dirt01`, `dirtpath01`, `pineforest01`, and their `_n` normal maps. It never
changes a BSA, ESP, executable, archive list, INI or save. Modern's configuration
changes remain the separate `GraphicsProfileStore` participant.

The source pack is independently produced from ambientCG CC0 materials. Bundle
`modern-visuals/pack` as a preserved resource folder, then pass its actual URL
containing `manifest.json`. No download, account, runtime plugin or Nexus mod is
part of this installer. Modern starter coverage is these terrain materials;
this is not a complete texture overhaul, AI/quest mod or performance claim.

## API and launch coordination

```swift
let assets = try ModernVisualAssets(
    dataDirectory: NativeRuntime.gameDirectory.appendingPathComponent("Data"),
    supportDirectory: SkyrimSaveLocations.supportDirectory,
    packDirectory: bundledPackURL)
```

The installer appends `GraphicsProfiles/ModernVisualAssets` to the supplied
support root, **outside Saves**. Its synchronous API is designed for the main
actor while the launcher holds its existing idle/busy/Play gate:

- `status() throws -> Status` returns `mode`, `packID`, `needsRecovery`,
  `conflicts`, `canLaunch`.
- `apply(.modern/.classic, configuration: throwingClosure,
  rollbackConfiguration: throwingClosure) throws -> ChangeResult` returns the
  committed `mode` and `changedFiles` only after both participants finish.
- `recover(configurationMode: .modern/.classic) throws -> Status` resolves an
  interrupted asset transaction using the configuration participant's verified
  actual mode.

Before changing a profile, capture the configuration store's exact checkpoint.
The configuration closure applies the requested profile and captures its
post-change checkpoint. Treat profile conflicts as errors. The rollback closure
restores the original checkpoint **replacing only that exact post-change
checkpoint**, including its prior baseline metadata. Applying the opposite mode
is not an equivalent rollback, especially after a custom Modern setting.

The caller must recover the configuration participant first on launch and
before Play, then pass its verified mode to `assets.recover`. If configuration
is unknown, pending or conflicted, do not guess from a picker/UserDefaults:
block Play and report the issue. With a pending asset journal, status may report
expected partial-transaction differences against the old state; recovery must
run before interpreting those differences as final external conflicts.

After recovery, require `canLaunch` and equality of the actual configuration and
asset modes. A thrown validation/I/O/recovery error also blocks Play. The two
public modes must not appear successfully changed from a UI selection alone.
There is no device install or launch in this service or its tests.

## Validation and ownership

Schema 1 manifests have an ID and exactly six entries. Every destination is a
fixed lowercase allowlisted path; its payload path must be `payload/` plus that
destination. Duplicate destinations, case variations, absolute/traversal paths,
native-code destinations and unsupported types fail preflight. Every entry
requires a matching SHA256, byte count, `CC0-1.0` license and HTTPS ambientCG
source URL/asset ID.

Each image must be a legacy 2D DDS, 2048 by 2048, FOURCC `DXT1`, complete 12-level
mip chain, expected texture/mipmap caps and exact computed payload length.
DX10, cubemap/volume headers, missing/trailing mip data and alternate formats
are rejected. The actual pack is 2,796,344 bytes per image, 16,778,064 bytes total.

All pack images, current destinations, existing originals and capacity on both
volumes are checked before any game-data mutation. Capacity includes a
conservative staging/rollback allowance. Backups are immutable content-addressed
files (`backups/<SHA256>.dds`) verified again before writing destinations.
Metadata and backups are independent of cloud saves and are retained for
recovery; this feature never prunes old backups.

Every relative directory and file is opened through a directory descriptor
with `O_NOFOLLOW`. The root itself must be a real directory. Case-insensitive
lookup preserves existing spelling and refuses ambiguous duplicate spellings
on a case-sensitive volume. Existing loose originals are backed up and verified
before replacement. Classic removes only unchanged managed payloads and
restores the exact original bytes, or removes the payload when no loose original
existed. Files changed or deleted externally are preserved and reported; the
service does not force a mode change over them.

The caller's idle gate prevents its other game/profile writers from interleaving;
an advisory exclusive file lock also prevents concurrent installer instances.
Each destination is rechecked against its expected fingerprint immediately
before its atomic replacement/removal. No game process should be reading or
writing these paths during a mode transaction.

## Journal and failure behavior

The write-ahead journal records the before/after ownership states and the
before/after fingerprint of every affected destination. Payload/original blobs
are verified before the journal is committed. File contents are staged in the
same directory, flushed and atomically renamed; directory changes are flushed.

After all assets finish, `configurationMayHaveChanged` is persisted **before**
calling the configuration participant. The asset state is committed only after
that callback returns. A normal failure reverses exact transaction-owned
changes and invokes the supplied configuration rollback when necessary.
Conflicting user changes or failed rollback leave the journal pending and
report an error instead of returning success.

For process interruption before configuration, recovery rolls assets back.
After configuration may have committed, recovery completes the requested asset
state when the verified configuration matches the target and every affected file
matches its journal's before OR after fingerprint. It preflights all destinations,
required verified after blobs and staging capacity before replaying only known
before values, then verifies every after value before committing. This repairs
our asset rollback when configuration rollback or its after-checkpoint read
failed; those known originals are not mistaken for unrelated user edits. If the
verified configuration differs from the target, recovery rolls back only known
before/after values. Any unrelated value is preserved and leaves recovery
pending. The real configuration store is responsible for its own recovery.

## Host checks

```sh
python3 apple/Tests/run_modern_assets_checks.py
python3 apple/Tests/run_modern_assets_checks.py --pack /absolute/modern-visuals/pack
```

Checks compile one job at a time with Swift 6/AddressSanitizer and typecheck the
service for iPhoneOS and xros. Without a pack, DDS fixtures are generated in a
temporary directory. A supplied pack is read-only; all installs occur in
temporary Data/support roots. Tests cover install/reinstall/Classic, existing
loose originals, case preservation, protected save/BSA/ESP/unmanaged files,
external conflicts, symlinks, low disk space, bad paths/format/license/hashes,
DDS header/mip corruption, missing originals, configuration and finalization
failures, and abrupt child-process exits before/after configuration. The JSON
receipt records source and optional manifest hashes. These are filesystem and
SDK checks, not installed-device visuals or performance acceptance.
