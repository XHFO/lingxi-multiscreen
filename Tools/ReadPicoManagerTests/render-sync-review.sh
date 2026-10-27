#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/pico-sync-review-render}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
fixture="$(mktemp -d -t pico-review-fixture)"
trap 'rm -rf "$fixture"' EXIT
cc -std=c11 Tools/ReadPicoManagerTests/ReadingNotesFixture.c -o "$fixture/fixture"
"$fixture/fixture" "$fixture/card"
python3 - "$output" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
for source, marker, name in [
    ('ReadPicoLocalLibraryView.swift', 'struct ReadPicoLibrarySyncReview: View', 'LibraryReview.swift'),
    ('ReadPicoReadingNotesView.swift', 'private struct ReadPicoReadingNotesSyncSheet: View', 'NotesReview.swift')]:
    text = (Path('Sources/LinxDisplayApp') / source).read_text()
    view = text[text.index(marker):].replace('private struct ', 'struct ', 1)
    (out / name).write_text('import AppKit\nimport SwiftUI\n' + view)
PY
swiftc -parse-as-library -swift-version 5 Sources/LinxDisplayCore/ReadPicoPowerStatus.swift \
    Sources/LinxDisplayCore/ReadPicoManager.swift Sources/LinxDisplayCore/ReadPicoLocalLibrary.swift Sources/LinxDisplayCore/ReadPicoReadingNotes.swift \
    "$output/LibraryReview.swift" "$output/NotesReview.swift" Tools/ReadPicoManagerTests/SyncReviewRender.swift \
    -o "$output/render"
"$output/render" "$output/screens" "$fixture/card"
