import SwiftUI
import WebKit

/// 登录 DeepSeek 平台后从 localStorage 读取 userToken，避免用户手动翻开发者工具。
struct DeepSeekTokenWebView: NSViewRepresentable {
    let onToken: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        context.coordinator.webView = webView
        webView.load(URLRequest(url: URL(string: "https://platform.deepseek.com/usage")!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: DeepSeekTokenWebView
        weak var webView: WKWebView?
        private var timer: Timer?
        private var finished = false

        init(_ parent: DeepSeekTokenWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            startPolling()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onError("页面加载失败：\(error.localizedDescription)")
        }

        private func startPolling() {
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.readToken()
            }
        }

        private func readToken() {
            guard !finished, let webView else { return }
            let js = """
            (function(){
              var keys = Object.keys(localStorage);
              var token = localStorage.getItem('userToken') || localStorage.getItem('token');
              return JSON.stringify({token: token || '', keys: keys});
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, !self.finished else { return }
                guard let text = result as? String,
                      let data = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = object["token"] as? String,
                      !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self.finished = true
                self.timer?.invalidate(); self.timer = nil
                self.parent.onToken(token)
            }
        }

        deinit { timer?.invalidate() }
    }
}

struct DeepSeekLoginSheet: View {
    let onToken: (String) -> Void
    let onCancel: () -> Void
    @State private var message = "请在下方登录 DeepSeek 平台；登录后会自动读取用量令牌。"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("登录 DeepSeek 平台", systemImage: "brain.head.profile").font(.headline)
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            DeepSeekTokenWebView(onToken: onToken,
                                 onError: { message = $0 })
            Divider()
            Text(message).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .frame(width: 560, height: 720)
    }
}
