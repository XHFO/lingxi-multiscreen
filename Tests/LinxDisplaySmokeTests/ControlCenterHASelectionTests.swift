import Foundation
import LinxDisplayCore

func testControlCenterHASelectionPolicy() {
    let selection = ControlCenterHASelection(connectionFingerprint: "source-a",
        entityIDs: [" light.desk ", "", "switch.fan", "light.desk", "\n"])
    checkEqual(selection.entityIDs, ["light.desk", "switch.fan"], "中控HA选择去空去重保留用户顺序")
    checkEqual(ControlCenterHASelection(connectionFingerprint: "source-a", entityIDs: []).entityIDs, [],
               "空选择保持空，不自动选择前几个实体")
    let encoded = try! JSONEncoder().encode(selection)
    checkEqual(try! JSONDecoder().decode(ControlCenterHASelection.self, from: encoded), selection,
               "独立中控选择与来源指纹完整往返")
    let legacy = Data(#"{"connectionFingerprint":"a","entityIDs":[" light.desk ","light.desk",""]}"#.utf8)
    checkEqual(try! JSONDecoder().decode(ControlCenterHASelection.self, from: legacy).entityIDs, ["light.desk"],
               "存档读取同样归一化，避免重复实体行")
    checkEqual(ControlCenterHAControlPolicy.supportedDomains, Set(["light", "switch", "fan", "input_boolean"]),
               "中控仅提供四种显式开关白名单")
    for domain in ["light", "switch", "fan", "input_boolean"] {
        let entity = HAEntity(entityId: domain + ".test", friendlyName: "Test", state: "off", unitOfMeasurement: nil)
        let on = ControlCenterHAControlPolicy.command(for: entity, selectedEntityIDs: [entity.entityId],
            expectedFingerprint: "a", currentFingerprint: "a", turnOn: true)
        checkEqual(on, HAServiceCommand(domain: domain, service: "turn_on", entityID: entity.entityId),
                   "\(domain)复用现有服务映射显式开启")
        let off = ControlCenterHAControlPolicy.command(for: entity, selectedEntityIDs: [entity.entityId],
            expectedFingerprint: "a", currentFingerprint: "a", turnOn: false)
        checkEqual(off?.service, "turn_off", "确认后的连续点按意图不被旧缓存off状态反转")
    }
    let light = HAEntity(entityId: "light.test", friendlyName: "Test", state: "on", unitOfMeasurement: nil)
    check(ControlCenterHAControlPolicy.command(for: light, selectedEntityIDs: [], expectedFingerprint: "a",
        currentFingerprint: "a", turnOn: false) == nil, "用户未选择的实体不能由中控发起控制")
    check(ControlCenterHAControlPolicy.command(for: light, selectedEntityIDs: [light.entityId], expectedFingerprint: "a",
        currentFingerprint: "b", turnOn: false) == nil, "来源指纹变化后不能发送旧实体控制")
    check(ControlCenterHAControlPolicy.command(for: light, selectedEntityIDs: [light.entityId], expectedFingerprint: "a",
        currentFingerprint: nil, turnOn: false) == nil, "连接被删除后不能发送控制")
    for state in ["unavailable", "unknown", "", " null ", "NONE"] {
        var offline = light; offline.state = state
        check(ControlCenterHAControlPolicy.command(for: offline, selectedEntityIDs: [offline.entityId], expectedFingerprint: "a",
            currentFingerprint: "a", turnOn: true) == nil, "不可用状态\(state)不会发出服务操作")
    }
    for domain in ["lock", "script", "scene", "automation", "button", "input_button", "cover", "vacuum", "climate", "media_player", "sensor", "binary_sensor"] {
        let entity = HAEntity(entityId: domain + ".test", friendlyName: "Test", state: "on", unitOfMeasurement: nil)
        check(ControlCenterHAControlPolicy.command(for: entity, selectedEntityIDs: [entity.entityId], expectedFingerprint: "a",
            currentFingerprint: "a", turnOn: false) == nil, "\(domain)保持只读，不继承更宽泛控制列表")
    }
}
