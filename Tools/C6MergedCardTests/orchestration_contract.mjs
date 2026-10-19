// These source checks exercise wiring, not physical screen/network acceptance.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const source = readFileSync(new URL('../../Sources/LinxDisplayApp/AppModel.swift', import.meta.url), 'utf8');
let count = 0;
const check = (value, message) => { assert(value, message); count++; };
function section(start, end) {
    const first = source.indexOf(start), last = source.indexOf(end, first + start.length);
    check(first >= 0 && last > first, `Missing section ${start}`);
    return source.slice(first, last);
}
const sync = section('private func scheduleC6ConfigurationSync(', 'private struct C6MediaUpload');
check(!sync.includes('if appliesSelection || retainsMediaOrigin'), 'An unrelated desktop edit cannot authorize old HA pictures');
check(sync.includes('if authorizesMediaOrigin || retainsMediaOrigin'), 'New media authorization is explicit');
check(sync.includes('!attemptCredentials.haToken.isEmpty') && sync.includes('canAuthorizeMediaOrigin(selection: resolved, current: remote)'),
    'New authorization requires actual credential application and the saved endpoint');
check(sync.indexOf('let permittedPrinters') > sync.indexOf('for attempt in 0..<2'), 'Credential allowlist is recomputed after conflict reads');
check(sync.includes('c6LastSyncedSelection = resolvedCheckpoint') && sync.includes('checkpoint.c6LastSyncedInputKey'),
    'Restart checkpoint uses resolved source identities');
check(sync.includes('didUpdateC6DeviceConfiguration(remote') && sync.indexOf('didUpdateC6DeviceConfiguration(remote') < sync.indexOf('if appliesSelection'),
    'Remote catalogue remains accessible even when desktop content synchronization fails');
const renderer = section('private func renderAIMacScreen(', 'private func aiMacScreenTransportPreview(');
check(!renderer.includes('C6LocalRenderer.clock('), 'C6 never approximates firmware clock appearance');
check(renderer.includes('throw C6StandaloneError.unsupported'), 'Generic native render requests fail closed');
const refresh = section('private func refreshAIMacCardDataAndPush(', 'public func aiMacCanvasBoards(');
check(refresh.includes('isCurrentColorScreenPresentation(deviceID, host: presentationHost, config: presentation)'),
    'Second image push rejects an old screen selection/host');
check(refresh.includes('c6CurrentPictureOrigin == pictureOrigin') && refresh.includes('bambuConfig(for: mode) == config'),
    'Second image push rejects a replaced source or printer binding');
const mapping = section('private func allC6Cards(', 'public func c6CardList(');
check(mapping.includes('item.settings.bambuMQTT?.host == match.host'), 'MQTT software slot mapping includes its origin');
console.log(`C6 merged orchestration contracts: ${count} assertions passed (source checks only)`);
