import AppKit
import WebKit
import LinxDisplayCore

/// Load the real device page in the production WKWebView controller. The runner
/// supplies only a disposable, offline loopback session; no cloud login is attempted.
@main struct WebMainFlowTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("RESULT PASS"); exit(0) }
            catch let failure as Failure { print("RESULT FAIL: " + failure.description); exit(1) }
            catch { print("RESULT FAIL: \(type(of: error))"); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
        guard value() else { throw Failure(description: label) }
        print("PASS " + label)
    }
    @MainActor static func js(_ view: WKWebView, _ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { completion in
            view.evaluateJavaScript(script) { result, error in
                if let error { completion.resume(throwing: error) }
                else { completion.resume(returning: result) }
            }
        }
    }
    @MainActor static func wait(_ view: WKWebView, _ condition: String, _ label: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if (try? await js(view, "Boolean(" + condition + ")")) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure(description: label)
    }
    @MainActor static func truth(_ view: WKWebView, _ condition: String, _ label: String) async throws {
        let value = try await js(view, "Boolean(" + condition + ")") as? Bool
        try check(value == true, label)
    }
    @MainActor static func snapshot(_ view: WKWebView, _ name: String, directory: URL) async throws {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            view.takeSnapshot(with: nil) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: Failure(description: "snapshot")) }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "PNG") }
        try png.write(to: directory.appendingPathComponent(name))
    }
    @MainActor static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["READ_PICO_WEB_TEST_URL"], let url = URL(string: address),
              url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              let output = environment["READ_PICO_WEB_TEST_OUTPUT"] else { throw Failure(description: "loopback fixture required") }
        let directory = URL(fileURLWithPath: output)
        let connection = try ReadPicoConnection(address: address, setupKey: "")
        let controller = ReadPicoManagementWebController(connection: connection)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1020, height: 820), configuration: ReadPicoManagementWebController.makeConfiguration())
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.orderFront(nil)
        controller.attach(web)
        defer { controller.invalidate(); window.close() }
        web.load(URLRequest(url: connection.managementURL))
        try await wait(web, "typeof state==='object' && state.connected && !$('app').hidden", "real page pairing")
        try check(!web.configuration.websiteDataStore.isPersistent, "real device page uses nonpersistent WebKit storage")
        try await truth(web, "$('auth').hidden && $('deviceState').dataset.kind==='good'", "real page pairs through the device HTTP adapter")
        try await truth(web, "!location.hash && typeof readPicoManagementDepartureState==='function'", "pairing fragment is removed and public departure contract is installed")
        try await truth(web, "$('haWifi').options.length>1 && $('p-0-source') && $('p-1-source') && $('p-2-source')", "remembered Wi-Fi and three independent printer slots render")
        try await snapshot(web, "web-settings.png", directory: directory)

        _ = try await js(web, "$('haEnabled').checked=false;$('haEnabled').dispatchEvent(new Event('change'));$('haLocal').value='http://readpico-fixture.invalid:8123';$('haLocal').dispatchEvent(new Event('input'));$('haWifi').selectedIndex=1;$('haWifi').dispatchEvent(new Event('change'));$('homeForm').requestSubmit();true")
        try await wait(web, "!state.working && !state.dirty.has('home') && state.home.config.local==='http://readpico-fixture.invalid:8123'", "HA readback")
        try await truth(web, "!state.home.config.enabled && $('homeResult').textContent.includes('已保存')", "HA save is confirmed by real C readback while networking stays disabled")

        _ = try await js(web, "$('nav-control').click();true")
        try await wait(web, "state.tab==='control' && state.entities!==null", "entity page")
        try await truth(web, "!$('view-control').hidden && $('entityKind').options.length===7 && $('previous').disabled", "HA entity page exposes supported kinds and bounded pagination")
        try await snapshot(web, "web-entities.png", directory: directory)
        _ = try await js(web, "$('nav-settings').click();$('p-0-source').value='4';$('p-0-source').dispatchEvent(new Event('change'));true")
        try await truth(web, "$('p-0-client_id') && $('p-0-client_secret') && !$('p-0-username')", "Formlabs renders Client ID and Client Secret separately from Bambu credentials")
        try await truth(web, "$('p-0-client_secret').type==='password'", "Formlabs secret remains masked")
        _ = try await js(web, "$('p-0-form').scrollIntoView({block:'start'});true")
        try await snapshot(web, "web-formlabs.png", directory: directory)

        _ = try await js(web, "state.dirty.delete('p0');$('p-0-source').value='3';$('p-0-source').dispatchEvent(new Event('change'));true")
        try await truth(web, "$('b-account') && $('b-password') && $('p-0-devices') && $('p-0-advanced')", "Bambu cloud presents account login, printer selection and optional advanced Token fields")
        try await truth(web, "$('b-password').type==='password' && !$('p-0-advanced').open && !$('p-0-client_secret')", "Bambu password is masked and unrelated Formlabs fields are removed")
        _ = try await js(web, "$('b-account').value='';$('b-password').value='';$('b-loginButton').click();true")
        try await truth(web, "$('b-loginResult').textContent.includes('请填写') && !state.bambu?.pending", "empty Bambu account validation stays local without a cloud request")
        _ = try await js(web, "$('bambuAccount').scrollIntoView({block:'start'});true")
        try await snapshot(web, "web-bambu.png", directory: directory)
        web.setFrameSize(NSSize(width: 390, height: 844))
        try await Task.sleep(nanoseconds: 200_000_000)
        try await truth(web, "document.documentElement.scrollWidth<=window.innerWidth+1", "the real device page fits a phone-width viewport")
        _ = try await js(web, "$('bambuAccount').scrollIntoView({block:'start'});true")
        try await Task.sleep(nanoseconds: 150_000_000)
        try await snapshot(web, "web-bambu-phone.png", directory: directory)

        let pageState = await withCheckedContinuation { continuation in controller.queryPageState { continuation.resume(returning: $0) } }
        try check(pageState == .known(dirty: true, working: false), "native close guard recognizes the actual page's printer draft")
        _ = try await js(web, "state.dirty.clear();clearTimeout(state.timer);true")
        var closed = false
        controller.close { closed = true }
        let deadline = Date().addingTimeInterval(5)
        while !closed && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(closed && controller.activeAlert == nil, "a clean actual page closes through the production native gate")
    }
}
