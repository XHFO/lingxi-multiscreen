import AppKit
import WebKit
import LinxDisplayCore

// Compiles the actual production WebController and parent DraftGuard; no device or server is used.
@main struct WebExitTests {
 @MainActor static func main() {
  setbuf(stdout, nil)
  _ = NSApplication.shared
  NSApp.setActivationPolicy(.accessory)
  Task { @MainActor in
   do { try await run(); print("RESULT PASS"); exit(0) }
   catch { print("RESULT FAIL: \(error)"); exit(1) }
  }
  NSApp.run()
 }
 struct Failure: Error, CustomStringConvertible { let description: String }
 @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw Failure(description: message) }; print("PASS \(message)")
 }
 @MainActor static func wait(_ predicate: () -> Bool, _ label: String, seconds: Double = 8) async throws {
  let end = Date().addingTimeInterval(seconds)
  while !predicate() { guard Date() < end else { throw Failure(description: "timeout: " + label) }; try await Task.sleep(nanoseconds: 10_000_000) }
 }
 // These deliberate callback tests verify WebKit completion handlers run exactly once.
 @MainActor static func startJS(_ view: WKWebView, _ script: String, completion: @escaping (Any?, Error?) -> Void) {
  view.evaluateJavaScript(script) { value, error in completion(value, error) }
 }
 @MainActor static func js(_ view: WKWebView, _ script: String) async throws -> Any? {
  try await withCheckedThrowingContinuation { continuation in
   view.evaluateJavaScript(script) { value, error in
    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
   }
  }
 }
 @MainActor static func state(_ controller: ReadPicoManagementWebController) async -> ReadPicoManagementWebController.PageState {
  await withCheckedContinuation { continuation in controller.queryPageState { continuation.resume(returning: $0) } }
 }
 @MainActor static func fixture() async throws -> (NSWindow, WKWebView, ReadPicoManagementWebController) {
  let connection = try ReadPicoConnection(address: "http://pico.fixture", setupKey: String(repeating: "a", count: 32))
  let controller = ReadPicoManagementWebController(connection: connection)
  let config = ReadPicoManagementWebController.makeConfiguration()
  let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 640), configuration: config)
  let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = view; window.orderFront(nil)
  controller.attach(view)
  view.loadHTMLString("<!doctype html><html><body><input id='field'><script>const nativeGuardSeenAtStart=window.__readPicoNativeDepartureGuard===true;const state={dirty:new Set(),working:false,pending:new Set(),bambu:null}; const credentials='NEVER-RETURN-THIS-PRIVATE-VALUE';</script></body></html>", baseURL: connection.managementURL)
  try await wait({ !controller.loading }, "fixture load")
  return (window, view, controller)
 }
 @MainActor static func click(_ controller: ReadPicoManagementWebController, _ index: Int) async throws {
  try await wait({ controller.activeAlert != nil }, "native alert")
  let alert = controller.activeAlert!
  try check(alert.buttons.indices.contains(index), "native alert has requested button")
  alert.buttons[index].performClick(nil)
  try await wait({ controller.activeAlert == nil }, "native alert closes")
 }
 @MainActor static func run() async throws {
  let (window, web, controller) = try await fixture()
  try check(web.configuration.websiteDataStore.isPersistent == false, "management web storage is nonpersistent")
  let guardScripts = web.configuration.userContentController.userScripts
  try check(guardScripts.count == 1 && guardScripts[0].injectionTime == .atDocumentStart && guardScripts[0].isForMainFrameOnly, "host marker is injected at document start for the main frame only")
  let earlyMarker = try await js(web, "nativeGuardSeenAtStart") as? Bool
  try check(earlyMarker == true, "page sees host ownership before its own script starts")
  let immutableMarker = try await js(web, "(() => {const d=Object.getOwnPropertyDescriptor(window,'__readPicoNativeDepartureGuard');window.__readPicoNativeDepartureGuard=false;return d.value===true && d.writable===false && d.configurable===false && window.__readPicoNativeDepartureGuard===true;})()") as? Bool
  try check(immutableMarker == true, "host marker cannot be reassigned or removed")
  try check(web.uiDelegate === controller && web.navigationDelegate === controller, "WKUIDelegate and navigation delegate are installed")
  let initial = await state(controller)
  try check(initial == .known(dirty: false, working: false), "clean query returns two false booleans")
  let raw = try await js(web, ReadPicoManagementWebController.departureQuery) as? [String: Any]
  try check(Set(raw?.keys.map { $0 } ?? []) == ["dirty", "working"], "query returns only dirty and working keys")
  try check(!(String(describing: raw).contains("NEVER-RETURN")), "query does not return fixture credentials")

  // A new page's public contract takes priority; old pages retain the legacy path.
  _ = try await js(web, "state.dirty.add('legacy-only');window.readPicoManagementDepartureState=()=>({dirty:false,working:true});true")
  let publicResult = await state(controller)
  try check(publicResult == .known(dirty: false, working: true), "public contract takes priority over legacy internals")
  let invalidContracts = [
   ("null", "non-function public contract"),
   ("undefined", "present but undefined public contract"),
   ("()=>{throw new Error('fixture query failed')}", "throwing public contract"),
   ("async()=>({dirty:false,working:false})", "asynchronous public contract"),
   ("()=>({dirty:false,working:false,secret:credentials})", "public contract with an extra field"),
   ("()=>({dirty:1,working:false})", "non-boolean dirty flag"),
   ("()=>({dirty:false,working:'false'})", "non-boolean working flag"),
   ("()=>({dirty:false})", "incomplete public contract"),
   ("()=>Object.assign([false,false],{dirty:false,working:false})", "array public contract"),
   ("()=>Object.assign(Object.create({then(){}}),{dirty:false,working:false})", "thenable public contract"),
   ("()=>Object.defineProperty({dirty:false,working:false},'hidden',{value:credentials})", "non-enumerable extra public field"),
   ("()=>Object.assign({dirty:false,working:false},{[Symbol('hidden')]:credentials})", "symbol extra public field")
  ]
  for (expression, label) in invalidContracts {
   _ = try await js(web, "window.readPicoManagementDepartureState=" + expression + ";true")
   let result = await state(controller)
   try check(result == .unavailable, label + " is unavailable without legacy fallback")
  }
  _ = try await js(web, "delete window.readPicoManagementDepartureState")
  let legacyResult = await state(controller)
  try check(legacyResult == .known(dirty: true, working: false), "only an absent public contract enables the legacy fallback")
  _ = try await js(web, "state.dirty.clear();state.bambu={phase:2,pending:false}")
  let legacyChallenge = await state(controller)
  try check(legacyChallenge == .known(dirty: false, working: true), "old firmware fallback still protects an unfinished Bambu challenge")
  _ = try await js(web, "state.bambu=null;window.readPicoManagementDepartureState=()=>({dirty:state.dirty.size>0,working:!!(state.working||state.pending.size||state.bambu?.pending||[1,2,3].includes(state.bambu?.phase))});true")

  _ = try await js(web, "state.dirty.add('home')")
  let dirty = await state(controller)
  try check(dirty == .known(dirty: true, working: false), "HA draft is detected")
  let guardObject = ReadPicoDraftGuard(); var dismissed = 0; var globalAllowed = 0
  controller.register(with: guardObject) { dismissed += 1 }
  guardObject.request(title: "Fixture global departure") { globalAllowed += 1 }
  try await click(controller, 0)
  try check(globalAllowed == 0 && dismissed == 0, "cancel does not continue global departure")
  try check(!guardObject.isHandlingDeparture, "child cancellation releases the parent guard")
  guardObject.request(title: "Fixture global departure") { globalAllowed += 1 }
  try await click(controller, 0)
  try check(globalAllowed == 0 && !guardObject.isHandlingDeparture, "a second global close remains usable after cancellation")

  _ = try await js(web, "state.dirty.clear();state.working=true")
  let working = await state(controller)
  try check(working == .known(dirty: false, working: true), "active form request is detected without dirty fields")
  _ = try await js(web, "state.working=false;state.pending.add('light.example')")
  let pending = await state(controller)
  try check(pending == .known(dirty: false, working: true), "pending HA entity action is detected")
  for phase in 1...3 {
   _ = try await js(web, "state.pending.clear();state.bambu={phase:\(phase),pending:false}")
   let result = await state(controller)
   try check(result == .known(dirty: false, working: true), "Bambu phase \(phase) is protected without dirty fields")
  }
  _ = try await js(web, "state.bambu={phase:4,pending:true}")
  let authRequest = await state(controller)
  try check(authRequest == .known(dirty: false, working: true), "pending Bambu request is protected")
  _ = try await js(web, "state.bambu={phase:4,pending:false}")
  let completedAuth = await state(controller)
  try check(completedAuth == .known(dirty: false, working: false), "completed Bambu login does not force a close prompt")
  _ = try await js(web, "state.pending=undefined")
  let unavailable = await state(controller)
  try check(unavailable == .unavailable, "unsupported page state is not mistaken for clean")
  controller.close { dismissed += 1 }
  try await wait({ controller.activeAlert != nil }, "unavailable-state prompt")
  try check(controller.activeAlert?.informativeText.contains("无法确认") == true, "unavailable state has an explicit conservative prompt")
  try await click(controller, 0)
  _ = try await js(web, "state.pending=new Set();state.bambu=null")

  var confirmResult: Bool?; var confirmCallbacks = 0
  startJS(web, "confirm('Clear the fixture configuration?')") { value, error in confirmResult = value as? Bool; confirmCallbacks += 1 }
  try await click(controller, 0)
  try await wait({ confirmCallbacks == 1 }, "confirm true result")
  try check(confirmResult == true, "page confirm accepts through native WKUIDelegate")
  confirmResult = nil; confirmCallbacks = 0
  startJS(web, "confirm('Cancel fixture clear?')") { value, error in confirmResult = value as? Bool; confirmCallbacks += 1 }
  try await click(controller, 1)
  try await wait({ confirmCallbacks == 1 }, "confirm false result")
  try check(confirmResult == false, "page confirm cancellation reaches JavaScript")
  var alertDone = false
  startJS(web, "alert('Fixture notice'); true") { value, error in alertDone = (value as? Bool) == true }
  try await click(controller, 0)
  try await wait({ alertDone }, "alert completion")
  try check(alertDone, "page alert completes through native WKUIDelegate")

  try check(controller.allows(URL(string: "http://pico.fixture/manage?reload=1")!), "same-origin management path is allowed")
  try check(controller.allows(URL(string: "http://pico.fixture:80/")!), "default HTTP port shares origin")
  try check(!controller.allows(URL(string: "https://pico.fixture/manage")!), "different scheme is blocked")
  try check(!controller.allows(URL(string: "http://pico.fixture:81/manage")!), "different port is blocked")
  try check(!controller.allows(URL(string: "http://evil.fixture/manage")!), "different host is blocked")
  try check(!controller.allows(URL(string: "http://pico.fixture/private")!), "unapproved path is blocked")
  _ = try await js(web, "state.dirty.add('p0');location.href='http://pico.fixture/manage?reload=1'")
  try await click(controller, 0)
  let retained = await state(controller)
  try check(retained == .known(dirty: true, working: false), "cancelled same-origin navigation preserves the current draft")

  let replacement = ReadPicoManagementWebController(connection: try ReadPicoConnection(address: "http://pico.fixture", setupKey: String(repeating: "a", count: 32)))
  replacement.register(with: guardObject) {}
  controller.invalidate()
  try check(guardObject.childDeparture != nil, "old web disappearance cannot clear a newer child registration")
  replacement.invalidate()
  try check(guardObject.childDeparture == nil, "own web disappearance clears its registration")
  window.close()

  let (cleanWindow, cleanWeb, cleanController) = try await fixture()
  var cleanDismissed = false
  cleanController.close { cleanDismissed = true }
  try await wait({ cleanDismissed }, "clean close")
  try check(cleanController.activeAlert == nil, "clean page closes without an unnecessary prompt")
  cleanController.invalidate(); cleanWindow.close()
  _ = cleanWeb

  let (dialogWindow, dialogWeb, dialogController) = try await fixture()
  var invalidationCallbacks = 0; var invalidationResult: Bool?
  startJS(dialogWeb, "confirm('Fixture is disappearing')") { value, error in invalidationCallbacks += 1; invalidationResult = value as? Bool }
  try await wait({ dialogController.activeAlert != nil }, "outstanding confirm before invalidation")
  dialogController.invalidate()
  try await wait({ invalidationCallbacks == 1 }, "invalidation confirm completion")
  try await Task.sleep(nanoseconds: 100_000_000)
  try check(invalidationCallbacks == 1 && invalidationResult == false, "dismantled web resolves outstanding confirm once and safely cancels")
  dialogWindow.close()
 }
}
