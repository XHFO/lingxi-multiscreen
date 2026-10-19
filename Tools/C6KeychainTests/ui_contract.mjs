import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import '../C6MergedCardTests/ui_contract.mjs';

// Source-structure guards, not a substitute for a running SwiftUI layout check.
const root = fileURLToPath(new URL('../../', import.meta.url));
const view = readFileSync(root + 'Sources/LinxDisplayApp/C6StandaloneView.swift', 'utf8');
const device = readFileSync(root + 'Sources/LinxDisplayApp/C6DeviceView.swift', 'utf8');
const appModel = readFileSync(root + 'Sources/LinxDisplayApp/AppModel.swift', 'utf8');
const management = readFileSync(root + 'Sources/LinxDisplayApp/Views.swift', 'utf8');
const flasher = readFileSync(root + 'Sources/LinxDisplayCore/ESP8266FirmwareFlasher.swift', 'utf8');
let checks = 0;
function check(value, message) { checks++; assert.ok(value, message); }
check((view.match(/GroupBox\(/g) ?? []).length === 1 && view.includes('GroupBox("C6 局域网固件更新")'), 'only management firmware actions use a GroupBox; configuration retains native Sections');
check(view.includes('pairingOnly: Bool = false') && view.includes('if pairingOnly {'), 'device management can request only pairing fields');
const pairing = view.slice(view.indexOf('if pairingOnly {'), view.indexOf('        Section {'));
check(pairing.includes('pairingFields') && !pairing.includes('Section('), 'management content has no nested Section');
check(pairing.includes('if allowsFirmwareUpdate {') && pairing.includes('Button("OTA 更新内置固件")'), 'OTA belongs to explicitly enabled added-device management');
check(!view.slice(view.indexOf('        Section {'), view.indexOf('private var authorizationStatus')).includes('Button("OTA'), 'offline function page no longer offers OTA');
check(view.includes('allowsFirmwareUpdate: Bool = false'), 'maintenance is opt-in, not enabled on other pages');
check(management.includes('allowsFirmwareUpdate: addingDeviceID != device.id'), 'new device setup does not show added-device OTA');
const ota = view.slice(view.indexOf('private func updateOTA()'));
check(ota.includes('guard pairingOnly, allowsFirmwareUpdate, !busy, !effectiveToken.isEmpty'), 'OTA cannot bypass placement, authorization or busy guards');
check(ota.includes('isCurrentTarget(host)') && (ota.match(/isCurrentTarget\(targetHost\)/g) ?? []).length >= 4, 'OTA remains guarded against removed, disabled or changed targets');
check(ota.includes('EmbeddedC6Firmware.resource(ota: true)') && ota.includes('nextBootID != bootID'), 'OTA validates embedded image and confirms restart');
check(view.includes('managedDeviceName') && view.includes('至 \\(EmbeddedC6Firmware.version)'), 'confirmation identifies user-named device, address and version');
check(device.includes('@State private var networkMode: C6FlashNetworkMode = .preserve'), 'USB defaults to preserving network');
check(device.includes('guard networkMode == .replace else { return nil }'), 'preserve skips all Wi-Fi input requirements');
check(device.includes('makeImage(networkMode: networkMode,'), 'USB uses the tested network-mode production path');
check(device.includes('if mode == .preserve {\n                wifiPassword = ""'), 'switching back to preserve clears unsubmitted password');
check(!device.includes('.task { networkScanner.requestScan() }'), 'preserve does not automatically scan or request network/location permissions');
const esp32 = flasher.slice(flasher.indexOf('private func flashESP32('));
check(esp32.includes('C6WiFiProvisioning.flashRegions(from: firmware, image: wifiProvisioningImage)') && !esp32.includes('erase_flash'), 'actual C6 USB path uses protected segmented plan without full erase');
check(!view.includes('已配对 · 自动同步'), 'authorization state never claims automatic sync is enabled');
check(view.includes('c6SessionOnlyAuthorizationIDs.contains(deviceID)'), 'valid temporary PIN authorization is visibly distinguished');
check(view.includes('private var effectiveToken: String { sessionToken }'), 'actions use the cached token, not repeated Keychain reads');
check(view.includes('c6SessionAuthorization(deviceID: id)'), 'page switches preserve the live authorized session');
check(view.includes('client.connectLAN()') && !view.includes('SecureField("4 位配对 PIN"') && !view.includes('读取已有钥匙串授权'), 'LAN connects without PIN or system authorization');
check(view.includes('guard !authorizationReadFinished else { return }'), 'entry read is bounded to once per page identity');
check(view.includes('private var authorizationStatus: some View'), 'side effects belong to one row, not every Section');
check(view.includes('localOptions.disabled(true)'), 'auto-sync prevents editing fields that would be overwritten');
const own = view.slice(view.indexOf('private func saveDeviceOwnedOptions('), view.indexOf('private func readHealth('));
check(own.includes('for attempt in 0..<2') && own.includes('var latest = try await client.read'), 'owned controls rebase latest revision with one conflict retry');
const ownedFields = ['enabled', 'localFirst', 'diagnostics', 'flipAnimation', 'clockStyle', 'rotation', 'cardMask',
  'language', 'digitStyle', 'sleepMode', 'idleSleepMinutes', 'sleepStartMinute', 'sleepEndMinute', 'keepPrintingAwake'];
for (const field of ownedFields) {
  check(own.includes(`latest.${field} = request.${field}`), 'expected device-owned field: ' + field);
}
check((own.match(/latest\.[a-zA-Z]+ = request\./g) ?? []).length === ownedFields.length && own.includes('option.rotate') && own.includes('option.cardStyle'), 'owned save preserves content/color/credentials and per-printer rotation/style');
check(own.includes('credentials: C6Credentials()'), 'owned save does not replay stale server credentials');
check(!device.includes('Section("首次配对与设备优先级")'), 'native Sections are not embedded as one Form row');
check(device.includes('.frame(width: 300)') && device.includes('.frame(width: 240, height: 240)'), 'right preview dimensions are retained');
const selection = appModel.slice(appModel.indexOf('private func c6Selection('), appModel.indexOf('private func c6SyncInput('));
for (const mapping of [
  'p.showImage = f.showImage',
  'p.showNozzle = f.showNozzleTemp && !fields.nozzleTempEntityID.isEmpty',
  'p.showBed = f.showBedTemp && !fields.bedTempEntityID.isEmpty',
  'p.showError = f.showError && !fields.errorEntityID.isEmpty',
]) check(selection.includes(mapping), 'board-only offline selection respects its visible fields: ' + mapping);
console.log(`C6 UI structure: ${checks} source checks passed; visual layout still requires app verification`);
