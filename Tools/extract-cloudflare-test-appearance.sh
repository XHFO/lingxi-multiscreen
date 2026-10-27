#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# Keep the focused Cloudflare runners independent of the full AppSettings
# dependency graph while compiling the actual production appearance types.
# Copy complete top-level declarations verbatim; fail if their shape changes.
awk '
BEGIN {
    expected["BackgroundTone"] = 1
    expected["AccentTone"] = 1
    expected["HexColor"] = 1
    expected["AppearanceResolver"] = 1
    print "// Generated verbatim from Sources/LinxDisplayCore/Models.swift."
    print "import Foundation\n"
}
/^public enum (BackgroundTone|AccentTone|HexColor|AppearanceResolver)(:| )/ {
    if (copying) exit 1
    name = $3
    sub(/:.*/, "", name)
    if (!(name in expected) || seen[name]++) exit 1
    copying = 1
}
copying { print }
copying && /^}$/ {
    copying = 0
    print ""
}
END {
    if (copying) exit 1
    for (name in expected) if (seen[name] != 1) exit 1
}
' Sources/LinxDisplayCore/Models.swift
