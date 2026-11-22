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
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let webView = session.webView
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // AppModel retains the WKWebView; detaching it must not stop the session.
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}
