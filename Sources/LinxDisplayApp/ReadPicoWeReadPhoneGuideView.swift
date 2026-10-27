import AppKit
import CoreImage.CIFilterBuiltins
import LinxDisplayCore
import SwiftUI

/// A short-lived setup task. The model owns cancellation so a dismissed phone page
/// cannot replace an account after the reader has moved to another task.
@MainActor final class ReadPicoWeReadPhoneGuideModel: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, ready(ReadPicoWeReadPhoneSetupServer.Session), saved, expired, failed(String)
    }
    typealias Start = (@escaping @Sendable (String) async throws -> Void) async throws -> ReadPicoWeReadPhoneSetupServer.Session

    @Published private(set) var phase: Phase
    @Published private(set) var feedback = ""
    private let startServer: Start
    private let stopServer: () -> Void
    private let saveCredential: (String) throws -> Void
    private let authorized: () -> Void
    private var generation: UUID?
    private var startTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?

    init(initialPhase: Phase = .idle, start: Start? = nil, stop: (() -> Void)? = nil,
         save: @escaping (String) throws -> Void = ReadPicoWeReadSecretStore.save,
         onAuthorized: @escaping () -> Void = {}) {
        phase = initialPhase
        if let start, let stop {
            startServer = start; stopServer = stop
        } else {
            let server = ReadPicoWeReadPhoneSetupServer()
            startServer = { handler in try await server.start(onAuthorize: handler) }
            stopServer = { server.stop() }
        }
        saveCredential = save; authorized = onAuthorized
    }

    func start() {
        cancel()
        let id = UUID(); generation = id; phase = .starting; feedback = ""
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await startServer { [weak self] value in
                    guard let owner = self else { throw CancellationError() }
                    try Task.checkCancellation()
                    try await MainActor.run {
                        try Task.checkCancellation()
                        guard owner.generation == id else { throw CancellationError() }
                        guard case .ready(let current) = owner.phase, current.expiresAt > Date() else {
                            throw CancellationError()
                        }
                        do {
                            try owner.saveCredential(value)
                        } catch {
                            owner.feedback = "未能保存授权，请在手机上重试，或使用 Mac 填写。"
                            throw error
                        }
                        owner.expirationTask?.cancel(); owner.expirationTask = nil
                        owner.phase = .saved; owner.feedback = ""
                        owner.authorized()
                        // The server sends its success response before closing the listener.
                    }
                }
                try Task.checkCancellation()
                guard generation == id else { return }
                phase = .ready(session)
                expirationTask = Task { [weak self] in
                    let seconds = max(0, session.expiresAt.timeIntervalSinceNow)
                    do { try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000)) }
                    catch { return }
                    guard let self, self.generation == id else { return }
                    if case .ready = self.phase {
                        self.generation = nil; self.stopServer(); self.phase = .expired
                    }
                }
            } catch {
                guard generation == id else { return }
                generation = nil; stopServer()
                if !(error is CancellationError) { phase = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        generation = nil
        startTask?.cancel(); startTask = nil
        expirationTask?.cancel(); expirationTask = nil
        stopServer()
    }
}

struct ReadPicoWeReadPhoneGuideView: View {
    @StateObject private var guide: ReadPicoWeReadPhoneGuideModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAddress = ""
    @State private var copied = false
    private let startsAutomatically: Bool

    init(model: ReadPicoWeReadPhoneGuideModel, startsAutomatically: Bool = true) {
        _guide = StateObject(wrappedValue: model); self.startsAutomatically = startsAutomatically
        if case .ready(let session) = model.phase { _selectedAddress = State(initialValue: session.urls.first?.absoluteString ?? "") }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "iphone.and.arrow.forward").font(.title2).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("用手机授权微信读书").font(.title2.weight(.semibold))
                    Text("扫码填写 API Key，回到 Mac 选择书籍并同步。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    content
                    if !guide.feedback.isEmpty {
                        Label(guide.feedback, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("密钥仅加密保存在本机，多台 Pico 共用。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button(guide.phase == .saved ? "完成" : "取消") { guide.cancel(); dismiss() }
                    .keyboardShortcut(guide.phase == .saved ? .defaultAction : .cancelAction)
                    .buttonStyle(.bordered)
            }.padding(20)
        }
        .frame(minWidth: 360, idealWidth: 680, maxWidth: 780, minHeight: 500, idealHeight: 650, maxHeight: 860)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if startsAutomatically { guide.start() } }
        .onDisappear { guide.cancel() }
        .onChange(of: selectedAddress) { _, _ in copied = false }
        .onChange(of: guide.phase) { _, phase in
            copied = false
            if case .ready(let session) = phase { selectedAddress = session.urls.first?.absoluteString ?? "" }
        }
    }

    @ViewBuilder private var content: some View {
        switch guide.phase {
        case .idle:
            steps
            Button("生成授权二维码", systemImage: "qrcode") { guide.start() }.buttonStyle(.borderedProminent)
        case .starting:
            HStack(spacing: 12) { ProgressView().controlSize(.small); Text("正在准备局域网授权页…") }
            sameNetwork
        case .ready(let session):
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    qrPanel(session).frame(width: 224)
                    VStack(alignment: .leading, spacing: 20) { sameNetwork; steps }.frame(minWidth: 260, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 24) {
                    qrPanel(session).frame(maxWidth: .infinity)
                    sameNetwork; steps
                }
            }
            connectionOptions(session)
        case .saved:
            VStack(alignment: .leading, spacing: 16) {
                Label("授权已保存，可读取书架", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                Text("手机上的配置已送达这台 Mac。点「完成」后，读取书架、选择书籍，再同步划线与想法。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("整本书的正文不在当前同步范围内。")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
        case .expired:
            unavailable("二维码已过期", detail: "重新生成二维码后，再用手机打开授权页。", symbol: "clock.badge.exclamationmark")
        case .failed(let detail):
            unavailable("暂时无法打开手机授权", detail: detail, symbol: "wifi.exclamationmark")
        }
    }

    private var sameNetwork: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("手机与 Mac 连接同一个网络", systemImage: "wifi").font(.headline)
            Text("Pico 无需联网。请在可信的家庭或办公网络内操作，保持此窗口打开。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 18) {
            step("1", title: "扫码打开配置页", detail: "使用手机相机扫描二维码，在浏览器中打开。")
            step("2", title: "获取并填写 API Key", detail: "按手机页面的引导登录微信读书，获取 wrk- 开头的密钥后粘贴保存。")
            step("3", title: "回到 Mac 同步", detail: "读取书架、勾选书籍，再读取个人划线与想法。")
        }
    }
    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.callout.weight(.semibold)).monospacedDigit()
                .frame(width: 24, height: 24).background(.quaternary, in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
    }

    private func qrPanel(_ session: ReadPicoWeReadPhoneSetupServer.Session) -> some View {
        VStack(spacing: 12) {
            if let url = activeURL(session), let image = Self.qrImage(for: url) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 200, height: 200)
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("微信读书临时授权二维码")
                    .accessibilityHint("也可以使用下面的复制链接或在这台 Mac 打开按钮。")
            } else {
                Label("二维码暂时不可用，请使用下方链接。", systemImage: "qrcode")
                    .frame(width: 200).frame(minHeight: 180).fixedSize(horizontal: false, vertical: true)
            }
            Text("有效至 \(session.expiresAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text("关闭窗口后，链接立即失效。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func connectionOptions(_ session: ReadPicoWeReadPhoneSetupServer.Session) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.urls.count > 1 {
                Picker("连接地址", selection: $selectedAddress) {
                    ForEach(session.urls, id: \.absoluteString) { url in Text(url.host ?? "局域网").tag(url.absoluteString) }
                }.pickerStyle(.menu)
                Text("手机无法打开时，可换一个与手机处于相同网络的地址。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let url = activeURL(session) {
                Text(verbatim: (url.host ?? "局域网") + ":" + String(url.port ?? 80))
                    .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { linkButtons(url) }
                    VStack(alignment: .leading, spacing: 12) { linkButtons(url) }
                }
            }
            Text("此页仅用于向当前 Mac 保存微信读书授权，不会自动下载或同步书籍。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private func linkButtons(_ url: URL) -> some View {
        Button(copied ? "已复制链接" : "复制链接", systemImage: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string); copied = true
        }
        Button("在这台 Mac 打开", systemImage: "safari") { NSWorkspace.shared.open(url) }
    }
    private func activeURL(_ session: ReadPicoWeReadPhoneSetupServer.Session) -> URL? {
        session.urls.first(where: { $0.absoluteString == selectedAddress }) ?? session.urls.first
    }
    private func unavailable(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            sameNetwork
            Button("重新生成二维码", systemImage: "arrow.clockwise") { guide.start() }.buttonStyle(.borderedProminent)
            Text("也可以取消此页，在 Mac 直接填写 API Key。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    static func qrImage(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(url.absoluteString.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let quietExtent = output.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: CIColor.white).cropped(to: quietExtent)
        guard let image = CIContext().createCGImage(output.composited(over: white), from: quietExtent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
