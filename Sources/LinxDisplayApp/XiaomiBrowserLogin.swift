import AppKit
import Foundation
import LinxDisplayCore

/// 在真实 Safari 中完成小米授权。WKWebView 里小米的确认按钮不触发导航，
/// 但真实浏览器可以正常授权；软件轮询 Safari 当前标签页地址，拿到回调 code。
enum XiaomiBrowserLogin {
    static func login(region: XiaomiCloudRegion, deviceID: String,
                      onStatus: @escaping (String) -> Void = { _ in }) async throws -> XiaomiAccount {
        guard let authURL = XiaomiOAuthLogin.authorizationURL(region: region, deviceID: deviceID) else {
            throw XiaomiCloudError.invalidURL
        }
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        guard FileManager.default.fileExists(atPath: safari.path) else {
            throw XiaomiCloudError.server("未找到 Safari，请先安装或改用扫码登录。")
        }
        try await NSWorkspace.shared.open([authURL], withApplicationAt: safari,
                                          configuration: NSWorkspace.OpenConfiguration())
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let urls = safariURLs(), !urls.isEmpty else {
                onStatus("等待 Safari 授权页…如果一直没有反应，请在系统设置 → 隐私与安全性 → 自动化中允许控制 Safari。")
                continue
            }
            for current in urls {
                if let code = XiaomiOAuthLogin.code(from: current), !code.isEmpty {
                    onStatus("已读取授权码，正在完成登录…")
                    return try await XiaomiOAuthLogin.complete(code: code, region: region, deviceID: deviceID)
                }
            }
            if let last = urls.first(where: { $0.host == "homeassistant.local" }) ?? urls.first {
                onStatus("Safari 当前地址：\(last.absoluteString)")
            }
        }
        throw XiaomiCloudError.server("Safari 登录超时。请确认已允许多屏灵犀控制 Safari，并在 Safari 中完成确认授权。")
    }

    /// 读取 Safari 所有窗口/标签页地址；授权页可能在新窗口或非当前标签。
    static func safariURLs() -> [URL]? {
        let script = """
        tell application "Safari"
          set output to ""
          repeat with w in windows
            repeat with t in tabs of w
              set output to output & (URL of t) & linefeed
            end repeat
          end repeat
          return output
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").compactMap { URL(string: String($0).trimmingCharacters(in: .whitespaces)) }
    }
}
