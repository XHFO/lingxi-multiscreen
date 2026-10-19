import SwiftUI
import LinxDisplayCore

/// 按需查看，不在启动时弹出，也不自动扫描串口、下载或刷写。
struct C6ProjectGuideEntry: View {
    @State private var showGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("XH Multiscreen 硬件与安装", systemImage: "book.closed")
                HelpIcon(text: "查看支持的开发板、安装步骤及 XHFO.NET 项目资源。外壳模型和官网下载固件入口待补充；软件内置刷机功能仍可使用。")
            }
            HStack(spacing: 12) {
                Button("查看指南") { showGuide = true }
                Link("XHFO.NET", destination: C6ProjectResources.websiteURL)
                    .help("在浏览器打开项目官网；不会自动下载或刷写固件。")
            }
        }
        .sheet(isPresented: $showGuide) { C6ProjectGuideView() }
    }
}

private struct C6ProjectGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(C6ProjectResources.productName) 开始使用").font(.title2.weight(.semibold))
                    Text("\(C6ProjectResources.branchName) · ESP32-C6 彩色小屏幕").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    step("1", title: "准备硬件", symbol: "cpu") {
                        Text(C6ProjectResources.hardwareName).font(.body.weight(.medium))
                        Text("本分支支持 Home Assistant、Bambu Lab、Formlabs 与多屏灵犀软件推送；与 Formlabs 专用分支分别维护。")
                        Text("准备可传输数据的 USB-C 线。请核对完整开发板型号，不要使用 ESP8266、ESP32-S3 或其他 C6 板型的固件。")
                        Text("外壳为可选配件，裸板也可测试。外壳模型文件和装配资料将通过官网提供，下载入口待补充。")
                    }
                    step("2", title: "刷入固件并连接 Wi-Fi", symbol: "cable.connector") {
                        LabeledContent("软件内置固件", value: EmbeddedC6Firmware.version)
                        Text("在设备管理中通过 USB 刷入内置 C6 固件。首次使用可填写 Wi-Fi 名称与密码；更新已有设备时可选择保留原网络配置。")
                        Label("仅支持 2.4 GHz Wi-Fi", systemImage: "wifi")
                            .font(.body.weight(.medium))
                        Text("未写入网络配置时，可连接设备热点并打开 192.168.4.1 完成配网。刷写前核对所选串口；刷写过程中保持供电，不要拔线。")
                    }
                    step("3", title: "添加设备与设置卡片", symbol: "rectangle.stack") {
                        Text("设备联网后，在设备管理中扫描添加，或填写屏幕显示的局域网 IP 地址。电脑与设备应连接到同一局域网。")
                        Text("在这台 C6 的侧边栏设置显示内容，并开启自动同步。支持的本地卡片配置会同步到设备，电脑断开后仍可独立显示；仅由软件提供的功能仍需要电脑在线。")
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            resource("外壳模型与装配资料", url: C6ProjectResources.enclosureURL)
                            resource("官网下载固件", url: C6ProjectResources.firmwareURL)
                            Text("官网资源入口待补充。官网下载固件与软件内置固件是不同入口，请按板型、固件用途与版本说明选择；刷写不会自动进行。")
                                .foregroundStyle(.secondary)
                            Link(destination: C6ProjectResources.websiteURL) {
                                Label("前往 XHFO.NET", systemImage: "arrow.up.right")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    } label: { Text("项目资源") }
                }.padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(width: 560, height: 640)
        .onExitCommand { dismiss() }
    }

    private func step<Content: View>(_ number: String, title: String, symbol: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(number).font(.body.weight(.semibold)).foregroundStyle(.secondary)
                Label(title, systemImage: symbol).font(.headline)
            }
            content().fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resource(_ title: String, url: URL?) -> some View {
        HStack {
            if let url { Link(title, destination: url) }
            else { Text(title) }
            Spacer()
            if url == nil { Text("待补充").foregroundStyle(.secondary) }
        }
    }
}
