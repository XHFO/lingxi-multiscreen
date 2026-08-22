import Foundation

public enum StartupError: Error, LocalizedError {
    case writeFailed(String)
    case removeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let message): return "写入登录启动项失败：\(message)"
        case .removeFailed(let message): return "移除登录启动项失败：\(message)"
        }
    }
}

/// 通过 LaunchAgent 实现“登录时自动启动”。
public final class StartupManager {
    public static let label = "com.linxdisplay.macos"

    public init() {}

    public var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    /// 应用可执行文件路径（.app 内为 Contents/MacOS/LinxDisplay；源码运行时为构建产物）。
    public var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    public func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            let plist: [String: Any] = [
                "Label": Self.label,
                "ProgramArguments": [executablePath],
                "RunAtLoad": true
            ]
            do {
                try FileManager.default.createDirectory(
                    at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(
                    fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: agentURL, options: .atomic)
            } catch {
                throw StartupError.writeFailed(error.localizedDescription)
            }
        } else {
            do {
                if FileManager.default.fileExists(atPath: agentURL.path) {
                    try FileManager.default.removeItem(at: agentURL)
                }
            } catch {
                throw StartupError.removeFailed(error.localizedDescription)
            }
        }
    }
}
