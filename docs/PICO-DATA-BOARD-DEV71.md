# Pico semantic board delivery — dev71 / Mac build87

Information modules now send a bounded JSON snapshot over LAN or native USB. Both routes use the same data schema and retain the existing saved/displayed receipts, LAN-first routing and operation identity checks. USB display pushes do not export or mount TF storage. Pure photos and drawings retain full-resolution portrait/landscape BMP delivery.

`ReadPicoBoardModelBuilder` reads Lingxi's existing source caches. It does not read credentials or start a second source service. The 64 KiB model includes text, metrics, rows, trends, timing data and bounded gray4 artwork. Clock/date updates are drawn locally and do not trigger uploads merely because the time changed.

The native Mac preview mirrors the firmware's strict C parser and layout; source hashes live in `Sources/CPicoBoardRenderer/source-manifest.json`. CoreGraphics/CoreText provides the Mac drawing backend at 684×1216 or 1216×684, quantized to the panel's 16 gray levels. The C layout reserves the same top/bottom system areas. Device glyphs still come from its own font library.

Existing content-size, full-row, media direction, Cloudflare language/domain case and world-map/ranking preferences remain effective. The world map is a 4,588-byte bounded geometry file packaged in the app and embedded only in map snapshots; it is validated and atomically persisted with the model. No separate resource-install step is required.

Grok is explicitly labelled as status/quota display in this version. Animation has not been ported and is not represented as completed.

## Validation

- Complete Mac application and smoke-test targets compile.
- Dedicated model/native-preview suite: 74 checks, including strict parsing, bounds, all module kinds, semantic change detection, 16-gray portrait/landscape output, timezone, layout options, old-firmware rejection and USB receipt semantics.
- Production Swift `DirectWire` → OS-created PTY → real firmware C consumer: normal and ASan builds both pass background-save and immediate-display transactions. The stored JSON matches the source bytes exactly, with real handshake, task IDs, chunk ACKs and CRC verification. Each run completes 75 smoke checks.
- The mirrored parser/layout/helper/vendor files are byte-identical to the firmware sources and match their recorded hashes.
- Physical USB/Wi-Fi transfer and physical panel performance remain separate acceptance checks; host PTY and native rendering tests do not prove them.

## Reproduce the production driver integration

Generate the fixture with `LinxDisplaySmokeTests --pico-board-data-only --pico-model-fixture /path/model.json`. Then run `Tools/test-pico-board-pty.py` with `--smoke`, `--consumer`, optional `--consumer-asan`, `--fixture`, and an empty `--output` directory. Consumer binaries come from the firmware's production desktop host harness. The script uses a temporary PTY and private synthetic TF directories; it never discovers a physical USB device or mounts user storage.
