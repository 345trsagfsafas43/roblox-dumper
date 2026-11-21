# Roblox Dumper

A Roblox client dumper with improved capture completeness, output reliability, and run controls.

## Run

```lua
loadstring(game:HttpGet('https://raw.githubusercontent.com/345trsagfsafas43/roblox-dumper/v8/dumper.lua'))()
```

This loader uses the verified v8 release. RightShift toggles the menu. Choose the capture options, then press **Start dump**.

For a run without the menu:

```lua
getgenv().DumperConfig = {
    AutoStart = true,
    NoUI = true,
    Speed = "Smooth",
    Output = "Split files",
    MaxFileMB = 24,
}
loadstring(game:HttpGet('https://raw.githubusercontent.com/345trsagfsafas43/roblox-dumper/v8/dumper.lua'))()
```

## Output

Files are written to `Dumper/<PlaceId>/` in the executor workspace, or to flat filenames when folder creation is unavailable. Start with `Dump.txt` or `Index.txt`; `Manifest.txt` records real filenames, part line ranges, truncation, and script results.

- Repeated folder rows can fold while their included descendants are still scanned.
- Escaped instance paths distinguish duplicate names and literal brackets or periods.
- Numeric values and complete CFrame rotation are preserved.
- Empty hashes do not merge unrelated scripts.
- Yielding decompile and module workers have cooperative timeouts.
- Stop/reload handling prevents overlapping writers.
- File errors are reported instead of falsely claiming success.
- Multipart outputs include navigation metadata and UTF-8 boundary handling.

`COMPLETE` means the run finished writing; configured filters, script failures, truncation, and client visibility limits still apply. `PARTIAL` indicates a cancelled or interrupted run; `WRITING` indicates unfinished output generation.

## Scope and dependencies

This captures objects and code available to the client. Server-only source and unloaded streamed map regions are unavailable. Native executor calls that block the scheduler cannot be guaranteed interruptible. Long strings and tables are bounded previews.

The menu uses a pinned Ui3 revision and optionally loads Lucide icons. `NoUI=true` skips this download chain. See [ATTRIBUTION.md](ATTRIBUTION.md) for source credits.

## Verification

38 regression tests passed against the actual production source using official Luau 0.748, and analysis/compilation passed. The suite covers capture behind folded folders, paths, serialization, crash state, cancellation, file failures, multipart navigation, and reloads. Live Roblox/executor and rendered menu behavior remain unverified.

For development, install the official [Luau 0.748 tools](https://github.com/luau-lang/luau/releases/tag/0.748), then invoke `tests/run-tests.ps1` with `-Luau` and `-Analyzer` pointing to those executables. Generated verification files stay in the ignored `.tools` folder.
