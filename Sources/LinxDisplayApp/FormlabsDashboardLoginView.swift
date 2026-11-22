import SwiftUI
import WebKit

struct FormlabsDashboardLoginView: View {
    @ObservedObject var session: FormlabsDashboardSession
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("连接 Formlabs Dashboard", systemImage: "printer").font(.headline)
                Spacer()
                Button("完成", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(16)
            Text("请在 Formlabs 官方网页中登录。连接仅用于这台打印机；关闭窗口后会继续同步网页返回的状态。")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            DashboardWebView(session: session)
            Divider()
            HStack {
                Text(session.statusText).font(.caption).textSelection(.enabled)
                Spacer()
                Button("重新打开 Dashboard") { session.openDashboard() }
            }.padding(12)
            Text("登录会话由本机 WebKit 独立保存；应用不会导出密码、Cookie 或令牌。电脑退出后，此连接停止更新。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .frame(minWidth: 720, minHeight: 600)
        .onAppear { session.isLoginVisible = true }
        .onDisappear { session.isLoginVisible = false }
    }
}

private struct DashboardWebView: NSViewRepresentable {
    let session: FormlabsDashboardSession

    func makeNSView(context: Context) -> WKWebView {
        // Return the actual WebKit responder to SwiftUI, and restore native
        // keyboard focus once when reattaching this retained background page.
        let webView = session.webView
        webView.removeFromSuperview()
        DispatchQueue.main.async { [weak webView, weak session] in
            guard let webView, let session, session.isLoginVisible,
                  let window = webView.window else { return }
            // One request on attachment only; state updates must not steal focus
            // from a login field, a popup, or the sheet's native buttons.
            window.makeFirstResponder(webView)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: ()) {
        // SwiftUI detaches the view. AppModel retains it and its authorized page;
        // dismissing this sheet must not stop loading or remove the observer.
    }
}
