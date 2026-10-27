import Foundation
import LinxDisplayCore

func testHASharedConnectionResolverAndFirstFrameDemand() {
    let sourceID = UUID()
    let migrated = HASharedConnectionResolver.resolve(serverURL: " http://shared.local:8123\n", token: "shared-token",
        legacyServerURL: nil, legacyToken: nil)
    checkEqual(migrated?.serverURL, "http://shared.local:8123", "迁移后设备副本为空仍使用完整共享HA连接")
    checkEqual(migrated?.token, "shared-token", "共享令牌保持原始请求字节")
    checkEqual(HASharedConnectionResolver.resolve(serverURL: "http://shared.local", token: " shared-token")?.token,
               " shared-token", "解析器不会悄悄修剪认证令牌")
    let origin = migrated!.fingerprint
    let requestSources = HASourcePreviewOriginPolicy.matchingSources(requestFingerprint: origin,
        configurations: [sourceID: origin])
    var cache = HASourcePreviewCache<[String]>()
    cache.recordSuccess(["sensor.reading"], requestedSources: requestSources, currentConfigurations: [sourceID: origin])
    checkEqual(cache.value(for: sourceID, configurationFingerprint: migrated?.fingerprint), ["sensor.reading"],
               "迁移后成功请求可写入并读取同一HA来源缓存")

    let changed = HASharedConnectionResolver.resolve(serverURL: "http://shared.local:8123", token: "new-token",
        legacyServerURL: "http://old-copy.local", legacyToken: "old-copy-token")!
    checkEqual(changed.token, "new-token", "共享配置是唯一来源，旧设备副本不会覆盖新连接")
    cache.recordSuccess(["late-old-response"], requestedSources: requestSources,
                        currentConfigurations: [sourceID: changed.fingerprint])
    check(cache.value(for: sourceID, configurationFingerprint: changed.fingerprint) == nil,
          "共享配置在请求期间变化后旧响应不能冒充新连接结果")
    check(HASharedConnectionResolver.resolve(serverURL: "", token: "") == nil, "没有任何配置时不生成连接")
    check(HASharedConnectionResolver.resolve(serverURL: "http://new.local", token: "",
        legacyServerURL: "http://old.local", legacyToken: "old-token") == nil,
          "不把新共享地址和旧副本令牌拼成一套连接")
    check(HASharedConnectionResolver.resolve(serverURL: "", token: "new-token",
        legacyServerURL: "http://old.local", legacyToken: "old-token") == nil,
          "不把旧副本地址和新共享令牌拼成一套连接")
    checkEqual(HASharedConnectionResolver.resolve(serverURL: "", token: "",
        legacyServerURL: "http://legacy.local", legacyToken: "legacy-token")?.serverURL,
               "http://legacy.local", "仅完全缺少共享连接时兼容完整旧副本")

    var demand = ControlCenterSourcePreviewDemand()
    let firstWindow = UUID(), secondWindow = UUID(), printer = UUID()
    check(!demand.shouldRequest(origin: origin, needsFirstReading: true, requestInFlight: false),
          "未显示中控时不会新增来源请求")
    demand.setDevices([sourceID], owner: firstWindow)
    check(demand.shouldRequest(origin: origin, needsFirstReading: true, requestInFlight: false),
          "首次显示且缓存缺失时请求首帧")
    check(!demand.shouldRequest(origin: origin, needsFirstReading: false, requestInFlight: false),
          "已有缓存时不因打开中控额外轮询")
    check(!demand.shouldRequest(origin: origin, needsFirstReading: true, requestInFlight: true),
          "中央已有请求时等待其完成")
    demand.beganRequest(origin: origin)
    demand.setDevices([sourceID, printer], owner: firstWindow)
    check(!demand.shouldRequest(origin: origin, needsFirstReading: true, requestInFlight: false),
          "失败或重复生命周期登记不形成每秒重试")
    check(demand.shouldRequest(origin: changed.fingerprint, needsFirstReading: true, requestInFlight: false),
          "连接配置更换后允许新来源请求首帧")
    demand.setDevices([printer], owner: secondWindow)
    demand.remove(owner: firstWindow)
    checkEqual(demand.deviceIDs, [printer], "一个窗口关闭后保留其他窗口的来源需求")
    check(!demand.shouldRequest(origin: origin, needsFirstReading: true, requestInFlight: false),
          "其他窗口仍打开时不会重置失败请求节流")
    demand.remove(owner: secondWindow)
    demand.setDevices([sourceID], owner: firstWindow)
    check(demand.shouldRequest(origin: origin, needsFirstReading: true, requestInFlight: false),
          "重新打开中控允许一次明确重试，正常轮询间隔不变")
}
