import SwiftUI
import WebKit

/// 在应用内打开小米 OAuth 登录页。导航到 accepted 回调地址时直接截获 code，
/// 不真正访问 homeassistant.local，因此不需要 Home Assistant 或复制粘贴。
struct XiaomiLoginWebView: NSViewRepresentable {
    let url: URL
    let redirectPrefix: String
    let onCode: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: XiaomiLoginWebView
        init(_ parent: XiaomiLoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let target = navigationAction.request.url,
               target.absoluteString.hasPrefix(parent.redirectPrefix) {
                decisionHandler(.cancel)
                if let code = XiaomiOAuthLogin.code(from: target), !code.isEmpty {
                    parent.onCode(code)
                } else {
                    parent.onCancel()
                }
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // 登录页资源偶发失败时保留窗口，让用户重新点登录；只有回调失败才关闭。
        }
    }
}

struct XiaomiLoginSheet: View {
    let url: URL
    let onCode: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("登录小米账号", systemImage: "m.square.fill").font(.headline)
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            XiaomiLoginWebView(url: url,
                               redirectPrefix: XiaomiOAuthLogin.redirectURL,
                               onCode: onCode, onCancel: onCancel)
            Divider()
            Text("登录完成后窗口会自动关闭；授权信息只保存在本机加密凭据中。")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 560, height: 720)
    }
}
