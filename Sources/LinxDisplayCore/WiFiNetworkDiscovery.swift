import Foundation
import CoreWLAN

public struct ProvisioningWiFiNetwork: Identifiable, Equatable, Sendable {
    public var ssid: String
    public var signal: Int
    public var isOpen: Bool
    public var id: String { ssid }
    public init(ssid: String, signal: Int, isOpen: Bool) {
        self.ssid = ssid; self.signal = signal; self.isOpen = isOpen
    }
}

public enum WiFiNetworkDiscoveryError: Error, LocalizedError {
    case unavailable, disabled, noVisibleNetworks, scanFailed
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "没有可扫描的 Wi-Fi 网卡，可手动填写 SSID。"
        case .disabled: return "Mac 的 Wi-Fi 已关闭。可在系统菜单栏开启 Wi-Fi，或手动填写 SSID。"
        case .noVisibleNetworks: return "未找到可见的 2.4 GHz 网络。请检查路由器频段和系统设置 → 隐私与安全性 → 定位服务中的多屏灵犀权限，或手动填写 SSID。"
        case .scanFailed: return "Wi-Fi 扫描未完成。请检查系统设置 → 隐私与安全性 → 定位服务中的多屏灵犀权限，或手动填写 SSID。"
        }
    }
}

public enum WiFiNetworkDiscovery {
    /// Called only following an explicit user action and location authorization.
    /// CoreWLAN's blocking radio scan never runs on the main/UI thread.
    public static func scan2GHz() async throws -> [ProvisioningWiFiNetwork] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let interface = CWWiFiClient.shared().interface() else {
                    continuation.resume(throwing: WiFiNetworkDiscoveryError.unavailable); return
                }
                guard interface.powerOn() else {
                    continuation.resume(throwing: WiFiNetworkDiscoveryError.disabled); return
                }
                do {
                    let networks = try interface.scanForNetworks(withSSID: nil)
                        .filter { $0.wlanChannel?.channelBand == .band2GHz }
                        .compactMap { network -> ProvisioningWiFiNetwork? in
                            guard let ssid = network.ssid, !ssid.isEmpty else { return nil }
                            return .init(ssid: ssid, signal: network.rssiValue,
                                         isOpen: network.supportsSecurity(.none))
                        }
                    let visible = normalized(networks)
                    guard !visible.isEmpty else { throw WiFiNetworkDiscoveryError.noVisibleNetworks }
                    continuation.resume(returning: visible)
                } catch let error as WiFiNetworkDiscoveryError {
                    continuation.resume(throwing: error)
                } catch {
                    // CoreWLAN error payloads can contain network names; do not
                    // surface raw errors in the application log or status text.
                    continuation.resume(throwing: WiFiNetworkDiscoveryError.scanFailed)
                }
            }
        }
    }

    /// One result per SSID, preferring its strongest access point. No BSSID or
    /// user's location is retained in the settings or firmware resources.
    public static func normalized(_ networks: [ProvisioningWiFiNetwork]) -> [ProvisioningWiFiNetwork] {
        var selected: [String: ProvisioningWiFiNetwork] = [:]
        for network in networks where !network.ssid.isEmpty {
            if selected[network.ssid] == nil || network.signal > selected[network.ssid]!.signal {
                selected[network.ssid] = network
            }
        }
        return selected.values.sorted {
            $0.signal == $1.signal ? $0.ssid.localizedStandardCompare($1.ssid) == .orderedAscending
                : $0.signal > $1.signal
        }
    }
}
