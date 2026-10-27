import AppKit
import LinxDisplayCore
import SwiftUI

/// Native software-source card. It observes the same MediaRemote state and artwork
/// as the sidebar; only the three explicit transport buttons control playback.
struct ControlCenterNowPlayingCard: View {
    @ObservedObject var model: AppModel
    let size: DeviceControlCenterCardSize
    let height: CGFloat
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    @State private var showControlStatus = false

    private var info: NowPlayingInfo { model.nowPlaying }
    private var hasMedia: Bool { NowPlayingControlClient.canControl(info) }
    private var title: String { hasMedia ? info.title : String(localized: "未在播放") }
    private var playbackLabel: String {
        !hasMedia ? String(localized: "未在播放")
            : info.isPlaying ? String(localized: "播放中") : String(localized: "已暂停")
    }
    private var compact: Bool { height < 330 }
    private var large: Bool { height >= 500 }
    private var artworkTint: NSColor? { hasMedia ? model.sidebarArtworkGlow?.usingColorSpace(.sRGB) : nil }
    private var primaryInk: Color { artworkTint == nil ? .primary : .white }
    private var secondaryInk: Color {
        artworkTint == nil ? .secondary : .white.opacity(contrast == .increased ? 1 : 0.86)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: compact ? 10 : (large ? 16 : 12)) {
                HStack(spacing: 8) {
                    Button(action: action) {
                        HStack(spacing: 8) {
                            Label("正在播放", systemImage: "music.note")
                                .font(.subheadline.weight(.semibold))
                            Spacer(minLength: 0)
                            Text(info.appName ?? String(localized: "系统媒体"))
                                .font(.caption).foregroundStyle(secondaryInk).lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold)).foregroundStyle(secondaryInk)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "打开正在播放设置"))
                    .accessibilityLabel(String(localized: "打开正在播放设置"))
                    if let status = model.nowPlayingControlStatus {
                        Button { showControlStatus = true } label: {
                            Image(systemName: model.nowPlayingControlFailed ? "exclamationmark.circle" : "info.circle")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help(status)
                        .accessibilityLabel(status)
                        .popover(isPresented: $showControlStatus) {
                            Text(status).font(.callout).padding(18).frame(width: 280)
                        }
                    }
                }
                .frame(height: compact ? 24 : 28)
                if geometry.size.width >= 420 && geometry.size.width > geometry.size.height * 1.4 {
                    HStack(spacing: compact ? 16 : 28) {
                        artwork(side: min(compact ? 138 : 226, max(80, geometry.size.height - 92)))
                        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                            metadata(large: false)
                            progress
                            transportControls
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: .infinity)
                } else if compact {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            artwork(side: geometry.size.width < 280 ? 64 : 80)
                            metadata(large: false)
                        }.frame(maxHeight: .infinity, alignment: .center)
                        progress
                        transportControls
                    }.frame(maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: large ? 20 : 8) {
                        artwork(side: large
                                ? min(280, geometry.size.width - 52, max(100, geometry.size.height - 370))
                                : min(112, geometry.size.width - 44, max(56, geometry.size.height - 250)))
                            .frame(maxWidth: .infinity)
                        metadata(large: large)
                        Spacer(minLength: 0)
                        progress
                        transportControls
                    }.frame(maxHeight: .infinity)
                }
            }
            .padding(compact ? 12 : (large ? 22 : 18))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: height)
        .foregroundStyle(primaryInk)
        .background { artworkBackground }
        .controlCenterGlassCard(hovering: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "正在播放") + ", " + title)
        .accessibilityValue(playbackLabel)
        .accessibilityIdentifier("control-center-now-playing")
    }

    private var transportControls: some View {
        HStack(spacing: compact ? 12 : (large ? 24 : 18)) {
            transportButton(.previousTrack, symbol: "backward.end.fill",
                            label: String(localized: "上一曲"), identifier: "previous")
            transportButton(info.isPlaying ? .pause : .play,
                            symbol: info.isPlaying ? "pause.fill" : "play.fill",
                            label: info.isPlaying ? String(localized: "暂停") : String(localized: "播放"),
                            identifier: "play-pause", prominent: true)
            transportButton(.nextTrack, symbol: "forward.end.fill",
                            label: String(localized: "下一曲"), identifier: "next")
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(_ command: NowPlayingControlCommand, symbol: String,
                                 label: String, identifier: String, prominent: Bool = false) -> some View {
        Button {
            Task { await model.controlNowPlaying(command) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 20 : 17, weight: .semibold))
                .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
                .background(Circle().fill(primaryInk.opacity(prominent ? 0.18 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(ControlCenterMediaTransportStyle())
        .disabled(!NowPlayingControlClient.canControl(info) || model.nowPlayingControlInFlight)
        .opacity(!hasMedia || model.nowPlayingControlInFlight ? 0.45 : 1)
        .help(model.nowPlayingControlInFlight ? String(localized: "正在发送媒体控制") : label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("control-center-media-" + identifier)
    }

    @ViewBuilder private var artworkBackground: some View {
        if let color = artworkTint {
            // Keep the hue sampled from the cover while bounding luminance for white
            // text. Even a white cover yields > 4.5:1 for the secondary text.
            let top = toned(color, scale: 0.36)
            let bottom = toned(color, scale: 0.22)
            LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: color)
                .accessibilityHidden(true)
        }
    }

    private func toned(_ color: NSColor, scale: CGFloat) -> Color {
        Color(red: Double(color.redComponent * scale + 0.025),
              green: Double(color.greenComponent * scale + 0.025),
              blue: Double(color.blueComponent * scale + 0.025))
    }

    private func artwork(side: CGFloat) -> some View {
        ZStack {
            if hasMedia, let glow = model.sidebarArtworkGlow, !reduceTransparency, contrast != .increased {
                Circle().fill(Color(nsColor: glow))
                    .frame(width: side * 1.22, height: side * 1.22)
                    .blur(radius: side * 0.23)
                    .opacity(artworkTint == nil ? 0.24 : 0.58)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: glow)
                    .accessibilityHidden(true)
            }
            ZStack {
                if hasMedia, let artwork = model.sidebarArtwork {
                    Image(nsImage: artwork).resizable().interpolation(.high).scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.secondary.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.27, weight: .light)).foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: large ? 18 : 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: large ? 18 : 14, style: .continuous)
                    .strokeBorder(primaryInk.opacity(0.15), lineWidth: 0.5)
            }
        }.frame(width: side, height: side)
    }

    private func metadata(large: Bool) -> some View {
        VStack(alignment: .leading, spacing: large ? 9 : 6) {
            Text(title).font(large ? .title.weight(.semibold) : .headline)
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hasMedia {
                if !info.artist.isEmpty {
                    Text(info.artist).font(large ? .title3 : .subheadline)
                        .foregroundStyle(secondaryInk).lineLimit(1)
                }
                if large, !info.album.isEmpty {
                    Text(info.album).font(.subheadline).foregroundStyle(secondaryInk).lineLimit(1)
                }
            } else {
                Text("播放后自动显示专辑封面与进度")
                    .font(.subheadline).foregroundStyle(secondaryInk).lineLimit(2)
            }
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = hasMedia ? info.effectiveElapsed(at: context.date) : 0
            let duration = hasMedia && info.duration.isFinite ? max(0, info.duration) : 0
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(primaryInk.opacity(0.18))
                        Capsule().fill(primaryInk.opacity(0.86))
                            .frame(width: geometry.size.width * (duration > 0 ? min(1, max(0, elapsed / duration)) : 0))
                    }
                }
                    .frame(height: 4)
                    .accessibilityHidden(true)
                HStack {
                    Text(hasMedia ? Self.timeText(elapsed) : "—:—")
                    Spacer()
                    Text(playbackLabel)
                    Spacer()
                    Text(duration > 0 ? Self.timeText(duration) : "—:—")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(secondaryInk)
                .lineLimit(1)
            }
        }
    }

    private static func timeText(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "—:—" }
        // Media times are short in practice; bounding before Int conversion also
        // keeps malformed system values from overflowing the presentation layer.
        let seconds = Int(max(0, min(value, 31_536_000)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ControlCenterMediaTransportStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}
