#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
output="${1:-.build/pico-wallpaper-transactions-20261024}"
mkdir -p "$output"
python3 - "$output" <<'PY'
from pathlib import Path
import hashlib, json, shutil, subprocess, sys
root=Path.cwd(); output=Path(sys.argv[1]).resolve(); products=root/'.build/out/Products/Release'
origins=[root/'Sources/LinxDisplayApp'/p for p in ('AppModel.swift','PicoNativeDesign/PicoNativeLibrary.swift','PicoNativeDesign/PicoPhotoRenderer.swift','ReadPicoLockScreenView.swift','ReadPicoLockScreenDraft.swift','SharedCanvasWallpaperButton.swift')]
test=root/'Tools/PicoNativePreviewTests/WallpaperTransactionChecks.swift'; origins+=[test,Path(__file__) if '__file__' in globals() else test]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
# The AppModel and SwiftUI methods are copied verbatim into isolated state fixtures; actual Core types and IO stay real.
def method(source, prefix):
    start=source.index(prefix); opening=source.index('{',start); depth=1; end=opening+1
    while depth:
        if source[end]=='{': depth+=1
        elif source[end]=='}': depth-=1
        end+=1
    return source[start:end]
model=origins[0].read_text(); lock=origins[3].read_text()
model_method=method(model,'    public func setSharedCanvasImage(').replace('public func','func',1)
capture=method(model,'    private func captureActiveDeviceSnapshot(').replace('private func','func',1)
lock_method=method(lock,'    private func applyComposition(').replace('private func','func',1)
fixture='''import AppKit
import LinxDisplayCore
@MainActor final class WallpaperModelFixture {
    enum CanvasOwner { case keyboard, oracle, excerpt, aiMac }
    let settings = AppSettings()
    let store: SettingsStore
    var canvasBoardAutosaveInFlight = false
    var unguardedChanges = 0
    var previewCalls = 0
    var syncCalls = 0
    init(root: URL) {
        store = SettingsStore(dataDirectory: root)
        settings.oracleCanvasImagePath = "/prior/oracle.png"; settings.oracleCanvasImageName = "旧先知"
        settings.excerptCanvasImagePath = "/prior/excerpt.png"; settings.excerptCanvasImageName = "旧摘录"
        settings.oracleCanvasBoards = [OracleCanvasBoard.capture(from: settings)]
        settings.excerptCanvasBoards = [ExcerptCanvasBoard.capture(from: settings)]
        settings.devices = [ManagedDevice(type: .oracle, name: "先知", settings: DeviceSettings.capture(from: settings, type: .oracle)),
                            ManagedDevice(type: .excerpt, name: "摘录", settings: DeviceSettings.capture(from: settings, type: .excerpt))]
        settings.activeOracleDeviceID = settings.devices[0].id
        settings.activeExcerptDeviceID = settings.devices[1].id
        settings.onChange = { [weak self] in
            guard let self, !self.canvasBoardAutosaveInFlight, !self.settings.deviceSyncInFlight else { return }
            self.unguardedChanges += 1
        }
    }
    func activeDeviceID(for type: DeviceType) -> UUID? { settings.activeDeviceID(for: type) }
    func canvasImagePath(for owner: CanvasOwner) -> String? { owner == .oracle ? settings.oracleCanvasImagePath : settings.excerptCanvasImagePath }
    func canvasImageName(for owner: CanvasOwner) -> String? { owner == .oracle ? settings.oracleCanvasImageName : settings.excerptCanvasImageName }
    func scheduleC6ConfigurationSync() { syncCalls += 1 }
    func refreshDevicePreview(for owner: CanvasOwner) { previewCalls += 1 }
'''+capture+'\n'+model_method+'''
}
@MainActor final class LockCompositionFixture {
    final class Reporter { var errors: [String] = []; func report(_ message: String, error: Bool) { if error { errors.append(message) } } }
    let editor: ReadPicoLockScreenDraft
    let model = Reporter()
    init(editor: ReadPicoLockScreenDraft) { self.editor = editor }
'''+lock_method+'\n}\n'
(output/'ProductionMethods.swift').write_text(fixture)
# Freeze the current actual Core product so a parallel final App build cannot replace linked files mid-test.
stable=output/'CoreProduct'; stable.mkdir(exist_ok=True)
for name in ('LinxDisplayCore.o','C6DisplayRenderer.o'):
    shutil.copy2(products/name, stable/name)
shutil.copytree(products/'LinxDisplayCore.swiftmodule', stable/'LinxDisplayCore.swiftmodule', dirs_exist_ok=True)
tracked=origins[:-1]+[root/'Tools/PicoNativePreviewTests/run-wallpaper-transactions.sh',stable/'LinxDisplayCore.o',stable/'C6DisplayRenderer.o']
before={str(p):sha(p) for p in tracked}
sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
args=[str(root/'scripts/swiftc-sdk-compat'),'-parse-as-library','-swift-version','5','-sdk',sdk,'-target','arm64-apple-macosx26.0','-I',str(stable),'-Xcc',f'-fmodule-map-file={root}/.build/out/Intermediates.noindex/LinxDisplay.build/Release/C6DisplayRenderer-t.build/C6DisplayRenderer.modulemap','-Xcc',f'-I{root}/Sources/C6DisplayRenderer/include',str(origins[1]),str(origins[2]),str(origins[4]),str(output/'ProductionMethods.swift'),str(test),str(stable/'LinxDisplayCore.o'),str(stable/'C6DisplayRenderer.o'),'-o',str(output/'tests')]
(output/'compile-command.json').write_text(json.dumps(args,indent=2)+'\n')
subprocess.run(args,check=True)
result=subprocess.run([str(output/'tests')],capture_output=True,text=True)
(output/'transaction-checks.txt').write_text(result.stdout+result.stderr)
print(result.stdout,end=''); print(result.stderr,end='',file=sys.stderr); result.check_returncode()
assert before=={str(p):sha(p) for p in tracked},'Production source or frozen Core changed during checks'
(output/'source-binding.json').write_text(json.dumps({'result':'PASS','sha256':before,'scope':'Actual library source, actual model setSharedCanvasImage/capture snapshot method bodies and lock applyComposition body, real Core SettingsStore/AppSettings/boards; UI/services are isolated probes. Temporary files only, no live app, settings, network or device.'},indent=2)+'\n')
PY
