import Foundation
import LinxDisplayCore

/// DeepSeek 官方余额 / 平台用量解析、设置持久化、聚合器与渲染回归。
func testDeepSeek() async throws {
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12))!

    // 1) 官方余额：字符串金额、赠送/充值拆分、CNY 选择。
    let balanceJSON = """
    {
      "is_available": true,
      "balance_infos": [
        {"currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"}
      ]
    }
    """
    let balance = try DeepSeekUsageParser.balanceSnapshot(from: Data(balanceJSON.utf8), now: now)
    checkEqual(balance.state, .balanceOnly, "余额响应解析为仅余额状态")
    checkEqual(balance.currency, "CNY", "余额币种")
    check(abs(balance.totalBalance - 110) < 0.0001, "总余额")
    check(abs(balance.grantedBalance - 10) < 0.0001, "赠送余额")
    check(abs(balance.toppedUpBalance - 100) < 0.0001, "充值余额")
    check(balance.apiAvailable, "API 可用标记")
    checkEqual(balance.balanceText, "¥110.00", "余额显示文本")
    check(balance.hasBalance && !balance.hasUsageDetails, "仅有余额时不应伪造 Token 用量")

    // 2) 多币种：有余额的 USD 优先于零余额 CNY。
    let usdJSON = """
    {"is_available": false, "balance_infos": [
      {"currency": "CNY", "total_balance": "0.00", "granted_balance": "0", "topped_up_balance": "0"},
      {"currency": "USD", "total_balance": "5.50", "granted_balance": "1.50", "topped_up_balance": "4.00"}
    ]}
    """
    let usd = try DeepSeekUsageParser.balanceSnapshot(from: Data(usdJSON.utf8), now: now)
    checkEqual(usd.currency, "USD", "有余额的 USD 优先")
    checkEqual(usd.balanceText, "$5.50", "USD 显示文本")
    check(!usd.apiAvailable, "is_available=false 保留 API 不可用状态")

    // 3) 平台月度用量：今日与本月聚合、REQUEST 单独计数、成本按币种保留。
    let amountJSON = """
    {"code": 0, "data": {"biz_code": 0, "biz_data": {
      "total": [
        {"model": "deepseek-chat", "usage": [
          {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "1100"},
          {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "2000"},
          {"type": "RESPONSE_TOKEN", "amount": "3000"},
          {"type": "REQUEST", "amount": "7"}
        ]}
      ],
      "days": [
        {"date": "2026-10-30", "data": [
          {"model": "deepseek-chat", "usage": [
            {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "100"},
            {"type": "REQUEST", "amount": "2"}
          ]}
        ]},
        {"date": "2026-10-31", "data": [
          {"model": "deepseek-chat", "usage": [
            {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "1000"},
            {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "2000"},
            {"type": "RESPONSE_TOKEN", "amount": "3000"},
            {"type": "REQUEST", "amount": "5"}
          ]},
          {"model": "deepseek-reasoner", "usage": [
            {"type": "RESPONSE_TOKEN", "amount": "0"},
            {"type": "REQUEST", "amount": "0"}
          ]}
        ]}
      ]
    }}}
    """
    let costJSON = """
    {"code": 0, "data": {"biz_code": 0, "biz_data": [{
      "currency": "CNY",
      "total": [{"model": "deepseek-chat", "usage": [
        {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "0.0223"},
        {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "0.0456"},
        {"type": "RESPONSE_TOKEN", "amount": "0.0789"}
      ]}],
      "days": [
        {"date": "2026-10-30", "data": [{"model": "deepseek-chat", "usage": [
          {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "0.01"}
        ]}]},
        {"date": "2026-10-31", "data": [{"model": "deepseek-chat", "usage": [
          {"type": "PROMPT_CACHE_HIT_TOKEN", "amount": "0.0123"},
          {"type": "PROMPT_CACHE_MISS_TOKEN", "amount": "0.0456"},
          {"type": "RESPONSE_TOKEN", "amount": "0.0789"}
        ]}]}
      ]
    }]}}
    """
    let details = try DeepSeekUsageParser.usageDetails(amountData: Data(amountJSON.utf8),
                                                       costData: Data(costJSON.utf8),
                                                       now: now, calendar: calendar)
    checkEqual(details.todayTokens, 6_000, "今日 Token 汇总")
    checkEqual(details.monthTokens, 6_100, "本月 Token 汇总")
    checkEqual(details.todayRequests, 5, "今日请求数")
    checkEqual(details.monthRequests, 7, "本月请求数")
    check(abs((details.todayCost ?? -1) - 0.1368) < 0.000001, "今日花费汇总")
    check(abs((details.monthCost ?? -1) - 0.1468) < 0.000001, "本月花费汇总")
    checkEqual(details.topModel, "deepseek-chat", "主要模型")

    // 4) 鉴权错误码映射为 unauthorized，供界面提示重新登录。
    let expired = Data(#"{"code": 40003, "msg": "token expired"}"#.utf8)
    do {
        _ = try DeepSeekUsageParser.usageDetails(amountData: expired, costData: expired,
                                                 now: now, calendar: calendar)
        check(false, "失效平台令牌应抛错")
    } catch let error as DeepSeekUsageError {
        checkEqual(error, .unauthorized, "平台令牌失效错误映射")
    }

    // 5) 快照合并后可渲染，圆角卡片与大屏模块都不会崩溃。
    var snapshot = balance
    snapshot.state = .live
    snapshot.todayTokens = details.todayTokens
    snapshot.monthTokens = details.monthTokens
    snapshot.todayCost = details.todayCost
    snapshot.monthCost = details.monthCost
    snapshot.todayRequests = details.todayRequests
    snapshot.monthRequests = details.monthRequests
    snapshot.topModel = details.topModel
    check(snapshot.hasUsageDetails, "合并平台用量后标记为明细可用")
    checkEqual(snapshot.todayTokensText, "6.0K", "Token 紧凑格式")
    checkEqual(snapshot.monthCostText, "¥0.15", "本月花费两位小数")

    var settings = AppSettings()
    settings.deepSeekAPIKey = "sk-test-deepseek"
    settings.deepSeekPlatformToken = "platform-token"
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    checkEqual(restored.deepSeekAPIKey, "sk-test-deepseek", "DeepSeek API Key 设置往返")
    checkEqual(restored.deepSeekPlatformToken, "platform-token", "平台会话令牌设置往返")

    let card = try ScreenRenderer.renderDeepSeek(snapshot, settings: settings, now: now)
    checkEqual(card.image.width, ScreenRenderer.width, "DeepSeek 键盘卡片宽度")
    checkEqual(card.image.height, ScreenRenderer.height, "DeepSeek 键盘卡片高度")
    check(!card.data.isEmpty, "DeepSeek 键盘卡片 JPEG 非空")

    let empty = try ScreenRenderer.renderDeepSeek(.notConfigured, settings: settings, now: now)
    check(!empty.data.isEmpty, "未配置状态也可渲染")

    let square = ScreenRenderer.renderDeviceCanvas(
        modules: [.deepSeek], system: .empty, nowPlaying: .placeholder,
        pomodoro: PomodoroSnapshot(phase: .idle, effectivePhase: .idle, taskName: "",
                                   remaining: 0, duration: 0, completedFocusSessions: 0),
        customText: "", settings: settings, deepSeek: snapshot,
        now: now, width: 240, height: 240, palette: settings.resolvedPalette,
        optimizeForEInk: false)
    checkEqual(square.width, 240, "DeepSeek 240×240 模块宽度")
    checkEqual(square.height, 240, "DeepSeek 240×240 模块高度")

    // 6) 能力目录：卡片自动出现在键盘、AI Mac 与轮播管理中。
    guard let capability = CardCapabilityRegistry.capability(for: .deepSeek) else {
        check(false, "DeepSeek 卡片未注册到能力目录")
        return
    }
    check(capability.requirements.contains(.quotas), "DeepSeek 卡片会触发额度数据刷新")
    checkEqual(capability.recipe, .modules([.deepSeek]), "DeepSeek 卡片渲染配方")
    checkEqual(DisplayMode.deepSeek.rawValue, 25, "DisplayMode.deepSeek 稳定编号")
    checkEqual(CanvasModule.deepSeek.rawValue, 31, "CanvasModule.deepSeek 稳定编号")

    // 7) 统一调取器会带上 DeepSeek 快照，且仍保留其他数据源。
    let aggregator = UsageDataAggregator(
        fetchCodex: { _ in UsageSnapshot.sample },
        fetchQuota: { QwenWorkQuota.sample },
        fetchGrokBot: { .notConfigured },
        fetchDeepSeek: { snapshot })
    let outcome = await aggregator.fetch(codexCliPath: nil)
    checkEqual(outcome.deepSeek, snapshot, "聚合器传递 DeepSeek 快照")
    check(outcome.failures.isEmpty, "未配置不是失败：\(outcome.failures)")

    print("  DeepSeek 官方余额与平台用量通过")
}
