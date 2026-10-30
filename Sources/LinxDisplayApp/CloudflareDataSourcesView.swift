import SwiftUI
import LinxDisplayCore

/// Cloudflare follows the same add, configure, and select pattern as managed devices.
struct CloudflareSourcesManagementView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    private let compact: Bool
    private let showsTitle: Bool
    private let onClose: (() -> Void)?
    @State private var editor: CloudflareSourceEditorRoute?
    @State private var removingSource: CloudflareAnalyticsSource?

    init(model: AppModel, compact: Bool = false, showsTitle: Bool = true, onClose: (() -> Void)? = nil) {
        self.model = model; self.settings = model.settings
        self.compact = compact; self.showsTitle = showsTitle; self.onClose = onClose
    }

    var body: some View {
        Group {
            if compact, let editor {
                editorContent(editor)
            } else {
                management
            }
        }
        .sheet(item: Binding(get: { compact ? nil : editor }, set: { editor = $0 })) { route in
            editorContent(route)
        }
        .alert("移除数据源？", isPresented: Binding(get: { removingSource != nil }, set: { if !$0 { removingSource = nil } })) {
            Button("取消", role: .cancel) { removingSource = nil }
            Button("移除", role: .destructive) {
                guard let source = removingSource else { return }
                if settings.removeCloudflareSource(source.id) {
                    if !settings.cloudflareSources.contains(where: { $0.configuration.credentialID == source.configuration.credentialID }) {
                        CloudflareAnalyticsSecretStore.save("", id: source.configuration.credentialID)
                    }
                    sourceChanged()
                }
                removingSource = nil
            }
        } message: {
            Text("移除「\(removingSource?.name ?? "")」及此 Mac 保存的对应凭据。若它正在使用，画板会改用剩余数据源；没有其他数据源时等待重新添加。")
        }
    }

    @ViewBuilder private func editorContent(_ route: CloudflareSourceEditorRoute) -> some View {
        if let source = route.source {
            VStack(alignment: .leading, spacing: compact ? 16 : 0) {
                if compact {
                    Button { editor = nil } label: { Label("返回数据源", systemImage: "chevron.left") }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                CloudflareSourceSettingsWorkspace(model: model, sourceID: source.id, compact: compact) { editor = nil }
            }
        } else {
            CloudflareSourceEditor(model: model, compact: compact) { editor = nil }
        }
    }

    private var management: some View {
        VStack(alignment: .leading, spacing: compact ? 16 : 22) {
            if let onClose {
                Button { onClose() } label: { Label("返回网站统计", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            if !compact && showsTitle {
                VStack(alignment: .leading, spacing: 6) {
                    Text("数据源").font(.title2.weight(.semibold))
                    Text("添加网站统计，在各设备的画板中共用。")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("添加数据源").font(.headline)
                Button { editor = .add } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "cloud.fill").font(.title2).foregroundStyle(Color.accentColor)
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Cloudflare 网站统计").font(.headline)
                            Text("按引导连接网站，查看请求数、流量与地区排名。")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                    }.padding(12).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                }.buttonStyle(.bordered).accessibilityLabel("添加 Cloudflare 数据源")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("已添加数据源").font(.headline)
                if settings.cloudflareSources.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("尚未添加数据源", systemImage: "externaldrive.badge.plus")
                        Text("像添加设备一样完成连接；API Token 获取和权限设置会逐步说明。")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 260 : 280), spacing: 14)], spacing: 14) {
                        ForEach(settings.cloudflareSources) { source in sourceCard(source) }
                    }
                    Text("当前所有 Cloudflare 卡片共用选中的数据源。切换后，各设备画板会一起更新。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceCard(_ source: CloudflareAnalyticsSource) -> some View {
        let selected = settings.cloudflareSourceID == source.id
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cloud.fill").font(.title3).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name).font(.headline).lineLimit(2)
                    Text(source.configuration.zoneName.isEmpty ? "Cloudflare 网站" : source.configuration.zoneName)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("编辑数据源", systemImage: "pencil") { editor = .edit(source) }
                    Button("移除数据源", systemImage: "trash", role: .destructive) { removingSource = source }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("管理数据源：\(source.name)")
            }
            sourceStatus(source)
            if let snapshot = source.snapshot, snapshot.matches(source.configuration) {
                HStack(spacing: 18) {
                    metric("请求数", CloudflareAnalyticsSnapshot.countText(snapshot.requests))
                    metric("流量", CloudflareAnalyticsSnapshot.bytesText(snapshot.bytes))
                }
            }
            Divider()
            HStack {
                if selected {
                    Label("正在使用", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(Color.accentColor)
                } else {
                    Button("使用此数据源") {
                        if settings.selectCloudflareSource(source.id) {
                            sourceChanged()
                            Task { await model.refreshCloudflare() }
                        }
                    }.buttonStyle(.borderless)
                }
                Spacer(minLength: 4)
                Button("编辑") { editor = .edit(source) }.buttonStyle(.borderless)
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .controlCenterHostedPanelSurface(in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 1.5 : 1))
    }

    @ViewBuilder private func sourceStatus(_ source: CloudflareAnalyticsSource) -> some View {
        if !source.configuration.isValid {
            Label("需要完善站点设置", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else if let snapshot = source.snapshot, snapshot.matches(source.configuration) {
            Label("已连接 · \(snapshot.sampledAt.formatted(date: .abbreviated, time: .shortened)) 更新", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("等待更新统计", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded).weight(.medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceChanged() {
        model.cloudflareCredentialGeneration += 1
        model.cloudflareLastAttempt = nil
        model.cloudflareStatus = ""
        model.invalidateCloudflarePreview()
    }
}

private struct CloudflareSourceEditorRoute: Identifiable {
    let id: UUID
    let source: CloudflareAnalyticsSource?
    static var add: Self { Self(id: UUID(), source: nil) }
    static func edit(_ source: CloudflareAnalyticsSource) -> Self { Self(id: source.id, source: source) }
}

/// A draft stays entirely local until the final action, including credentials.
struct CloudflareSourceEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    private let source: CloudflareAnalyticsSource?
    private let compact: Bool
    private let onClose: () -> Void
    @State private var step = 0
    @State private var name = ""
    @State private var configuration: CloudflareAnalyticsSettings
    @State private var token = ""
    @State private var keepSavedToken: Bool
    @State private var zones: [CloudflareAnalyticsZone] = []
    @State private var manualZone = false
    @State private var busy = false
    @State private var status = ""
    @State private var snapshot: CloudflareAnalyticsSnapshot?
    @State private var credentialRevision = UUID()
    @State private var validationProof: CloudflareSourceValidationProof?
    @State private var useAfterAdding = true
    @State private var requestTask: Task<Void, Never>?
    @State private var requestID = UUID()
    private let steps = ["获取 Token", "连接账户", "选择网站", "完成"]

    init(model: AppModel, source: CloudflareAnalyticsSource? = nil, compact: Bool = false, onClose: @escaping () -> Void) {
        self.model = model; self.settings = model.settings; self.source = source
        self.compact = compact; self.onClose = onClose
        _step = State(initialValue: CloudflareSourceDraftPolicy.initialConnectionStep(editingExistingSource: source != nil))
        _configuration = State(initialValue: source?.configuration ?? CloudflareAnalyticsSettings())
        _name = State(initialValue: source?.name ?? "")
        _keepSavedToken = State(initialValue: source != nil)
        _manualZone = State(initialValue: source != nil)
        _useAfterAdding = State(initialValue: source == nil || model.settings.cloudflareSourceID == source?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(source == nil ? "添加 Cloudflare 数据源" : "编辑 Cloudflare 数据源")
                        .font(compact ? .headline : .title2.weight(.semibold))
                    Spacer(minLength: 8)
                    Button("取消") { cancel() }.keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Text(compact ? "\(index + 1)" : "\(index + 1) \(title)")
                            .font(.caption.weight(index == step ? .semibold : .regular))
                            .foregroundStyle(index == step ? Color.accentColor : Color.secondary)
                            .accessibilityLabel("第 \(index + 1) 步：\(title)\(index == step ? "，当前步骤" : "")")
                    }
                }
            }.padding(compact ? 0 : 22).padding(.bottom, compact ? 12 : 0)
            if !compact { Divider() }
            if compact {
                ScrollView {
                    stepContent.disabled(busy).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 150, maxHeight: .infinity)
            } else {
                ScrollView { stepContent.disabled(busy).padding(24).frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity) }
            }
            if !status.isEmpty {
                Label(status, systemImage: busy ? "clock" : "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, compact ? 0 : 24).padding(.vertical, 10)
                    .accessibilityIdentifier("cloudflareWizardStatus")
            }
            if !compact { Divider() }
            HStack {
                if step > 0 { Button("上一步") { step -= 1; status = "" }.disabled(busy) }
                Spacer()
                if busy { ProgressView().controlSize(.small).accessibilityLabel("正在连接 Cloudflare") }
                Button(primaryTitle) { advance() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canContinue || busy)
            }.padding(compact ? 0 : 20).padding(.top, compact ? 12 : 0)
        }
        .frame(minWidth: compact ? 0 : 620, idealWidth: compact ? nil : 720, minHeight: compact ? 0 : 560, idealHeight: compact ? nil : 660)
        .frame(height: compact ? 390 : nil)
        .textFieldStyle(.roundedBorder)
        .onChange(of: token) { _, _ in invalidateCredentialValidation() }
        .onChange(of: keepSavedToken) { _, _ in invalidateCredentialValidation() }
        .onChange(of: configuration) { _, current in
            if let validationProof, !validationProof.matches(current, credentialRevision: credentialRevision) {
                snapshot = nil; self.validationProof = nil
            }
        }
        .onDisappear { requestTask?.cancel(); requestID = UUID(); token = "" }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case 0:
            CloudflareTokenGuideView(compact: compact)
        case 1:
            credentialStep
        case 2:
            websiteStep
        default:
            finishStep
        }
    }

    private var credentialStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading("连接 Cloudflare", "粘贴刚刚创建的 API Token，下一步会读取你已授权的网站。")
            if source != nil {
                Toggle("继续使用已保存的 Token", isOn: $keepSavedToken)
                if keepSavedToken {
                    Label("出于安全考虑，不显示已保存的 Token。", systemImage: "key.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !keepSavedToken || source == nil {
                VStack(alignment: .leading, spacing: 7) {
                    Text("API Token").font(.headline)
                    SecureField("粘贴 Cloudflare API Token", text: $token)
                        .textContentType(.password).autocorrectionDisabled()
                        .accessibilityIdentifier("cloudflareAPIToken")
                    Text("使用 API Token，不使用账户密码或 Global API Key。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Label("仅在完成添加时加密保存到此 Mac，不会发送到屏幕设备。", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("打开 Cloudflare API Tokens", destination: CloudflareTokenGuideView.tokensURL)
        }
    }

    private var websiteStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading("选择要展示的网站", "验证网站统计后再保存；此时仍可取消，不会留下数据源。")
            if !zones.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("授权网站").font(.headline)
                    Picker("授权网站", selection: Binding(get: { configuration.zoneID }, set: { id in
                        configuration.zoneID = id
                        configuration.zoneName = zones.first(where: { $0.id == id })?.name ?? ""
                        if name.isEmpty { name = configuration.zoneName }
                        snapshot = nil
                    })) {
                        Text("请选择网站").tag("")
                        if !configuration.zoneID.isEmpty, !zones.contains(where: { $0.id == configuration.zoneID }) {
                            Text(configuration.zoneName.isEmpty ? "手动填写的网站" : configuration.zoneName).tag(configuration.zoneID)
                        }
                        ForEach(zones) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !zones.isEmpty { Toggle("手动填写 Zone ID", isOn: $manualZone) }
            if manualZone || zones.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    TextField("Zone ID（32 位）", text: $configuration.zoneID).autocorrectionDisabled()
                    TextField("网站域名，例如 example.com", text: $configuration.zoneName).autocorrectionDisabled()
                    Text("在 Cloudflare 打开目标网站的 Overview（概述），右侧 API 区域可复制 Zone ID。手动填写无需额外的 Zone Read 权限。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField("子域名筛选（可选，例如 www.example.com）", text: $configuration.hostname).autocorrectionDisabled()
            Text("留空时统计整个网站。此处填写域名，不包含 https:// 或路径。")
                .font(.caption).foregroundStyle(.secondary)
            Text("本次验证读取\(configuration.period.title)的统计。时间范围可在添加后调整；是否可用取决于 Cloudflare 套餐和数据集。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeading("网站已连接", "确认名称，完成后即可在画板卡片中使用。")
            Label("统计读取成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            TextField("数据源名称", text: $name)
                .accessibilityIdentifier("cloudflareSourceName")
            LabeledContent("网站", value: configuration.zoneName.isEmpty ? "手动填写的网站" : configuration.zoneName)
            if !configuration.hostname.isEmpty { LabeledContent("筛选域名", value: configuration.hostname) }
            if let snapshot {
                LabeledContent("请求数", value: CloudflareAnalyticsSnapshot.countText(snapshot.requests))
                LabeledContent("响应流量", value: CloudflareAnalyticsSnapshot.bytesText(snapshot.bytes))
            }
            Toggle("在网站统计卡片中使用此数据源", isOn: $useAfterAdding)
                .disabled(settings.cloudflareSources.isEmpty)
            Text("所有 Cloudflare 卡片当前共用一个选中的数据源。请求数包括资源和机器人请求，不等于访客人数。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepHeading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 4)
    }

    private var primaryTitle: String {
        switch step {
        case 0: return "已有 Token，继续"
        case 1: return "读取网站"
        case 2: return "验证并继续"
        default: return source == nil ? "添加数据源" : "保存修改"
        }
    }

    private var canContinue: Bool {
        switch step {
        case 0: return true
        case 1: return CloudflareSourceDraftPolicy.canReadSites(token: token, retainingCredential: source != nil && keepSavedToken)
        case 2: return normalizedConfiguration.isValid
        default: return CloudflareSourceDraftPolicy.canFinish(name: name, configuration: configuration, snapshot: snapshot,
            validation: validationProof, credentialRevision: credentialRevision)
        }
    }

    private var normalizedConfiguration: CloudflareAnalyticsSettings {
        CloudflareSourceDraftPolicy.normalized(configuration)
    }

    private func credential() -> String {
        if source != nil && keepSavedToken {
            return CloudflareAnalyticsSecretStore.read(id: configuration.credentialID)
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func advance() {
        status = ""
        switch step {
        case 0: step = 1
        case 1: loadZones()
        case 2: validateWebsite()
        default: finish()
        }
    }

    private func loadZones() {
        let value = credential()
        guard !value.isEmpty else { status = "未找到已保存的 Token，请关闭保留选项并重新粘贴。"; return }
        let id = UUID(); requestID = id; busy = true
        requestTask?.cancel()
        requestTask = Task { @MainActor in
            defer { if requestID == id { busy = false } }
            do {
                let result = try await CloudflareAnalyticsClient.zones(token: value)
                guard !Task.isCancelled, requestID == id else { return }
                zones = result
                if configuration.zoneID.isEmpty, let first = result.first {
                    configuration.zoneID = first.id; configuration.zoneName = first.name
                    if name.isEmpty { name = first.name }
                }
                manualZone = result.isEmpty
                status = result.isEmpty ? "未读到网站，可手动填写 Zone ID 后验证 Analytics 权限。" : "已读取 \(result.count) 个授权网站。"
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                zones = []; manualZone = true
                status = "未能读取网站列表。可检查 Token 的 Zone · Zone · Read 权限，或手动填写 Zone ID 继续验证。"
            }
            guard !Task.isCancelled, requestID == id else { return }
            step = 2
        }
    }

    private func validateWebsite() {
        let draft = normalizedConfiguration
        guard draft.isValid else { return }
        let value = credential()
        guard !value.isEmpty else { status = "Token 不可用，请返回上一步重新填写。"; return }
        let validatedRevision = credentialRevision
        let id = UUID(); requestID = id; busy = true
        requestTask?.cancel()
        requestTask = Task { @MainActor in
            defer { if requestID == id { busy = false } }
            do {
                let result = try await CloudflareAnalyticsClient.fetch(draft, token: value)
                guard !Task.isCancelled, requestID == id, credentialRevision == validatedRevision,
                      normalizedConfiguration == draft else { return }
                configuration = draft; snapshot = result
                validationProof = CloudflareSourceValidationProof(configuration: draft, credentialRevision: validatedRevision)
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = draft.zoneName.isEmpty ? "Cloudflare 网站" : draft.zoneName
                }
                status = ""; step = 3
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                status = error is CloudflareAnalyticsError ? error.localizedDescription : "连接失败，请检查网络后重试。"
            }
        }
    }

    private func finish() {
        guard let snapshot, canContinue else { return }
        var draft = normalizedConfiguration
        let replacingCredential = source == nil || !keepSavedToken
        if replacingCredential { draft.credentialID = UUID() }
        var sourceID = source?.id
        do {
            try CloudflareSourceCredentialTransaction.commit(
                replacementToken: replacingCredential ? token : nil,
                credentialID: draft.credentialID, previousCredentialID: source?.configuration.credentialID,
                saveSecret: { CloudflareAnalyticsSecretStore.save($0, id: $1) },
                persistSource: {
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let source {
                        return settings.updateCloudflareSource(CloudflareAnalyticsSource(id: source.id, name: title, configuration: draft, snapshot: snapshot))
                    }
                    sourceID = settings.addCloudflareSource(name: title, configuration: draft, snapshot: snapshot, select: useAfterAdding)
                    return true
                },
                credentialIsReferenced: { id in settings.cloudflareSources.contains(where: { $0.configuration.credentialID == id }) }
            )
        } catch {
            status = error.localizedDescription; return
        }
        guard let sourceID else { return }
        if useAfterAdding { _ = settings.selectCloudflareSource(sourceID) }
        model.cloudflareCredentialGeneration += 1
        model.cloudflareLastAttempt = settings.cloudflareSourceID == sourceID ? snapshot.sampledAt : nil
        model.cloudflareStatus = settings.cloudflareSourceID == sourceID ? "已连接 · Cloudflare Analytics" : ""
        model.invalidateCloudflarePreview()
        token = ""; onClose()
    }

    private func cancel() {
        requestTask?.cancel(); requestID = UUID(); token = ""; onClose()
    }

    private func invalidateCredentialValidation() {
        credentialRevision = UUID(); snapshot = nil; validationProof = nil
    }
}

struct CloudflareTokenGuideView: View {
    var compact = false
    static let tokensURL = URL(string: "https://dash.cloudflare.com/profile/api-tokens")!
    // Official template parameters only; the user chooses the authorized websites in Cloudflare.
    static let tokenCreationURL: URL = {
        var components = URLComponents(url: tokensURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "permissionGroupKeys", value: #"[{"key":"analytics","type":"read"},{"key":"zone","type":"read"}]"#),
            URLQueryItem(name: "name", value: "多屏灵犀网站统计")
        ]
        return components.url!
    }()
    static let documentationURL = URL(string: "https://developers.cloudflare.com/analytics/graphql-api/getting-started/authentication/api-token-auth/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("先准备一个只读 API Token").font(.title3.weight(.semibold))
                Text("所需的两项只读权限已预选。打开创建页后，选择要授权的网站即可。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            guideStep(1, "打开预配置创建页", "登录 Cloudflare 后，创建页会自动填好名称与下列只读权限，无需逐项添加。")
            Link("打开预配置创建页", destination: Self.tokenCreationURL).buttonStyle(.bordered)
            VStack(alignment: .leading, spacing: 7) {
                permission("Zone · Analytics · Read", note: "读取请求数、流量和地区统计")
                permission("Zone · Zone · Read", note: "自动读取网站列表；手动填写 Zone ID 时可省略")
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            guideStep(2, "选择授权网站", "在 Zone Resources 中选择 Include → Specific zone 和目标网站。可以重复添加需要展示的网站。")
            guideStep(3, "确认并复制 Token", "点击 Continue to summary 检查两项只读权限及网站范围，再点击 Create Token。复制完整 Token，回到软件继续。")
            Text("若 Cloudflare 未自动填入权限，可按上方两项权限手动创建。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("打开普通 Token 管理页", destination: Self.tokensURL).font(.callout)
            Text("Token 仅显示一次，请妥善保存。不要填写 Global API Key；无需账户密码或写入权限。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("查看 Cloudflare 官方说明", destination: Self.documentationURL).font(.callout)
        }
    }

    private func guideStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26).background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permission(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(.callout, design: .monospaced).weight(.medium))
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}
