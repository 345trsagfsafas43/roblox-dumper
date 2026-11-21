# Roblox Dumper v9

A Roblox client dumper with asset inventory, optional individual source files, and guarded capture/output handling.

## Run

```lua
loadstring(game:HttpGet('https://raw.githubusercontent.com/345trsagfsafas43/roblox-dumper/v9/dumper.lua'))()
```

RightShift toggles the menu. Choose the capture options, then press **Start dump**.

For richer output with separate source files:

```lua
getgenv().DumperConfig = {
    ExportScripts = true,
    Assets = true,
    Output = "Split files",
    Speed = "Smooth",
    MaxScriptChars = 1000000,
}
loadstring(game:HttpGet('https://raw.githubusercontent.com/345trsagfsafas43/roblox-dumper/v9/dumper.lua'))()
```

Add `AutoStart = true, NoUI = true` for a headless capture.

## Output

Files are written to `Dumper/<PlaceId>/` in the executor workspace, or to flat filenames when folder creation is unavailable. Start with `Dump.txt` or `Index.txt`; `Manifest.txt` records real filenames, part line ranges, script results, and capture limits.

- **Asset inventory** lists client-visible mesh, texture, image, sound, animation, video, skybox and clothing references, with locations and bounded use samples. It supports readable URI-backed Content properties. Assets are referenced, not downloaded.
- **Individual script files** are optional: enable **Save individual script files**. Source files preserve collected text; constants-only captures use `.constants.txt`. Duplicate script entries can point to the same file. Truncation remains explicit.
- **Potassium compatibility** resolves documented aliases such as `dumpstring`, reads inspection/filesystem functions from the script or shared environment, and records observed executor name/version.
- **Wide traversal** checks the frame budget and cancellation inside sibling/constant loops.
- **Memory handling** limits retained duplicate key/path bytes and releases capture text after successful saves. Large captures can still use substantial memory during collection; the cache limit is not a whole-process RAM limit.
- **Crash tracking** uses available script hashes. Without a hash, unstable ordinal paths are not persisted across runs. A simple path fallback still cannot identify code changes; clear old crash skips when needed.
- **Fidelity and saving** preserve UTF-8 boundaries and distinct instance references, report filesystem failures, and retain multipart navigation.

`HideName` redacts reports and filenames. Individual source files retain collected text and can contain names; they are not a scrubbed sharing format. Older unlisted script files may remain in the export directory: the current manifest identifies this capture's files.

`COMPLETE` means the run finished writing; filters, script failures, truncation and client visibility limits still apply. `PARTIAL` indicates an interrupted capture; `WRITING` indicates unfinished report generation.

## Potassium and platform limits

Compatibility work follows [Potassium's primary documentation](https://docs.potassium.pro/api-reference/introduction). See [CHANGELOG.md](CHANGELOG.md) for source links and the tested behavior.

The user's v8 runs in Potassium. V9 has been verified with offline fixtures; its live executor and rendered menu behavior remain unverified. The installed Potassium version is unknown until the dumper observes it.

Decompile output depends on the executor and can be pseudocode. Server-only source and unloaded streamed map regions are unavailable. Native executor calls that block the scheduler cannot be guaranteed interruptible.

If state existence cannot be queried and an existing state file cannot be read safely, capture continues with persistent crash tracking disabled and leaves that file untouched. The manifest records this limitation.

The menu uses a pinned Ui3 revision and optional Lucide icons. `NoUI=true` skips this download chain. Source credits remain in [ATTRIBUTION.md](ATTRIBUTION.md).

## Verification

80 actual-source regression tests passed using official Luau 0.748; analysis and compilation passed. Tests exercise source exports, assets, aliases/version reporting, wide-loop yielding, UTF-8, duplicate cache limits, crash state, cancellation, file failures, multipart indexing and buffer release.

For development, install the official [Luau 0.748 tools](https://github.com/luau-lang/luau/releases/tag/0.748), then invoke `tests/run-tests.ps1` with `-Luau` and `-Analyzer` pointing to those executables. Generated verification files stay in the ignored `.tools` folder.
