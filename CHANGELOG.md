# Changes

## v9.1

Expanded UI slider ranges to match the supported high limits: tree depth 200, script size 10000 KB and decompile timeout 120 seconds. Users can keep the menu while setting these limits. Max speed remains available and uses the same underlying decompiler.

Verification: the 80 existing actual-source regressions and Luau 0.748 analysis/compilation passed. Rendered UI and live Potassium remain unverified.

## v9

Added bounded asset inventory and optional individual script files with manifest/index references. Source exports preserve the collected text, including its newline shape; constants-only exports use a distinct extension. Redaction remains report-only for source exports.

Fixed wide sibling loops that bypassed the per-frame budget, oversized dedupe keys, stale crash skips for known changed script hashes, unsafe state-read handling, false-return writes, UTF-8 truncation, and ambiguous serialized instance references. Successful saves release capture text; failed saves retain it.

Added Potassium alias lookup and observed executor version reporting. An empty bytecode result no longer skips an otherwise readable decompile target.

Independent review identified two additional boundary issues: user-avatar thumbnails were incorrectly normalized as asset IDs, and a missing isfile API could abort the first capture. Both were fixed with focused regressions. Unreadable state with unknown existence now disables journaling instead of truncating it.

Verification: 80 regressions passed against the actual source, Luau 0.748 analyzer/compiler exit 0. Standalone host-type/getfenv warnings remain. V9 live Potassium and rendered menu checks were not performed.

### Primary compatibility sources

- [Potassium getscriptbytecode](https://docs.potassium.pro/api-reference/Script%20Library/getscriptbytecode): `dumpstring` alias; empty-string behavior is not specified.
- [Potassium identifyexecutor](https://docs.potassium.pro/api-reference/Miscellaneous%20Library/identifyexecutor): name/version return values and `getexecutorname` alias.
- [Potassium getscriptclosure](https://docs.potassium.pro/api-reference/Script%20Library/getscriptclosure): `getscriptfunction` alias.
- [Potassium decompile](https://docs.potassium.pro/api-reference/Script%20Library/decompile): one target argument and pseudocode output, with no documented native timeout argument.
- [Potassium getgenv](https://docs.potassium.pro/api-reference/Environment%20Library/getgenv): shared executor environment.
- [Content.Uri](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/datatypes/Content.yaml#L142), [Decal](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/Decal.yaml), [SurfaceAppearance](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/SurfaceAppearance.yaml): readable URI-backed alternatives. Protected MaterialVariant properties remain guarded/skipped.
- [Roblox task.cancel](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/libraries/task.yaml#L246): cancellation can fail in some thread states.

## v8

Initial reliability improvements: folded-folder capture, escaped paths, precision/rotation, cooperative timeouts, completed crash attempts, corrected deduplication keys, checked saves, multipart manifests, option snapshots and reload guards.

The v8 tag preserves the previous release.
