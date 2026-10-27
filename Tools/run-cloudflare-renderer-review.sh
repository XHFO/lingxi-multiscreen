#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="${1:-.build/readpico-cloudflare-renderer-review}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib, json, os, subprocess, sys

root = Path.cwd()
output = Path(sys.argv[1])
renderer = root/'Sources/LinxDisplayCore/ScreenRenderer.swift'
core = root/'Sources/LinxDisplayCore/CloudflareAnalytics.swift'
test = root/'Tools/CloudflareRendererReviewTests.swift'
runner = root/'Tools/run-cloudflare-renderer-review.sh'
map_sources = [root/'Sources/LinxDisplayCore'/name for name in ('CloudflareWorldMap.swift', 'CloudflareWorldDots.swift')]
themes = root/'Sources/LinxDisplayCore/Themes.swift'
origins = [renderer, core, themes, test, runner] + map_sources
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
before = {str(p.relative_to(root)): sha(p) for p in origins}
source = renderer.read_text()

def method(signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[start:end]

signatures = [
    'private static func drawCloudflareAnalytics(',
    'private static func drawCloudflareNativeEInk(',
    'private static func cloudflareTrendPoints(',
    'private static func drawText(',
    'private static func drawGlyphCenteredText(',
    'private static func measureTextWidth(_ text: String, size:',
    'private static func measureTextWidth(_ text: String, fontName:',
    'private static func rect(_ x:',
    'private static func rect(_ skia:',
    'private static func formatDate(',
    'private static func drawQuoteBand(',
    'public static func wrapText(',
]
methods = []
method_hashes = {}
for signature in signatures:
    original = method(signature)
    method_hashes[signature] = hashlib.sha256(original.encode()).hexdigest()
    extracted = original.replace('private static func', 'static func', 1).replace('public static func', 'static func', 1)
    if signature in ('private static func drawText(', 'private static func drawGlyphCenteredText('):
        # Trace the actual rectangle, truncation and CoreText glyph position immediately before drawing.
        needle = '        CTLineDraw(line, ctx)'
        assert extracted.count(needle) == 1
        extracted = extracted.replace(needle,
            '        textTraces.append(TextTrace(text: text, displayed: content, size: size, bounds: bounds, '
            'glyphBounds: CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).offsetBy(dx: x, dy: baselineY), transform: ctx.ctm))\n' + needle)
    if signature == 'private static func cloudflareTrendPoints(':
        opening = extracted.index('{') + 1
        extracted = extracted[:opening] + '\n        chartTraces.append(chart)' + extracted[opening:]
    methods.append(extracted)

preamble = '''import AppKit
import CoreGraphics
import CoreText
import Foundation

// Only the surrounding settings/palette/canvas environment is a fixture.
// The renderer and CoreText helpers below are extracted from current production source.
struct AppSettings {
    var cloudflare = CloudflareAnalyticsSettings()
    var cloudflareSnapshot: CloudflareAnalyticsSnapshot?
}
''' + themes.read_text().split('public enum ScreenThemes', 1)[0] + '''
enum CloudflareRendererReview {
    static var height = 428
    struct TextTrace {
        let text: String
        let displayed: String
        let size: CGFloat
        let bounds: CGRect
        let glyphBounds: CGRect
        let transform: CGAffineTransform
    }
    static var textTraces: [TextTrace] = []
    static var chartTraces: [CGRect] = []
'''
extracted = output/'ProductionCloudflareRenderer.swift'
extracted.write_text(preamble + '\n\n'.join(methods) + '\n}\n')
sdk = os.environ.get('SDKROOT') or subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'], text=True).strip()
compiler = [str(root/'scripts/swiftc-sdk-compat'), '-sdk', sdk, '-target', 'arm64-apple-macosx26.0', '-swift-version', '5', '-parse-as-library']
environment = dict(os.environ, SDKROOT=sdk, TZ='UTC')
subprocess.run(compiler + [str(core)] + [str(p) for p in map_sources] + [str(extracted), str(test), '-o', str(output/'tests')], env=environment, check=True)
result = subprocess.run([str(output/'tests'), str(output)], env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(output/'results.txt').write_text(result.stdout)
print(result.stdout)
after = {str(p.relative_to(root)): sha(p) for p in origins}
binding = {
    'exit_code': result.returncode,
    'sources_unchanged': before == after,
    'source_sha256': before,
    'production_method_sha256': method_hashes,
    'extracted_source_sha256': sha(extracted),
    'sdk': sdk,
    'target': 'arm64-apple-macosx26.0',
    'scope': 'Actual production Cloudflare layout/trend methods and CoreText/rect/date/quote helpers; added trace-only instrumentation. Actual full CloudflareAnalytics.swift compiled, with no network or Keychain calls. Actual production ScreenPalette structure is compiled; settings container, selected monochrome palette values and canvas extent are fixtures. No App, hardware, live credentials or network access.'
}
(output/'source-binding.json').write_text(json.dumps(binding, indent=2) + '\n')
assert before == after, 'Production/test source changed during the run'
raise SystemExit(result.returncode)
PY
