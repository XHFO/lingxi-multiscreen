import SwiftUI
import LinxDisplayCore

struct ControlCenterAIStatusCard: View {
    @ObservedObject var model: AppModel
    let height: CGFloat
    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 360 || geometry.size.height < 320
            let entries = model.aiStatusEntries
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                    Text("AI 状态").font(.headline)
                    Spacer()
                    Text(entries.isEmpty ? "暂无" : "\(entries.count) 个来源")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if entries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("暂无 AI 状态").font(.subheadline.weight(.semibold))
                        Text("Codex 会自动检测运行中与报错；批准状态可由本机 hook 上报。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(entries) { entry in
                                row(entry, compact: compact)
                            }
                        }
                    }
                }
                Text("hook: POST 127.0.0.1:8765/ai-status")
                    .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(compact ? 14 : 18)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .controlCenterGlassCard(hovering: hovering)
        }
        .frame(height: height)
        .onHover { hovering = $0 }
        .task { model.startAIStatusMonitoring() }
        .accessibilityIdentifier("control-center-source-ai-status")
    }

    private func row(_ entry: AIStatusEntry, compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.state.symbol)
                .foregroundStyle(color(entry.state))
                .font(compact ? .system(size: 15) : .title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.source).font(.subheadline.weight(.semibold))
                    Text(entry.state.title).font(.caption.weight(.medium)).foregroundStyle(color(entry.state))
                    Spacer(minLength: 0)
                    Text(entry.updatedAt, style: .time).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if !entry.task.isEmpty {
                    Text(entry.task).font(.caption).lineLimit(1)
                }
                if !entry.message.isEmpty {
                    Text(entry.message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func color(_ state: AIStatusState) -> Color {
        switch state {
        case .running: return .green
        case .approval: return .orange
        case .error: return .red
        case .completed: return .blue
        case .idle: return .gray
        }
    }
}
