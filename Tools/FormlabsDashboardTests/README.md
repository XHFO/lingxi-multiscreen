# Formlabs Dashboard local tests

Run `bash Tools/FormlabsDashboardTests/run.sh` for the Swift payload projection and the exact injected JavaScript observer under local fetch/XHR fixtures. Add `--webkit` to also exercise a hidden, nonpersistent WKWebView with inline fixture HTML, then mount and detach the actual login view inside a window that is never shown or activated. The latter verifies its initial native first responder and that detaching the view preserves the background session. The WebKit test may require a host environment that permits WebKit's auxiliary processes.

The tests never sign in, use a real printer, read browser cookies, or send a Formlabs request. The hidden WebView replaces fetch before installing the production observer and rejects navigation after loading the inline fixture.

Coverage includes the selected serial, nested account/credential-field exclusion, GUID and device names, null task preservation, bounded fields, exact endpoint/origin filtering, fetch/XHR behavior, authentication failure, malformed/missing printer data, and background callbacks without an NSWindow. Official website compatibility, real login/SSO, restart recovery and long-running cloud updates still require an explicitly authorized live check.

`ViewportTests.swift` constructs the production session without a window or prior login sheet. Its actual document must start at 1024×768 and emit a layout-gated fixture response. A zero-size control reproduces the no-request behavior; this checks the viewport mechanism, not the private implementation of the live Dashboard website.
