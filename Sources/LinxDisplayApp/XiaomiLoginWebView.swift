import SwiftUI
import WebKit

/// 在应用内打开小米 OAuth 登录页。导航到 accepted 回调地址时直接截获 code，
/// 不真正访问 homeassistant.local，因此不需要 Home Assistant 或复制粘贴。
struct XiaomiLoginWebView: NSViewRepresentable {
    let url: URL
    let redirectPrefix: String
    let onCode: (String) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void
    let onURLChange: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let script = """
        (function(){
          window.open = function(u){ if(u){ window.location.href = u; } return null; };
          document.addEventListener('click', function(e){
            var a = e.target && e.target.closest ? e.target.closest('a') : null;
            if (a && a.target && a.target.toLowerCase() === '_blank') { a.target = '_self'; }
          }, true);
        })();
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: XiaomiLoginWebView
        init(_ parent: XiaomiLoginWebView) { self.parent = parent }

        private func handleRedirect(_ url: URL?) -> Bool {
            guard let url else { return false }
            let isCallbackHost = url.host == "homeassistant.local" && url.port == 8123
            let isConfiguredPrefix = url.absoluteString.hasPrefix(parent.redirectPrefix)
            guard isCallbackHost || isConfiguredPrefix else { return false }
            if let code = XiaomiOAuthLogin.code(from: url), !code.isEmpty {
                parent.onCode(code)
                return true
            }
            parent.onError("已到达小米回调地址，但没有收到 code。请重试登录。")
            return true
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if handleRedirect(navigationAction.request.url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            parent.onURLChange(webView.url)
            if handleRedirect(webView.url) { webView.stopLoading() }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onURLChange(webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onURLChange(webView.url)
            if handleRedirect(webView.url) { webView.stopLoading() }
        }

        /// 小米短信校验/登录成功可能用 target=_blank 或 window.open 打开结果页。
        /// WKWebView 默认没有这个委托时点击会完全无响应，验证码却已被消费。
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let target = navigationAction.request.url, handleRedirect(target) { return nil }
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
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
    @State private var message = ""
    @State private var currentURL: URL?

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
                               onCode: onCode, onCancel: onCancel,
                               onError: { message = $0 },
                               onURLChange: { currentURL = $0 })
            if let currentURL {
                Text(currentURL.absoluteString)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.top, 6)
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.top, 4)
            }
            HStack {
                Button("我已完成授权") {
                    if let currentURL, let code = XiaomiOAuthLogin.code(from: currentURL) {
                        onCode(code)
                    } else {
                        message = "当前页面还没有回调 code，请先完成小米授权。"
                    }
                }
                .disabled(currentURL == nil)
                Spacer()
            }.padding(.horizontal, 12).padding(.top, 6)
            Divider()
            Text("登录完成后窗口会自动关闭；授权信息只保存在本机加密凭据中。")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 560, height: 720)
    }
}
