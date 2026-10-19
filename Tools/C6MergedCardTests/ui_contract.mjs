// Source contracts complement compiled policy tests. They do not prove a real
// device has received a card or accepted a configuration change.
import assert from 'node:assert/strict';
import './orchestration_contract.mjs';
import '../C6StandaloneTests/card_option_lifecycle.mjs';
import { readFileSync } from 'node:fs';
const root = new URL('../../', import.meta.url);
const read = name => readFileSync(new URL(name, root), 'utf8');
const views = read('Sources/LinxDisplayApp/Views.swift');
const menu = read('Sources/LinxDisplayApp/LinxDisplayApp.swift');
const local = read('Sources/LinxDisplayApp/C6StandaloneView.swift');
let assertions = 0;
const check = (condition, description) => { assert(condition, description); assertions++; };
const section = (source, start, end) => {
  const first = source.indexOf(start);
  check(first >= 0, `Missing section: ${start}`);
  const last = source.indexOf(end, first + start.length);
  check(last > first, `Missing section endpoint: ${end}`);
  return source.slice(first, last);
};

const cardPage = section(views, 'private var aiMacCardForm:', 'private var aiMacSoftwareCardForm:');
check(cardPage.includes('device.type == .c6Screen') && cardPage.includes('card.nativeCard != nil'),
      'C6 native details have an explicit path, not a software renderer fallback');
check(cardPage.includes('aiMacSoftwareCardForm'), 'ESP8266 software details remain supported');
const managementRoute = section(views, 'private var aiMacCardManagementForm:', 'private var aiMacSoftwareCardManagementForm:');
check(managementRoute.includes('device.type == .c6Screen') && managementRoute.includes('c6CardManagementForm'),
      'C6 card management uses its merged catalogue');
check(managementRoute.includes('aiMacSoftwareCardManagementForm'), 'ESP8266 management remains unchanged');

const manager = section(views, 'private func c6CardManagementForm(', 'private func c6CardManagementRow(');
for (const name of ['c6CardList', 'c6HiddenCardList', 'commitC6CardOrder', 'setC6CardVisible']) {
  check(manager.includes(name), `Merged management uses ${name}`);
}
check(manager.includes('card.sourceTitle'), 'Local and software origins have readable text labels');
check(manager.includes('c6SyncStatuses[deviceID]'), 'Sync feedback belongs to the managed device');
check(manager.includes('.font(.system(size: 13))'), 'Merged card source labels use a legible font');
check(manager.includes('aiMacCardRotationBinding(for: deviceID)'), 'The mixed list retains one per-device rotation switch');

const row = section(views, 'private func c6CardManagementRow(', 'private func c6NativeCardForm(');
check(row.includes('setC6CardRotation') && row.includes('deviceID: deviceID'), 'Rotation changes are device-scoped');
check(row.includes('Toggle("显示\\(card.title)"') && row.includes('Toggle("轮换\\(card.title)"'),
      'Each compact toggle retains its VoiceOver label');
check(row.includes('NSItemProvider(object: card.id as NSString)'), 'Drag identity is a stable merged-card token');
check(!row.includes('mode.rawValue'), 'Native ordering never casts a local card to a software mode');

const native = section(views, 'private func c6NativeCardForm(', 'private func aiMacCardManagementRow(');
check(native.includes('c6SyncedConfigurations[deviceID]?.clockStyle.title'), 'Clock details reflect the device style');
check(native.includes('c6SyncedConfigurations[deviceID]?.digitStyle.title'), 'Clock numerals reflect the device style');
check(native.includes('refreshC6NativeCardPreview(deviceID: deviceID)'), 'Native preview reads the device frame');
check(native.includes('isCurrentC6Card(deviceID: deviceID, card: card)') && native.includes('!Task.isCancelled'),
      'Native preview polling only continues for the current card and view');
check(native.includes('5_000_000_000'), 'Native preview polling is bounded to five seconds');
check(!native.includes('pushAIMacScreen') && !native.includes('renderAIMacScreen'), 'Native clock details never send or fabricate a clock image');

const c6Sidebar = section(views, 'case .c6Screen:\n            return AnyView(deviceInstanceGroup', 'case .awtrix:');
check(c6Sidebar.includes('c6Cards: model.c6CardList(for: device.id)'), 'C6 sidebar uses the same merged list');
const sidebarRow = section(views, 'private func c6CardSidebarRow(', 'private func aiMacCardSidebarRow(');
check(sidebarRow.includes('activateC6Card(card, deviceID: deviceID)'), 'C6 sidebar selection uses native-capable activation');
check(sidebarRow.includes('card.sourceTitle'), 'Sidebar accessibility includes the content source');

const menuCards = section(menu, 'case .aiMacScreen, .c6Screen:', 'case .awtrix:');
check(menuCards.includes('device.type == .c6Screen') && menuCards.includes('c6CardList(for: device.id)'),
      'C6 menu uses the same merged list');
check(menuCards.includes('aiMacCardList(for: device.id)'), 'Legacy AI Mac menu remains supported');
check(menuCards.includes('.c6Local(device.id, card.id)'), 'Native menu preview uses stable local identity');
check(menuCards.includes('card.sourceTitle'), 'Menu entries visibly distinguish local and software sources');
const menuAction = section(menu, 'private func switchC6Card(', 'private func switchAIMacCard(');
check(menuAction.includes('$0.id == token') && menuAction.includes('activateC6Card(card, deviceID: deviceID)'),
      'Native menu activation resolves exact identity instead of display names');

const clockOptions = section(local, 'Toggle("翻页钟动态翻页"', 'Toggle("设备状态页"');
check(clockOptions.includes('Picker("桌面时钟样式"') && !clockOptions.includes('if !automaticSync'),
      'Device clock style remains editable while software autosync is on');
const saveOptions = section(local, 'private func saveDeviceOwnedOptions(', 'private func saveSupported(');
check(saveOptions.includes('latest.clockStyle = request.clockStyle'), 'Device-owned save includes clock style');
check(local.includes('电脑断开后的本地轮询'), 'Offline fallback rotation is not confused with the mixed online list');
console.log(`C6 merged card UI contracts: ${assertions} assertions passed (source checks only)`);
