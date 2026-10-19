// Execute the production AppModel queue, clock-style binding and native-option
// save functions with a suspended, in-memory transport. No device/cloud access.
import {readFileSync,mkdtempSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import assert from 'node:assert/strict';
const root=new URL('../../',import.meta.url).pathname;
const source=readFileSync(join(root,'Sources/LinxDisplayApp/AppModel.swift'),'utf8');
const extract=(start,end)=>{const a=source.indexOf(start),b=source.indexOf(end,a+start.length);assert.ok(a>=0&&b>a);return source.slice(a,b);};
const clock=extract('    public func c6ClockStyleBinding(', '    public func didUpdateC6DeviceConfiguration(');
const helpers=extract('    private func invalidateC6CardOptionTasks(', '    /// Patch only local card participation.');
const options=extract('    private func saveC6NativeCardOptions(', '    public func refreshC6NativeCardPreview(');
const fields=['c6CardOptionTasks','c6CardOptionEpochs','c6CardOptionTaskIDs'].map(name=>source.split('\n').find(line=>line.includes('private var '+name+':'))).join('\n');
for(const block of [clock,options]){
 assert.ok(block.indexOf('let host = AIMacScreenSupport.normalizedHost')<block.indexOf('await previous?.value'),'capture target before waiting');
 assert.match(block,/defer \{ self\.finishC6CardOptionTask/);
 assert.match(block,/let saved = try await client\.save[\s\S]*?guard self\.isCurrentC6CardOptionTarget/);
}
assert.match(extract('    public func removeDevice(id:', '    public func'),/invalidateC6CardOptionTasks/);
assert.match(extract('    private func mutateAIMacScreenSettings(', '    public func aiMacScreenHostBinding('),/normalizedHost\(value\.host\) != previousHost[\s\S]*?invalidateC6CardOptionTasks/);
assert.match(extract('    public func prepareForTermination()', '    public func'),/c6CardOptionTasks\.values\.forEach \{ \$0\.cancel\(\) \}/);
assert.match(extract('    private func refreshAIMacCardDataAndPush(', '        let requirements ='),/isCurrentAIMacCard/);
assert.match(source,/if dueDevices\.contains\(where: \{ device in[\s\S]*?if device\.type == \.c6Screen,[\s\S]*?config\.c6NativeCardID != nil[\s\S]*?return false/);
const program=`
import Foundation
enum C6ClockStyle { case flip, rounded }
enum DeviceType { case c6Screen }
struct Binding<T> { let get: () -> T; let set: (T) -> Void }
struct Desired { var host = "192.168.1.10"; var visible = true }
struct Managed { var id: UUID; var type: DeviceType = .c6Screen }
struct Settings { var devices: [Managed] }
struct HA { var enabled = false }
struct Printer { var serial = ""; var enabled = false; var rotate = false }
struct Configuration {
 var clockStyle: C6ClockStyle = .flip; var clock = true; var diagnostics = false
 var weather = false; var enabled = true; var cardMask = 0; var ha = HA(); var printers: [Printer] = []
}
struct Native { var kind: String; var id: String }
struct Card { var nativeCard: Native?; var visible: Bool; var participatesInRotation: Bool }
enum C6MergedCardPolicy {
 static func descriptors(settings: Desired, configuration: Configuration, softwareModes: [Int]) -> [Card] {
  [Card(nativeCard: Native(kind: "clock", id: "clock"), visible: settings.visible, participatesInRotation: settings.visible)]
 }
 static func printerIdentity(_ printer: Printer, configuration: Configuration) -> String { printer.serial }
}
enum AIMacScreenSupport { static func normalizedHost(_ host: String) -> String { host } }
enum C6SecretStore { static func read(deviceID: UUID) -> String { "fixture" } }
struct C6Credentials {}
enum C6StandaloneError: Error { case conflict }
@MainActor final class Transport {
 static var shared = Transport()
 var remote = Configuration(); var writes: [Configuration] = []; var reads = 0
 var hold = false; var suspended: [CheckedContinuation<Void, Never>] = []
 func read() async -> Configuration {
  reads += 1
  if hold { await withCheckedContinuation { suspended.append($0) } }
  return remote
 }
 func resume() { hold = false; let waiting = suspended; suspended = []; waiting.forEach { $0.resume() } }
 func save(_ config: Configuration) -> Configuration { writes.append(config); remote = config; return config }
}
@MainActor struct C6StandaloneClient {
 init(host: String) throws {}
 func read(token: String) async throws -> Configuration { await Transport.shared.read() }
 func save(_ config: Configuration, token: String, credentials: C6Credentials) async throws -> Configuration { Transport.shared.save(config) }
}
@MainActor final class Harness {
 let id = UUID(); var settings: Settings; var desired = Desired()
 var c6PreparingForQuit = false; var c6SyncedConfigurations: [UUID: Configuration] = [:]
 var c6Tokens: [UUID: String] = [:]; var c6SyncStatuses: [UUID: String] = [:]
 var c6OfflineSimulationIDs = Set<UUID>(); var availableAIMacCardModes: [Int] = []
 ${fields}
 init() { settings = Settings(devices: []); settings.devices = [Managed(id: id)] }
 func aiMacScreenSettings(for id: UUID) -> Desired { desired }
 func isCurrentColorScreenTarget(_ id: UUID, host: String) -> Bool { settings.devices.contains { $0.id == id } && desired.host == host && !c6PreparingForQuit }
 func didUpdateC6DeviceConfiguration(_ config: Configuration, deviceID: UUID, host: String) { c6SyncedConfigurations[deviceID] = config }
 func pushAIMacScreen(deviceID: UUID, force: Bool) async {}
 static func sha256(_ bytes: Data) -> String { "unused" }
 ${helpers}
 ${clock}
 ${options}
 func waitForSuspendedRead() async {
  for _ in 0..<10000 { if !Transport.shared.suspended.isEmpty { return }; await Task.yield() }
  preconditionFailure("fixture did not suspend a read")
 }
 func verifyOrderedFieldsAndCleanup() async {
  Transport.shared = Transport()
  c6ClockStyleBinding(for: id).set(.rounded)
  saveC6NativeCardOptions(deviceID: id)
  let tail = c6CardOptionTasks[id]; await tail?.value
  precondition(Transport.shared.writes.count == 2)
  precondition(Transport.shared.writes.allSatisfy { $0.clockStyle == .rounded })
  precondition(Transport.shared.remote.cardMask & 1 != 0)
  precondition(c6CardOptionTasks[id] == nil && c6CardOptionTaskIDs[id] == nil)
 }
 func verifyHostRoundTripRejectsOldQueue() async {
  Transport.shared = Transport(); Transport.shared.hold = true
  c6ClockStyleBinding(for: id).set(.rounded)
  saveC6NativeCardOptions(deviceID: id)
  let oldTail = c6CardOptionTasks[id]
  await waitForSuspendedRead()
  desired.host = "192.168.1.20"; invalidateC6CardOptionTasks(deviceID: id)
  desired.host = "192.168.1.10"; invalidateC6CardOptionTasks(deviceID: id)
  Transport.shared.hold = false
  c6ClockStyleBinding(for: id).set(.flip)
  let freshTail = c6CardOptionTasks[id]; await freshTail?.value
  Transport.shared.resume(); await oldTail?.value
  precondition(Transport.shared.writes.count == 1 && Transport.shared.writes[0].clockStyle == .flip)
  precondition(c6CardOptionTasks[id] == nil && c6CardOptionTaskIDs[id] == nil)
 }
 func verifyDeleteAndQuit() async {
  for removing in [true, false] {
   Transport.shared = Transport(); Transport.shared.hold = true
   settings.devices = [Managed(id: id)]; c6PreparingForQuit = false
   c6ClockStyleBinding(for: id).set(.rounded)
   let tail = c6CardOptionTasks[id]; await waitForSuspendedRead()
   if removing { settings.devices = [] } else { c6PreparingForQuit = true }
   invalidateC6CardOptionTasks(deviceID: id); Transport.shared.resume(); await tail?.value
   precondition(Transport.shared.writes.isEmpty)
   precondition(c6CardOptionTasks[id] == nil && c6CardOptionTaskIDs[id] == nil && c6CardOptionEpochs[id] == nil)
  }
 }
 func run() async {
  await verifyOrderedFieldsAndCleanup(); await verifyHostRoundTripRejectsOldQueue(); await verifyDeleteAndQuit()
 }
}
@main struct Tests {
 @MainActor static func main() async {
  await Harness().run()
  print("C6 production option queues: ordered clock + card edits retained, tail cleanup, old-host round-trip/delete/quit rejection; native sampling and refresh source guards passed")
 }
}
`;
const stage=mkdtempSync('/private/tmp/c6-option-lifecycle.');
const sdk=spawnSync(join(root,'scripts/select-macos-sdk'),[],{encoding:'utf8'});assert.equal(sdk.status,0,sdk.stderr);
const binary=join(stage,'test');
const build=spawnSync('swiftc',['-parse-as-library','-sdk',sdk.stdout.trim(),'-module-cache-path',join(stage,'modules'),'-o',binary,'-'],{input:program,encoding:'utf8'});
assert.equal(build.status,0,build.stderr);
const result=spawnSync(binary,[],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);console.log(result.stdout.trim());
