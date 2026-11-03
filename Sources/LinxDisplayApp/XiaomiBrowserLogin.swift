import AppKit
import Foundation
import LinxDisplayCore

/// 在真实 Safari 中完成小米授权。WKWebView 里小米的确认按钮不触发导航，
/// 但真实浏览器可以正常授权；软件轮询 Safari 当前标签页地址，拿到回调 code。
enum XiaomiBrowserLogin {
    static func login(region: XiaomiCloudRegion, deviceID: String) async throws -> XiaomiAccount {
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
            guard let current = safariCurrentURL() else { continue }
            if let code = XiaomiOAuthLogin.code(from: current), !code.isEmpty {
                return try await XiaomiOAuthLogin.complete(code: code, region: region, deviceID: deviceID)
            }
        }
        throw XiaomiCloudError.server("Safari 登录超时。请确认已允许多屏灵犀控制 Safari。")
    }

    /// 读取 Safari 最前面窗口当前标签页的地址。
    static func safariCurrentURL() -> URL? {
        let script = """
        tell application "Safari"
          if (count of windows) > 0 then
            return URL of current tab of front window
          end if
        end tell
        return ""
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
        let text = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: text)
    }
}
