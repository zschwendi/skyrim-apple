# Classic / Modern graphics

Settings → Graphics offers one **Classic / Modern** choice. Modern changes 31
owned Skyrim graphics preferences: higher shadow detail, farther object/actor/
terrain/grass detail, water reflections, decals and anisotropic filtering. This
configuration service manages preferences. Native iOS/visionOS launcher builds also
coordinate a bundled CC0 2K terrain starter through `GraphicsVisualModeCoordinator`
and `ModernVisualAssets`. No Nexus account or downloaded mod is required. Mesh
replacement and ray tracing are not implemented; performance needs gameplay validation.

Native resolution, texture mip selection, MSAA, controls, audio, cloud choices and
saves are outside the managed key list. Both profiles apply next launch. The
control is disabled during launcher work and whenever a game session is active,
including paused sessions. A missing SkyrimPrefs.ini asks the user to launch
Skyrim once and quit; it does not create a fake ready profile.

Classic restores the managed values saved immediately before Modern was enabled.
Later custom changes to managed values are kept and listed in the UI. Unknown
lines and other options survive. Matching is case-insensitive; every duplicate
owned key is updated, avoiding first-vs-last duplicate ambiguity. UTF-8/BOM,
UTF-16/BOM, legacy single-byte text, line endings and a missing EOF newline are
preserved. A new Modern cycle captures the current Classic values as a fresh
baseline; earlier backups are never overwritten.

The real preferences file is the case-resolved
`Documents/My Games/Skyrim/SkyrimPrefs.ini` inside
`SkyrimSaveLocations.runtimeRoot`. The final component is explicitly a file URL.
Mac's bridge receives that same runtime root, so the service uses the same real
profile there. Backups and metadata stay device-local in
`SkyrimSaveLocations.supportDirectory/GraphicsProfiles`, outside cloud saves.

Each mutation writes and verifies an immutable per-operation `before.ini`, a
managed-key snapshot and a write-ahead journal before the atomic INI replacement.
On a failure, rollback touches only the exact bytes written by this operation.
After interruption, the journal reconciles the actual before/after owned keys;
conflicting subsequent edits remain untouched and require review. A corrupted
baseline or missing backup cannot silently restore preferences.

## Optional asset transaction seam

`GraphicsProfileStore.apply(_:gameIsActive:isBusy:)` synchronously returns mode
and preserved custom-key conflicts. Call on the main actor while idle, so Play
cannot interleave a write. The Foundation service itself owns no asset paths.

For an optional asset installer, capture `before = try store.checkpoint()`; run
`apply` in its configuration callback and capture `after = try store.checkpoint()`
after success. Its rollback callback uses:

```swift
try store.restore(before, replacing: after, gameIsActive: false, isBusy: false)
```

This restores exact prior managed values **and prior baseline metadata**, while
preserving unowned edits and refusing managed/state conflicts. Applying the
opposite profile is insufficient when Modern already contained custom values.
If a failed apply never produced `after`, inspect/reconcile `status()` rather
than guessing a profile. `GraphicsVisualModeCoordinator` binds the asset transaction, performs pre-launch
recovery and checks that custom file-loading settings permit replacement textures.
Classic 1.9.32 defaults already register `TEXTURES\`; the launcher does not add
SSE/Fallout archive keys. Actual winning DDS reads and physical appearance checks
remain separate acceptance evidence.

## Existing manually upgraded profiles

The baseline migration API requires all 31 current owned keys to match Modern,
backs up the supplied private original preferences, and writes profile metadata
without changing the current INI. Existing metadata is never overwritten. The
original file is a private local input and must not be added to source control.

For host-side copies from a fully closed game:

```sh
xcrun swiftc -swift-version 6 -parse-as-library -j1 \
  apple/Sources/Services/GraphicsProfile.swift \
  graphics-profiles/tools/adopt-modern-baseline.swift \
  -o graphics-profiles/build/adopt-modern-baseline
graphics-profiles/build/adopt-modern-baseline CURRENT_PREFS METADATA_DIRECTORY ORIGINAL_PREFS
```

## Checks

With one available compiler slot, from the repository root:

```sh
python3 graphics-profiles/tests/run_checks.py
```

The host checks execute the production service, including round trips preserving
native pixels/controls/unknowns, missing sections, duplicate keys, conflicts,
backup-before-write failure injection, journal recovery, exact prior profile
rollback, migration, encodings, activity guards and final file URL semantics.
The runner then typechecks the complete launcher in Swift 6 strict-concurrency
mode against the selected iPhoneOS and xros SDKs, sequentially. It accesses no
devices or game files. Compilation and configuration tests are not gameplay,
visual-quality, performance or installed-app acceptance.
