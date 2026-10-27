import LinxDisplayCore
import SwiftUI

struct C6StandaloneView: View {
  @State private var host = ""
  @State private var sessionToken = ""
  @State private var config = C6StandaloneConfiguration()
  @State private var capabilities = C6StandaloneCapabilities()
  @State private var credentials = C6Credentials()
  @State private var loadedHost = ""
  @State private var status = "连接同一局域网即可配置，无需 PIN 或钥匙串授权。"
  @State private var feedbackPhase: C6FeedbackPhase = .information
  @State private var busy = false
  @State private var confirmOTA = false
  @State private var monitoring = false
  @State private var healthText = ""
  @State private var savedAuthorization = false
  @State private var authorizationReadFinished = false
  @State private var authorizationWasStored = false
  let deviceID: UUID?
  let model: AppModel?
  let pairingOnly: Bool
  let allowsFirmwareUpdate: Bool
  var onAuthorized: ((String) -> Void)?
  init(
    initialHost: String = "", deviceID: UUID? = nil, model: AppModel? = nil,
    pairingOnly: Bool = false,
    allowsFirmwareUpdate: Bool = false,
    onAuthorized: ((String) -> Void)? = nil
  ) {
    _host = State(initialValue: initialHost)
    self.deviceID = deviceID
    self.model = model
    self.pairingOnly = pairingOnly
    self.allowsFirmwareUpdate = allowsFirmwareUpdate
    self.onAuthorized = onAuthorized
  }
  /// Actions reuse the installation-local session; no system credential UI.
  private var effectiveToken: String { sessionToken }
  private var automaticSync: Bool {
    guard let model, let deviceID else { return false }
    return model.settings.devices.first { $0.id == deviceID }?.settings.c6AutomaticSync ?? true
  }
  private var sessionOnlyAuthorization: Bool {
    if let model, let deviceID { return model.c6SessionOnlyAuthorizationIDs.contains(deviceID) }
    return savedAuthorization && !authorizationWasStored
  }
  private func isCurrentTarget(_ targetHost: String) -> Bool {
    guard host == targetHost else { return false }
    guard let model, let deviceID else { return true }
    return model.settings.devices.contains {
      $0.id == deviceID && $0.type == .c6Screen && $0.isEnabled
        && $0.settings.aiMacScreen?.host == targetHost
    }
  }
  @ViewBuilder private var pairingFields: some View {
    if model != nil && deviceID != nil {
      LabeledContent("设备 IP 地址", value: host.isEmpty ? "尚未设置" : host)
        .help("在设备管理中修改这台设备的网络地址，连接与自动同步始终对应同一台设备。")
    } else {
      TextField("设备 IP 地址", text: $host)
    }
    if !savedAuthorization {
      Button(automaticSync ? "连接并同步" : "连接设备") { pair() }
        .disabled(busy || host.isEmpty)
        .help("仅在可信的同一局域网使用。设备完成 Wi-Fi 配置并关闭热点后即可直接连接，无需输入 PIN。")
    } else {
      HStack {
        Label(sessionOnlyAuthorization ? "本次会话已连接" : "连接凭据已保存", systemImage: "checkmark.shield")
        Spacer()
        Button("重新连接") {
          savedAuthorization = false
          loadedHost = ""
          sessionToken = ""
          authorizationWasStored = false
          monitoring = false
          status = "正在重新连接局域网设备。"
          pair()
        }
        .disabled(busy)
      }
      Button("读取设备配置") { transfer(save: false) }.disabled(busy || host.isEmpty)
      if sessionOnlyAuthorization {
        Text("连接可正常使用，但本机凭据未保存；下次连接会自动重新获取，无需 PIN。")
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    if busy { ProgressView("正在处理设备请求…").controlSize(.small) }
    authorizationStatus
  }
  var body: some View {
    Group {
      if pairingOnly {
        VStack(alignment: .leading, spacing: 12) {
          pairingFields
          if allowsFirmwareUpdate {
            GroupBox("C6 局域网固件更新") {
              VStack(alignment: .leading, spacing: 12) {
                LabeledContent("内置固件版本", value: EmbeddedC6Firmware.version)
                HStack(spacing: 4) {
                  Button("OTA 更新内置固件") { confirmOTA = true }
                    .disabled(busy || effectiveToken.isEmpty || !isCurrentTarget(host))
                  HelpIcon(text: "更新当前这台已添加设备，无需 USB 或重新填写 Wi-Fi。需要先连接、设备在线且已安装双分区固件。更新保留网络、连接和离线设置，完成后确认重启与版本。首次从旧单分区升级请使用下方 USB 刷写。")
                }
              }.padding(8)
            }
          }
        }
          .textFieldStyle(.roundedBorder)
      } else {
        Section {
          pairingFields
        } header: {
          HStack(spacing: 4) {
            Text("局域网连接")
            HelpIcon(
              text:
                "同一可信局域网内免 PIN 连接。连接凭据由软件内部保存，不调用系统钥匙串。开放配网热点不提供配置授权。固件升级与重置网络仍需确认。"
            )
          }
        }
        if loadedHost == host && !loadedHost.isEmpty {
          Section("设备独立运行") {
            Toggle("电脑离线时独立运行", isOn: $config.enabled)
            Picker("数据源优先级", selection: $config.localFirst) {
              Text("优先多屏灵犀软件").tag(false)
              Text("固件本地卡片优先 · 混合轮转").tag(true)
            }.help("本地优先：固件中对应的天气、Home Assistant 和同一台打印机卡片替代软件卡片，其他卡片继续由电脑推送。电脑在线时，在本设备的卡片管理统一安排顺序和轮转；断开约 30 秒后恢复固件独立轮询，分组与排序可能不同。需要更新内置 C6 固件。")
            DisclosureGroup("时钟、方向与状态（高级）") {
              Toggle("翻页钟动态翻页", isOn: $config.flipAnimation)
                .disabled(config.clockStyle != .flip)
                .help("只在时分数字变化时执行短暂翻页；关闭可减少动态效果。")
              Picker("桌面时钟样式", selection: $config.clockStyle) {
                ForEach(C6ClockStyle.allCases) { style in Text(style.title).tag(style) }
              }
              .help("时钟由设备通过网络校时并在本地实时渲染；电脑只切换卡片和管理样式，不发送时钟图片。样式保存到这台设备，自动同步不会覆盖。")
              Toggle("设备状态页", isOn: $config.diagnostics)
              Picker("屏幕方向", selection: $config.rotation) {
                ForEach([0, 90, 180, 270], id: \.self) { angle in Text("\(angle)°").tag(angle).disabled(!capabilities.rotations.contains(angle)) }
              }.help("只在固件输出到 LCD 时旋转，电脑预览和发送的图片保持正向。90° 档位需要更新内置固件。")
            }
            DisclosureGroup("语言、数字与休眠") {
              Picker("设备界面语言", selection: $config.language) {
                ForEach(C6Language.allCases) { Text($0.title).tag($0) }
              }
              Picker("主数字样式", selection: $config.digitStyle) {
                ForEach(C6DigitStyle.allCases) { Text($0.title).tag($0) }
              }.help("用于翻页钟、天气温度和打印进度的大数字；圆角粗数字时钟保持自己的字形，任务名称不改变。")
              Picker("自动休眠", selection: $config.sleepMode) {
                ForEach(C6SleepMode.allCases) { Text($0.title).tag($0) }
              }
              if config.sleepMode == .idle {
                Stepper("无操作 \(config.idleSleepMinutes) 分钟后休眠", value: $config.idleSleepMinutes, in: 1...120)
              } else if config.sleepMode == .schedule {
                DatePicker("休眠开始", selection: scheduleTime(\.sleepStartMinute), displayedComponents: .hourAndMinute)
                DatePicker("唤醒时间", selection: scheduleTime(\.sleepEndMinute), displayedComponents: .hourAndMinute)
                if config.sleepStartMinute == config.sleepEndMinute {
                  Label("休眠开始与唤醒时间不能相同。", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
              }
              if config.sleepMode != .off {
                Toggle("打印任务进行时保持亮屏", isOn: $config.keepPrintingAwake)
              }
            }.disabled(!capabilities.uiOptions)
            if !capabilities.uiOptions {
              Label("语言、数字、休眠及新卡片样式需要更新内置 C6 固件。", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !config.printers.isEmpty {
              DisclosureGroup("本地打印机卡片样式") {
                ForEach(config.printers.indices, id: \.self) { index in
                  Picker(config.printers[index].name + " · " + config.printers[index].brandName, selection: $config.printers[index].cardStyle) {
                    ForEach(C6PrinterCardStyle.allCases) { Text($0.title).tag($0) }
                  }
                }
              }.disabled(!capabilities.uiOptions)
                .help("超大百分比和超大剩余时间不显示任务缩略图。保存到本设备，不改变其他屏幕的打印机卡片。")
              if config.printers.filter(\.enabled).count >= 2 && capabilities.printerOverview {
                Label("已加入多打印机总览", systemImage: "square.grid.2x2")
                  .foregroundStyle(.secondary)
              }
            }
            DisclosureGroup("电脑断开后的本地轮询") {
              ForEach(Array(["桌面时钟", "设备状态", "天气", "Home Assistant"].enumerated()), id: \.offset) { index, name in
                Toggle(name, isOn: Binding(get: { config.cardMask & (1 << index) != 0 }, set: { value in
                  if value { config.cardMask |= 1 << index } else { config.cardMask &= ~(1 << index) }
                }))
              }
              ForEach(config.printers.indices, id: \.self) { index in
                Toggle(config.printers[index].name, isOn: $config.printers[index].rotate)
              }
            }.help("电脑在线时，在本设备的“卡片管理”统一排列电脑推送和设备本地卡片。这里调整断开电脑后的独立轮询，按固件自身顺序运行；不删除数据源或凭据，尚未配置的卡片不会显示。这里的修改不会撤销电脑端卡片管理已明确选择的显示与轮换设置。")
            Button("保存到设备") { transfer(save: true) }.disabled(busy)
          }.disabled(busy)
          Section {
            if automaticSync {
              LabeledContent("配置方式", value: "跟随电脑端功能页")
              LabeledContent("Home Assistant 实体", value: "在本设备的 Home System 卡片页选择")
              LabeledContent("打印机内容", value: "在打印机卡片与设备管理中设置")
              LabeledContent("天气", value: "在天气卡片页设置城市与更新间隔")
              LabeledContent("亮度与色彩", value: "在本设备的屏幕控制页调整")
              DisclosureGroup("查看设备配置") { localOptions.disabled(true) }
            } else {
              DisclosureGroup("编辑设备独立配置") { localOptions }
              Button("保存独立配置到设备") { transfer(save: true) }
            }
          } header: {
            HStack(spacing: 4) {
              Text("显示内容与数据源")
              HelpIcon(
                text:
                  "自动同步开启时，这些选项由侧边栏的功能页统一管理，避免设备和电脑出现两套互相覆盖的设置。关闭自动同步后才可手工编辑设备独立配置。本地运行、优先级、动态翻页与设备状态页始终由设备保留。"
              )
            }
          }.disabled(busy)
          Section("运行状态与验证") {
            HStack {
              Button("读取运行状态") { readHealth() }.disabled(busy)
              Button(monitoring ? "停止验证" : "持续验证 30 分钟") { monitoring.toggle() }.disabled(busy)
            }
            if !healthText.isEmpty {
              Text(healthText).font(.body.monospacedDigit()).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }
  /// Attach side effects to one stable row, not to a virtual Group of multiple
  /// Sections, so entering the page cannot spawn duplicate authorization reads
  /// or duplicate long-running health monitors.
  private var authorizationStatus: some View {
    C6StatusMessage(text: status, phase: busy ? .working : feedbackPhase)
      .task {
        guard !authorizationReadFinished else { return }
        authorizationReadFinished = true
        loadAuthorization(allowUserInteraction: false)
      }
      .alert("通过局域网更新 C6 固件？", isPresented: $confirmOTA) {
        Button("取消", role: .cancel) {}
        Button("开始 OTA") { updateOTA() }
      } message: {
        Text("将更新“\(managedDeviceName)”（\(host)）至 \(EmbeddedC6Firmware.version)。保留 Wi-Fi、配对与离线设置；设备会重启，期间不要断电。仅支持已安装双分区固件的 C6。")
      }
      .task(id: monitoring) {
        guard monitoring else { return }
        let started = Date()
        let target = host
        let secret = effectiveToken
        var samples = 0
        var failures = 0
        var minimum = Int.max
        while !Task.isCancelled && monitoring && Date().timeIntervalSince(started) < 1800 {
          guard isCurrentTarget(target) else { return }
          do {
            let data = try await C6StandaloneClient(host: target).health(token: secret)
            guard !Task.isCancelled, isCurrentTarget(target) else { return }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            minimum = min(minimum, object["minimum_heap"] as? Int ?? Int.max)
            samples += 1
          } catch { failures += 1 }
          healthText =
            "运行验证：\(samples) 次成功，\(failures) 次失败；最低堆内存 \(minimum == Int.max ? "—" : "\(minimum / 1024) KB")"
          do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
        }
        if !Task.isCancelled {
          monitoring = false
          status = "30 分钟采样完成；仍需在实屏检查画面、翻页与温度。"
          feedbackPhase = failures == 0 ? .success : .warning
        }
      }
  }
  private var managedDeviceName: String {
    model?.settings.devices.first { $0.id == deviceID }?.name ?? C6ProjectResources.productName
  }
  private func pair() {
    busy = true
    status = "正在连接设备并读取配置…"
    let targetHost = host
    Task { @MainActor in
      defer { busy = false }
      do {
        guard isCurrentTarget(targetHost) else { return }
        let client = try C6StandaloneClient(host: targetHost)
        let secret = try await client.connectLAN()
        guard isCurrentTarget(targetHost) else { return }
        let result = try await client.read(token: secret)
        guard isCurrentTarget(targetHost) else { return }
        guard result.schemaVersion == 2 else { throw C6StandaloneError.unsupported }
        let negotiated = (try? await client.capabilities(token: secret)) ?? C6StandaloneCapabilities()
        guard isCurrentTarget(targetHost) else { return }
        config = result
        capabilities = negotiated
        loadedHost = targetHost
        sessionToken = secret
        savedAuthorization = true
        authorizationWasStored = false
        if let onAuthorized {
          // AppModel owns installation-local persistence and the live session.
          onAuthorized(secret)
          authorizationWasStored = !sessionOnlyAuthorization
          status =
            automaticSync
            ? "连接成功，电脑端设置正在同步。"
            : "连接成功，自动同步已关闭。"
        } else if let id = deviceID {
          authorizationWasStored = C6SecretStore.save(secret, deviceID: id)
          status =
            authorizationWasStored
            ? "连接成功，连接凭据已在软件内部保存。"
            : "连接成功，本次会话可用；本机保存失败，下次会自动重新连接。"
        } else {
          status = "连接成功，本次会话可用。"
        }
        feedbackPhase = .success
      } catch {
        guard isCurrentTarget(targetHost) else { return }
        status = error.localizedDescription
        feedbackPhase = .failure
      }
    }
  }
  private func loadAuthorization(allowUserInteraction: Bool) {
    guard let id = deviceID, !busy, !host.isEmpty, isCurrentTarget(host) else { return }
    let activeSession = model?.c6SessionAuthorization(deviceID: id) ?? ""
    let secret =
      !allowUserInteraction && !activeSession.isEmpty
      ? activeSession
      : C6SecretStore.read(deviceID: id, allowUserInteraction: allowUserInteraction)
    guard !secret.isEmpty else {
      pair()
      return
    }
    sessionToken = secret
    savedAuthorization = true
    authorizationWasStored = !sessionOnlyAuthorization
    transfer(save: false)
  }
  @ViewBuilder private var localOptions: some View {
    Toggle("本地时钟", isOn: $config.clock)
    Stepper(
      "饱和度：\(config.saturationPercent)%", value: $config.saturationPercent, in: 50...200, step: 5)
    Stepper("对比度：\(config.contrastPercent)%", value: $config.contrastPercent, in: 75...150, step: 5)
    DisclosureGroup("Home Assistant 实体订阅") {
      Toggle("直连 Home Assistant", isOn: $config.ha.enabled)
      if let connection = model?.c6HomeAssistantConnection {
        LabeledContent("设备管理中的服务器", value: connection.name)
        Button("使用设备管理中的连接") { reuseHomeAssistantConnection() }
          .help("自动填写服务器与令牌，不需要重复输入。")
      }
      TextField("服务器局域网 IP", text: $config.ha.host)
      TextField("端口", value: $config.ha.port, formatter: NumberFormatter())
      Toggle("HTTPS / WSS（校验证书）", isOn: $config.ha.tls)
      SecureField(config.ha.tokenSet ? "长期令牌已保存；留空保持" : "长期访问令牌", text: $credentials.haToken)
      ForEach(config.ha.entities.indices, id: \.self) { i in
        HStack {
          VStack {
            TextField("实体 ID，如 sensor.room_temperature", text: $config.ha.entities[i].id)
            TextField("显示名称（可选）", text: $config.ha.entities[i].name)
          }
          Button("移除") { config.ha.entities.remove(at: i) }
        }
      }
      Button("添加实体") { config.ha.entities.append(.init()) }.disabled(config.ha.entities.count >= 6)
    }
    DisclosureGroup("打印机 · Bambu Lab / Formlabs") {
      ForEach(config.printers.indices, id: \.self) { i in
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Toggle("\(config.printers[i].brandName) · \(config.printers[i].name.isEmpty ? "打印机 \(i + 1)" : config.printers[i].name)", isOn: $config.printers[i].enabled)
            Spacer()
            Button("移除") {
              let key = config.printers[i].credentialKey
              credentials.formClientSecrets.removeValue(forKey: key)
              credentials.printerAccessCodes.removeValue(forKey: key)
              config.printers.remove(at: i)
            }
          }
          TextField("用户设备名称", text: $config.printers[i].name)
          Picker("数据源", selection: Binding<String>(
            get: { config.printers[i].sourceFormlabs ? "formlabs" : config.printers[i].sourceHA ? "ha" : "mqtt" },
            set: { source in
              let old = config.printers[i]
              guard source != old.source else { return }
              credentials.formClientSecrets.removeValue(forKey: old.credentialKey)
              credentials.printerAccessCodes.removeValue(forKey: old.credentialKey)
              var replacement = C6PrinterConfiguration()
              replacement.name = old.name; replacement.enabled = old.enabled
              replacement.serial = UUID().uuidString.replacingOccurrences(of: "-", with: "")
              replacement.sourceFormlabs = source == "formlabs"; replacement.sourceHA = source == "ha"
              config.printers[i] = replacement
            })) {
            Text("Bambu Lab · Home Assistant").tag("ha")
            Text("Bambu Lab · 本地 MQTT").tag("mqtt")
            Text("Formlabs 云端 API").tag("formlabs")
          }
          if config.printers[i].sourceFormlabs {
            TextField("Formlabs 序列号", text: $config.printers[i].serial)
            TextField("Client ID", text: $config.printers[i].formClientID)
            SecureField(config.printers[i].formCredentialsSet ? "Client Secret 已保存；留空保持" : "Client Secret",
              text: Binding(get: { credentials.formClientSecrets[config.printers[i].credentialKey] ?? "" },
                            set: { credentials.formClientSecrets[config.printers[i].credentialKey] = $0 }))
            Toggle("显示层数", isOn: $config.printers[i].showLayers)
            Toggle("显示耗材", isOn: $config.printers[i].showMaterial)
            Toggle("显示任务缩略图", isOn: $config.printers[i].showImage)
            Toggle("使用品牌强调色", isOn: $config.printers[i].brandAccent)
            HelpIcon(text: "C6 直接访问 Formlabs Dashboard 云端 API，需要联网。Client Secret 保存在设备中，不会由配置接口回传；OAuth Token 仅缓存在内存。打印时约 30 秒查询一次，空闲时约 2 分钟。")
          } else if config.printers[i].sourceHA {
            entityPicker("打印状态", selection: $config.printers[i].statusEntity)
            entityPicker("打印进度", selection: $config.printers[i].progressEntity)
            entityPicker("任务名称", selection: $config.printers[i].taskEntity)
            entityPicker("剩余时间", selection: $config.printers[i].remainingEntity)
            entityPicker("摄像头 / 主画面", selection: $config.printers[i].imageEntity)
            entityPicker("任务封面", selection: $config.printers[i].taskCoverEntity)
            Toggle("显示实况与任务封面", isOn: $config.printers[i].showImage)
            Toggle("周期采样主画面", isOn: $config.printers[i].liveImage)
            Button("复用 Home Assistant 连接") { reuseHomeAssistantConnection() }
            HelpIcon(
              text:
                "请选择对应打印机的打印状态实体，不是 SD 卡状态。其余字段可留空；设备直接订阅所选实体，不需要打印机 LAN 访问码。自动同步开启时以侧边栏选择与设备管理绑定为准；手工设置前请关闭自动同步。"
            )
          } else {
            TextField("打印机局域网 IP", text: $config.printers[i].host)
            TextField("设备序列号 SN", text: $config.printers[i].serial)
            SecureField(
              config.printers[i].accessCodeSet ? "访问码已保存；留空保持" : "LAN 访问码",
              text: Binding(
                get: {
                  credentials.printerAccessCodes[config.printers[i].credentialKey] ?? ""
                }, set: { credentials.printerAccessCodes[config.printers[i].credentialKey] = $0 }))
            Toggle("信任局域网自签名证书", isOn: $config.printers[i].trustLAN)
              .help("连接仍使用 TLS 加密，但不能验证打印机身份。仅在可信局域网使用；关闭后需提供打印机 CA / 服务器证书。")
            if !config.printers[i].trustLAN {
              TextField("PEM 证书", text: $config.printers[i].certificate, axis: .vertical).lineLimit(
                3...6)
            }
          }
        }.padding(.vertical, 8)
      }
      Button("添加打印机") {
        var printer = C6PrinterConfiguration()
        printer.serial = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        printer.sourceHA = true
        config.printers.append(printer)
        reuseHomeAssistantConnection()
      }.disabled(config.printers.count >= 3)
      Label("仅订阅状态 · 完成任务保留 30 分钟", systemImage: "info.circle")
    }
    DisclosureGroup("屏幕与本地轮转") {
      Stepper("亮度：\(config.brightness)%", value: $config.brightness, in: 0...100, step: 5)
      Stepper("轮转间隔：\(config.interval) 秒", value: $config.interval, in: 5...300, step: 5)
    }
    DisclosureGroup("天气") {
      Toggle("独立获取天气", isOn: $config.weather)
      TextField("显示城市", text: $config.weatherCity)
      TextField("纬度", value: $config.latitude, formatter: NumberFormatter())
      TextField("经度", value: $config.longitude, formatter: NumberFormatter())
      Stepper(
        "更新间隔：\(config.weatherMinutes) 分钟", value: $config.weatherMinutes, in: 15...180, step: 15)
    }
  }
  @ViewBuilder private func entityPicker(_ title: String, selection: Binding<String>) -> some View {
    if let model, !model.haEntityCatalog.isEmpty {
      Picker(title, selection: selection) {
        Text("不显示").tag("")
        if !selection.wrappedValue.isEmpty,
          !model.haEntityCatalog.contains(where: { $0.entityId == selection.wrappedValue })
        {
          Text(selection.wrappedValue).tag(selection.wrappedValue)
        }
        ForEach(model.haEntityCatalog, id: \.entityId) { entity in
          Text("\(entity.displayName) · \(entity.entityId)").tag(entity.entityId)
        }
      }
    } else {
      TextField(title + "实体 ID", text: selection)
    }
  }
  private func reuseHomeAssistantConnection() {
    guard let connection = model?.c6HomeAssistantConnection,
      let endpoint = C6ConfigurationSync.homeAssistantEndpoint(connection.url)
    else {
      status = "请先在设备管理中配置可直连的 Home Assistant 服务器。"
      feedbackPhase = .warning
      return
    }
    config.ha.enabled = true
    config.ha.host = endpoint.host
    config.ha.port = endpoint.port
    config.ha.tls = endpoint.tls
    credentials.haToken = connection.token
    status = "已复用设备管理中的连接，保存时同步给 C6。"
    feedbackPhase = .information
  }
  private func transfer(save: Bool) {
    busy = true
    status = save ? "正在保存设备配置…" : "正在读取设备配置…"
    let targetHost = host
    let secret = effectiveToken
    var pending = config
    var secrets = credentials
    if save, pending.printers.contains(where: { $0.sourceHA }) { pending.ha.enabled = true }
    if save, pending.ha.enabled, let connection = model?.c6HomeAssistantConnection,
      let endpoint = C6ConfigurationSync.homeAssistantEndpoint(connection.url)
    {
      pending.ha.host = endpoint.host
      pending.ha.port = endpoint.port
      pending.ha.tls = endpoint.tls
      secrets.haToken = connection.token
    }
    let request = pending
    let requestSecrets = secrets
    let saveOwnedOptionsOnly = save && automaticSync
    Task { @MainActor in
      defer { busy = false }
      do {
        guard isCurrentTarget(targetHost) else { return }
        let client = try C6StandaloneClient(host: targetHost)
        let result: C6StandaloneConfiguration
        if saveOwnedOptionsOnly {
          result = try await saveDeviceOwnedOptions(
            request, client: client, targetHost: targetHost, token: secret)
        } else {
          var resolved = request
          if save && resolved.ha.enabled {
            resolved.ha.host = try await C6ConfigurationSync.localIPv4(resolved.ha.host)
          }
          // DNS 查询期间设备可能被删除或改址，不把配置和凭据发给旧地址。
          guard isCurrentTarget(targetHost) else { return }
          result =
            try await
            (save
            ? saveSupported(resolved, client: client, token: secret, credentials: requestSecrets)
            : client.read(token: secret))
        }
        guard isCurrentTarget(targetHost) else { return }
        guard result.schemaVersion == 2 else {
          status = "请先通过 USB 刷入新 C6 固件，再配置独立订阅。"
          feedbackPhase = .warning
          return
        }
        let negotiated = (try? await client.capabilities(token: secret)) ?? C6StandaloneCapabilities()
        guard isCurrentTarget(targetHost) else { return }
        config = result
        capabilities = negotiated
        if let model, let deviceID { model.didUpdateC6DeviceConfiguration(result, deviceID: deviceID, host: targetHost) }
        loadedHost = targetHost
        credentials = .init()
        status = save ? "已保存到设备（修订 \(result.revision)）。" : "配置已读取（修订 \(result.revision)）。"
        feedbackPhase = .success
      } catch {
        guard isCurrentTarget(targetHost) else { return }
        if error as? C6StandaloneError == .unauthorized {
          if let id = deviceID {
            if let model { model.invalidateC6Authorization(deviceID: id, host: targetHost, token: secret) }
            else { _ = C6SecretStore.save("", deviceID: id) }
          }
          savedAuthorization = false
          loadedHost = ""
          sessionToken = ""
          authorizationWasStored = false
        }
        status = error.localizedDescription
        feedbackPhase = .failure
      }
    }
  }
  /// Automatic content sync may have advanced the device revision since this
  /// page opened. Rebase only device-owned controls; never re-send stale HA,
  /// printer, weather, color or credential fields from the page snapshot.
  private func saveDeviceOwnedOptions(
    _ request: C6StandaloneConfiguration,
    client: C6StandaloneClient, targetHost: String, token: String
  ) async throws -> C6StandaloneConfiguration {
    for attempt in 0..<2 {
      guard isCurrentTarget(targetHost), automaticSync else { throw CancellationError() }
      var latest = try await client.read(token: token)
      latest.enabled = request.enabled
      latest.localFirst = request.localFirst
      latest.diagnostics = request.diagnostics
      latest.flipAnimation = request.flipAnimation
      latest.clockStyle = request.clockStyle
      latest.rotation = request.rotation
      latest.cardMask = request.cardMask
      latest.language = request.language
      latest.digitStyle = request.digitStyle
      latest.sleepMode = request.sleepMode
      latest.idleSleepMinutes = request.idleSleepMinutes
      latest.sleepStartMinute = request.sleepStartMinute
      latest.sleepEndMinute = request.sleepEndMinute
      latest.keepPrintingAwake = request.keepPrintingAwake
      for i in latest.printers.indices {
        if let option = request.printers.first(where: { $0.identity == latest.printers[i].identity }) {
          latest.printers[i].rotate = option.rotate
          latest.printers[i].cardStyle = option.cardStyle
        }
      }
      guard isCurrentTarget(targetHost), automaticSync else { throw CancellationError() }
      do {
        return try await saveSupported(latest, client: client, token: token, credentials: C6Credentials())
      } catch C6StandaloneError.conflict where attempt == 0 { continue }
    }
    throw C6StandaloneError.conflict
  }
  private func saveSupported(_ configuration: C6StandaloneConfiguration, client: C6StandaloneClient,
                             token: String, credentials: C6Credentials) async throws -> C6StandaloneConfiguration {
    try await client.ensureSupports(configuration, token: token)
    guard isCurrentTarget(client.baseURL.host ?? "") else { throw CancellationError() }
    return try await client.save(configuration, token: token, credentials: credentials)
  }
  private func scheduleTime(_ keyPath: WritableKeyPath<C6StandaloneConfiguration, Int>) -> Binding<Date> {
    Binding(get: {
      Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(config[keyPath: keyPath] * 60))
    }, set: { date in
      let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
      config[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    })
  }
  private func readHealth() {
    busy = true
    status = "正在读取设备运行状态…"
    let targetHost = host
    let secret = effectiveToken
    Task { @MainActor in
      defer { busy = false }
      do {
        guard isCurrentTarget(targetHost) else { return }
        let data = try await C6StandaloneClient(host: targetHost).health(token: secret)
        guard isCurrentTarget(targetHost) else { return }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let uptime = object["uptime_seconds"] as? Int ?? 0
        let heap = object["free_heap"] as? Int ?? 0
        healthText =
          "运行 \(uptime / 60) 分钟 · 可用堆 \(heap / 1024) KB · HA \(object["ha_connected"] as? Bool == true ? "已订阅" : "未连接")"
        status = "设备运行状态已读取。"
        feedbackPhase = .success
      } catch {
        guard isCurrentTarget(targetHost) else { return }
        status = error.localizedDescription
        feedbackPhase = .failure
      }
    }
  }
  private func updateOTA() {
    guard pairingOnly, allowsFirmwareUpdate, !busy, !effectiveToken.isEmpty,
      isCurrentTarget(host) else { return }
    busy = true
    status = "正在上传并校验固件…"
    let targetHost = host
    let secret = effectiveToken
    Task { @MainActor in
      defer { busy = false }
      do {
        guard isCurrentTarget(targetHost) else { return }
        let firmware = try EmbeddedC6Firmware.resource(ota: true)
        let client = try C6StandaloneClient(host: targetHost)
        let before =
          try JSONSerialization.jsonObject(with: await client.health(token: secret))
          as? [String: Any]
        guard isCurrentTarget(targetHost) else { return }
        let bootID = before?["boot_id"] as? UInt64
        try await client.updateFirmware(firmware.data, token: secret, sha256: firmware.sha256)
        guard isCurrentTarget(targetHost) else { return }
        status = "设备已接受更新，等待重启…"
        for _ in 0..<20 {
          try await Task.sleep(nanoseconds: 3_000_000_000)
          guard isCurrentTarget(targetHost) else { return }
          if let data = try? await client.health(token: secret),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            (object["firmware"] as? String) == EmbeddedC6Firmware.version,
            let nextBootID = object["boot_id"] as? UInt64, nextBootID != bootID
          {
            guard isCurrentTarget(targetHost) else { return }
            status = "OTA 完成，已确认设备固件 \(EmbeddedC6Firmware.version)。"
            feedbackPhase = .success
            return
          }
        }
        status = "更新已上传，但尚未确认设备重启；请检查电源和网络。"
        feedbackPhase = .warning
      } catch {
        guard isCurrentTarget(targetHost) else { return }
        status = error.localizedDescription
        feedbackPhase = .failure
      }
    }
  }
}

/// Explicit request state: successful reads are not inferred from message text.
private enum C6FeedbackPhase {
  case information, working, success, warning, failure

  var symbol: String {
    switch self {
    case .information: return "info.circle"
    case .working: return "arrow.triangle.2.circlepath"
    case .success: return "checkmark.circle"
    case .warning: return "exclamationmark.triangle"
    case .failure: return "xmark.circle"
    }
  }
  var color: Color {
    switch self {
    case .failure: return .red
    case .warning: return .orange
    default: return .secondary
    }
  }
}

private struct C6StatusMessage: View {
  let text: String
  let phase: C6FeedbackPhase
  var body: some View {
    Label {
      Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: phase.symbol).foregroundStyle(phase.color)
    }
    .font(.callout)
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
  }
}
