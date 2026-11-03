import SwiftUI
import LinxDisplayCore

/// 小米 IoT 中控卡片。第一阶段展示账号与已导入设备；控制项会按设备 MIoT 规格继续接入。
struct ControlCenterXiaomiCard: View {
    @ObservedObject var model: AppModel
    let source: DeviceControlCenterDataSource
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false

    private var devices: [XiaomiDevice] { model.selectedXiaomiDevices }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 360 || geometry.size.height < 320
            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                Button(action: action) {
                    HStack(spacing: 9) {
                        Image(systemName: "m.square.fill").foregroundStyle(Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("小米 IoT").font(.headline).lineLimit(1)
                            Text(model.xiaomiAccount == nil ? "未登录" : "小米云 · 已导入 \(devices.count) 台")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)

                if model.xiaomiAccount == nil {
                    emptyState(compact: compact)
                } else if devices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.xiaomiDevices.isEmpty ? "尚未读取设备" : "尚未选择设备")
                            .font(.headline)
                        Text(model.xiaomiStatus.isEmpty ? "在「小米 IoT」设置中同步并选择设备。" : model.xiaomiStatus)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Button("打开小米设置", action: action).buttonStyle(.bordered)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 130 : 160), spacing: 10)],
                                  alignment: .leading, spacing: 10) {
                            ForEach(devices) { device in
                                deviceTile(device, compact: compact)
                            }
                        }
                    }.scrollIndicators(.automatic)
                }
                HStack {
                    Text(model.xiaomiStatus.isEmpty ? "登录小米账号后导入设备" : model.xiaomiStatus)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("设置", action: action).buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(compact ? 14 : 20)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .controlCenterGlassCard(hovering: hovering)
        }
        .frame(height: height)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("control-center-source-\(source.id)")
    }

    private func emptyState(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Image(systemName: "m.square").font(.system(size: compact ? 24 : 34))
                .foregroundStyle(.secondary)
            Text("登录小米账号").font(compact ? .system(size: 14, weight: .semibold) : .title3.weight(.semibold))
            Text("使用小米账号授权后，从小米云导入灯光、开关、风扇、空调和温湿度传感器。")
                .font(compact ? .system(size: 12) : .subheadline).foregroundStyle(.secondary)
                .lineLimit(compact ? 2 : 3)
            Button("登录小米账号", action: action).buttonStyle(.borderedProminent)
                .controlSize(compact ? .small : .regular)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func deviceTile(_ device: XiaomiDevice, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: device)).font(compact ? .system(size: 15) : .title3)
                    .foregroundStyle(device.online ? Color.orange : Color.secondary)
                Spacer(minLength: 0)
                Circle().fill(device.online ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 6, height: 6)
            }
            Text(device.name).font(compact ? .system(size: 12, weight: .semibold) : .subheadline.weight(.semibold))
                .lineLimit(2)
            Text(device.subtitle.isEmpty ? device.model : device.subtitle)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Text(device.online ? "在线" : "离线")
                .font(.system(size: 10)).foregroundStyle(device.online ? .green : .secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: compact ? 82 : 92, alignment: .topLeading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func icon(for device: XiaomiDevice) -> String {
        switch device.category {
        case "light": return "lightbulb"
        case "fan": return "fan"
        case "air-conditioner", "airconditioner": return "thermostat"
        case "switch", "plug", "outlet": return "powerplug"
        case "temperature-sensor", "humidity-sensor", "environment-sensor": return "thermometer.medium"
        default: return "square.grid.2x2"
        }
    }
}
