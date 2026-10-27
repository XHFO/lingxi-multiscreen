import Foundation
import LinxDisplayCore

func testHASourcePreviewCachePolicy() {
    testHASharedConnectionResolverAndFirstFrameDemand()
    let sourceA = UUID(), sameConnection = UUID(), sourceB = UUID()
    let connectionA = HASourcePreviewOriginPolicy.fingerprint(serverURL: "http://ha-a.local:8123", token: "token-a")!
    let connectionB = HASourcePreviewOriginPolicy.fingerprint(serverURL: "http://ha-b.local:8123", token: "token-b")!
    let changedToken = HASourcePreviewOriginPolicy.fingerprint(serverURL: "http://ha-a.local:8123", token: "token-new")!
    checkEqual(connectionA.count, 64, "HA来源指纹使用SHA256，不保存明文令牌")
    check(connectionA != connectionB && connectionA != changedToken, "HA服务器或令牌变化均产生不同来源指纹")
    checkEqual(HASourcePreviewOriginPolicy.fingerprint(serverURL: "  http://ha-a.local:8123\n", token: "token-a"), connectionA,
               "HA URL首尾空白与实际请求一致，不改变来源")
    check(HASourcePreviewOriginPolicy.fingerprint(serverURL: "http://ha-a.local:8123", token: " token-a") != connectionA,
          "HA令牌按实际请求字节匹配，不把不同认证混为同源")
    check(HASourcePreviewOriginPolicy.fingerprint(serverURL: "", token: "token-a") == nil, "未配置地址不能构造来源证明")
    check(HASourcePreviewOriginPolicy.fingerprint(serverURL: "http://ha-a.local:8123", token: " \n") == nil, "未配置令牌不能构造来源证明")
    let configurations = [sourceA: connectionA, sameConnection: connectionA, sourceB: connectionB]
    let requestA = HASourcePreviewOriginPolicy.matchingSources(requestFingerprint: connectionA, configurations: configurations)
    checkEqual(Set(requestA.keys), Set([sourceA, sameConnection]), "请求只捕获相同URL与令牌的受管HA来源")
    check(HASourcePreviewOriginPolicy.matchingSources(requestFingerprint: nil, configurations: configurations).isEmpty,
          "无请求指纹时不能借用当前活动来源")

    var cache = HASourcePreviewCache<[String]>()
    check(cache.value(for: sourceA, configurationFingerprint: connectionA) == nil, "首次打开来源不伪造全局实体缓存")
    cache.recordSuccess(["a.sensor"], requestedSources: requestA, currentConfigurations: configurations)
    checkEqual(cache.value(for: sourceA, configurationFingerprint: connectionA), ["a.sensor"], "成功请求保存到对应稳定UUID")
    checkEqual(cache.value(for: sameConnection, configurationFingerprint: connectionA), ["a.sensor"], "完全相同连接可安全复用成功结果")
    check(cache.value(for: sourceB, configurationFingerprint: connectionB) == nil, "其他服务器不会读取同名实体池")
    check(cache.value(for: sourceA, configurationFingerprint: changedToken) == nil, "保存的令牌变化立即使旧缓存不可见")
    check(cache.value(for: sourceA, configurationFingerprint: nil) == nil, "连接配置被清空后旧缓存不可见")
    let changedConfigurations = [sourceA: changedToken, sameConnection: connectionA, sourceB: connectionB]
    cache.recordSuccess(["old-response"], requestedSources: requestA, currentConfigurations: changedConfigurations)
    check(cache.value(for: sourceA, configurationFingerprint: changedToken) == nil,
          "请求期间改连接后，旧响应不能标记为新来源的缓存")
    cache.recordSuccess(["new-response"], requestedSources: [sourceA: changedToken], currentConfigurations: changedConfigurations)
    cache.invalidate(requestedSources: requestA)
    checkEqual(cache.value(for: sourceA, configurationFingerprint: changedToken), ["new-response"],
               "旧连接延迟失败不能清掉新连接的成功数据")
    check(cache.value(for: sameConnection, configurationFingerprint: connectionA) == nil, "失败的连接不继续展示旧成功实体")
    cache.invalidate(requestedSources: [sourceA: changedToken])
    check(cache.value(for: sourceA, configurationFingerprint: changedToken) == nil, "当前连接失败返回无缓存")
    cache.recordSuccess(["removed-source"], requestedSources: [sourceA: connectionA], currentConfigurations: [:])
    check(cache.value(for: sourceA, configurationFingerprint: connectionA) == nil, "请求期间删除来源后不会恢复已删除档案缓存")
    cache.recordSuccess(["b.sensor"], requestedSources: [sourceB: connectionB], currentConfigurations: configurations)
    var consumerCopy = cache.value(for: sourceB, configurationFingerprint: connectionB)!
    consumerCopy.append("consumer-only")
    checkEqual(cache.value(for: sourceB, configurationFingerprint: connectionB), ["b.sensor"], "数组COW使预览消费者编辑不会改动缓存")
    cache.remove(sourceID: sourceB)
    check(cache.value(for: sourceB, configurationFingerprint: connectionB) == nil, "删除受管来源释放其缓存")
    cache.recordSuccess(["a.sensor"], requestedSources: requestA, currentConfigurations: configurations)
    cache.removeAll()
    check(cache.value(for: sourceA, configurationFingerprint: connectionA) == nil, "恢复出厂设置清除来源缓存")
}
