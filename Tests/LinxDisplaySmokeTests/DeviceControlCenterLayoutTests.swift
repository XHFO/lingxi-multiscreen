import Foundation
import LinxDisplayCore

func testDeviceControlCenterLayout() throws {
    let device = "device:11111111-1111-1111-1111-111111111111"
    let source = "cloudflare:11111111-1111-1111-1111-111111111111"
    let weather = "weather:open-meteo"
    let all = [device, source, weather]
    let defaults = DeviceControlCenterCardSize()
    checkEqual(defaults.preferredWidth, 320, "中控卡片默认宽320pt")
    checkEqual(defaults.preferredHeight, 360, "中控卡片默认高360pt")
    let minimum = DeviceControlCenterCardSize(preferredWidth: -1, preferredHeight: 0)
    checkEqual(minimum, defaults, "过小旧尺寸迁移到1×1网格")
    let maximum = DeviceControlCenterCardSize(columnSpan: 2, rowSpan: 2)
    let extraLarge = DeviceControlCenterCardSize(columnSpan: 2, rowSpan: 3)
    checkEqual(DeviceControlCenterCardSize(preferredWidth: 5000, preferredHeight: 10000), extraLarge,
               "过大尺寸限制到新增2×3网格")
    checkEqual(maximum.preferredWidth, 658, "两列的宽度包含一个18pt网格间隔")
    checkEqual(maximum.preferredHeight, 738, "两行的高度包含一个18pt网格间隔")
    checkEqual(DeviceControlCenterCardSize(columnSpan: -10, rowSpan: 99),
               .init(columnSpan: 1, rowSpan: 2), "窄卡仍最多两行，不引入未设计的1×3组合")
    checkEqual(DeviceControlCenterCardSize(columnSpan: 1, rowSpan: 3), .init(columnSpan: 1, rowSpan: 2),
               "仅新增2×3，不自动开启1×3")
    checkEqual(extraLarge.preferredHeight, 1116, "三行包含两个18pt网格间隔")
    checkEqual(DeviceControlCenterCardSize.heightRange.upperBound, 1116, "点尺寸范围包含完整2×3高度")
    checkEqual(DeviceControlCenterCardSize(preferredWidth: 658, preferredHeight: 926), maximum,
               "旧2×2高度在第三行中点以下仍保留两行")
    checkEqual(DeviceControlCenterCardSize(preferredWidth: 658, preferredHeight: 927), extraLarge,
               "第三行中点吸附到新增2×3")
    checkEqual(DeviceControlCenterCardSize(preferredWidth: 488, preferredHeight: 548), defaults,
               "旧点尺寸按距离选择最近的固定组合")
    checkEqual(DeviceControlCenterCardSize(preferredWidth: 489, preferredHeight: 549), maximum,
               "两种跨度正好等距时选择较大组合")
    let combinations = [
        DeviceControlCenterCardSize(columnSpan: 1, rowSpan: 1),
        DeviceControlCenterCardSize(columnSpan: 2, rowSpan: 1),
        DeviceControlCenterCardSize(columnSpan: 1, rowSpan: 2),
        DeviceControlCenterCardSize(columnSpan: 2, rowSpan: 2),
        extraLarge
    ]
    checkEqual(Set(combinations.map { "\($0.columnSpan)×\($0.rowSpan)" }).count, 5,
               "保留原四种网格并新增2×3")
    for invalid in [Double.nan, .infinity, -.infinity] {
        checkEqual(DeviceControlCenterCardSize(preferredWidth: invalid, preferredHeight: invalid), defaults,
                   "非有限拖动值安全回到默认尺寸")
    }

    var layout = DeviceControlCenterLayout(cardOrder: [weather, weather, "deleted", ""])
    checkEqual(layout.orderedIDs(for: all + [device, ""]), [weather, device, source],
               "保存顺序忽略已删/重复项，新卡保留默认相对顺序")
    check(layout.setSize(for: device, width: 700, height: 600), "设备卡可保存独立尺寸")
    checkEqual(layout.size(for: source), defaults, "相同UUID的Cloudflare源不继承设备尺寸")
    check(layout.setSize(for: source, width: 658, height: 360), "源卡尺寸可独立修改")
    check(!layout.setSize(for: source, width: 650, height: 350), "吸附到相同网格时不重复保存布局")
    checkEqual(layout.size(for: device), .init(preferredWidth: 700, preferredHeight: 600),
               "源卡改动不覆盖设备卡")
    check(!layout.setSize(for: "", width: 400, height: 400), "拒绝缺失身份的尺寸写入")
    check(layout.move(source, before: weather, availableIDs: all), "支持拖动到卡片之前")
    checkEqual(layout.orderedIDs(for: all), [source, weather, device], "before按最终顺序排列")
    check(layout.move(source, after: device, availableIDs: all), "支持拖动到卡片之后")
    checkEqual(layout.orderedIDs(for: all), [weather, device, source], "after移除源位置后再计算目标")
    check(layout.move(source, to: -5, availableIDs: all), "负索引安全落在开头")
    checkEqual(layout.orderedIDs(for: all).first, source, "负索引不越界")
    check(layout.move(source, to: Int.max, availableIDs: all), "过大索引安全落在末尾")
    checkEqual(layout.orderedIDs(for: all).last, source, "过大索引不越界")
    let unchanged = layout
    check(!layout.move("deleted", to: 0, availableIDs: all), "不能移动已删身份")
    check(!layout.move(device, before: device, availableIDs: all), "自身放置不改变顺序")
    check(!layout.move(device, after: "deleted", availableIDs: all), "删除中的目标不会吞掉卡片")
    checkEqual(layout, unchanged, "失败的移动保持原布局")
    let newSource = "cloudflare:new"
    checkEqual(layout.orderedIDs(for: all + [newSource]).last, newSource, "新增来源自动附加，不重置已有排序")

    let otherDevice = "device:second"
    var sections = DeviceControlCenterLayout(cardOrder: [newSource, device, weather, otherDevice, source])
    let screenIDs = [device, otherDevice]
    let sourceIDs = [source, newSource, weather]
    let previousSources = sections.orderedIDs(for: sourceIDs)
    check(sections.move(otherDevice, before: device, availableIDs: screenIDs), "只传屏幕分区也能排序")
    checkEqual(sections.orderedIDs(for: screenIDs), [otherDevice, device], "屏幕分区采用新顺序")
    checkEqual(sections.orderedIDs(for: sourceIDs), previousSources, "屏幕重排不丢失数据源分区的保存顺序")
    check(sections.move(source, before: newSource, availableIDs: sourceIDs), "只传数据源分区也能排序")
    checkEqual(sections.orderedIDs(for: sourceIDs), [source, newSource, weather], "数据源分区采用新顺序")
    checkEqual(sections.orderedIDs(for: screenIDs), [otherDevice, device], "数据源重排不丢失屏幕分区顺序")
    check(sections.move("device:new", to: 0, availableIDs: screenIDs + ["device:new"]), "分区内新增卡可立即移动")
    checkEqual(sections.orderedIDs(for: sourceIDs), [source, newSource, weather], "移动新增卡仍保留另一分区")

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let restored = try decoder.decode(DeviceControlCenterLayout.self, from: encoder.encode(layout))
    checkEqual(restored, layout, "尺寸和排序无损JSON往返")

    let legacyLayout = Data(#"{"cardSizes":{"device:old":{"preferredWidth":658,"preferredHeight":360}},"cardOrder":["device:old","source:weather:open-meteo"]}"#.utf8)
    let migratedLayout = try decoder.decode(DeviceControlCenterLayout.self, from: legacyLayout)
    checkEqual(migratedLayout.groups, [], "旧桌面布局不自动拆分设备和数据源")
    checkEqual(migratedLayout.cardGroups, [:], "旧桌面布局所有卡片默认混排")
    checkEqual(migratedLayout.orderedIDs(for: ["device:old", "source:weather:open-meteo"], inGroup: nil),
               ["device:old", "source:weather:open-meteo"], "旧设备和数据源保留已有混合顺序")
    checkEqual(migratedLayout.size(for: "device:old").columnSpan, 2, "分组迁移保留旧卡片尺寸")
    checkEqual(migratedLayout.hiddenCardIDs, [], "旧布局没有隐藏字段时继续展示所有原卡片")
    checkEqual(migratedLayout.homeAssistantSelections, [:], "旧布局没有中控实体选择时不自动选择实体")

    var visibility = DeviceControlCenterLayout(cardOrder: all)
    let retainedGroup = visibility.createGroup(title: "保留分组")!
    visibility.setGroup(for: source, to: retainedGroup)
    visibility.setSize(for: source, width: 658, height: 738)
    let retainedOrder = visibility.cardOrder
    check(visibility.setCardVisible(false, for: source), "可以从中控移除已配置数据源的卡片")
    checkEqual(visibility.visibleIDs(for: all), [device, weather], "隐藏后只投影可见卡片")
    checkEqual(visibility.visibleIDs(for: all, inGroup: retainedGroup), [], "隐藏卡片不留可见分组占位")
    checkEqual(visibility.cardOrder, retainedOrder, "移除卡片保留原顺序")
    checkEqual(visibility.groupID(for: source), retainedGroup, "移除卡片保留原分组")
    checkEqual(visibility.size(for: source), maximum, "移除卡片保留原尺寸")
    check(!visibility.setCardVisible(false, for: source), "重复移除不会重复保存")
    check(!visibility.setCardVisible(true, for: ""), "不能添加缺失身份的卡片")
    check(!visibility.isCardVisible(""), "空身份不创建可见卡片")
    check(visibility.setCardVisible(false, for: "temporarily-unavailable"), "来源临时消失时保留隐藏偏好")
    let roundTripVisibility = try decoder.decode(DeviceControlCenterLayout.self, from: encoder.encode(visibility))
    checkEqual(roundTripVisibility, visibility, "隐藏偏好与尺寸分组一起无损持久化")
    check(visibility.setCardVisible(true, for: source), "可以从卡片库重新添加隐藏卡片")
    checkEqual(visibility.visibleIDs(for: all), all, "重新添加恢复原顺序")
    checkEqual(visibility.visibleIDs(for: all, inGroup: retainedGroup), [source], "重新添加恢复原分组")
    checkEqual(visibility.size(for: source), maximum, "重新添加恢复原尺寸")
    visibility.setCardVisible(false, for: source)
    check(visibility.move(weather, before: device, availableIDs: visibility.visibleIDs(for: all)), "隐藏卡片后可调整其余可见卡片")
    visibility.setCardVisible(true, for: source)
    checkEqual(visibility.visibleIDs(for: all), [weather, source, device], "可见卡片重排保留隐藏卡片的顺序槽位")
    for initial in [DeviceControlCenterLayout(), try decoder.decode(DeviceControlCenterLayout.self, from: Data("{}".utf8))] {
        var firstOrder = initial
        firstOrder.setCardVisible(false, for: source)
        check(firstOrder.move(weather, before: device, availableIDs: firstOrder.visibleIDs(for: all), allAvailableIDs: all),
              "首次或旧空顺序布局可重排可见卡片")
        firstOrder.setCardVisible(true, for: source)
        checkEqual(firstOrder.visibleIDs(for: all), [weather, source, device],
                   "首次重排先物化全局顺序，恢复隐藏卡仍保留中间槽位")
    }
    var freshGroupedOrder = DeviceControlCenterLayout()
    let freshGroup = freshGroupedOrder.createGroup(title: "首次分组")!
    freshGroupedOrder.setGroup(for: device, to: freshGroup)
    freshGroupedOrder.setGroup(for: weather, to: freshGroup)
    check(freshGroupedOrder.move(device, after: weather,
          availableIDs: freshGroupedOrder.visibleIDs(for: all, inGroup: freshGroup), allAvailableIDs: all),
          "默认空顺序的分组同样支持局部重排")
    checkEqual(freshGroupedOrder.orderedIDs(for: all), [weather, source, device],
               "首次分组重排保留其他分组卡片槽位")
    let malformedVisibility = try decoder.decode(DeviceControlCenterLayout.self,
        from: Data(#"{"hiddenCardIDs":"broken","cardOrder":["device:old"]}"#.utf8))
    checkEqual(malformedVisibility.hiddenCardIDs, [], "损坏可选隐藏字段安全恢复默认显示")
    checkEqual(malformedVisibility.cardOrder, ["device:old"], "隐藏字段损坏不丢弃其余布局")

    var independentHA = DeviceControlCenterLayout()
    check(independentHA.setHomeAssistantEntities(for: "managed:ha", connectionFingerprint: "server-a", entityIDs: ["light.desk", "light.desk", " "]),
          "中控Home Assistant实体选择独立存储")
    checkEqual(independentHA.homeAssistantEntityIDs(for: "managed:ha", connectionFingerprint: "server-a"), ["light.desk"], "中控实体选择规范化去重")
    checkEqual(independentHA.homeAssistantEntityIDs(for: "managed:ha", connectionFingerprint: "server-b"), [], "来源连接变化不沿用旧服务器实体")
    checkEqual(independentHA.homeAssistantEntityIDs(for: "managed:other", connectionFingerprint: "server-a"), [], "同服务器不同来源不共享选择")
    independentHA.setCardVisible(false, for: "source:managed:ha")
    independentHA.reset()
    checkEqual(independentHA.hiddenCardIDs, [], "恢复默认布局重新显示所有可用卡片")
    checkEqual(independentHA.homeAssistantEntityIDs(for: "managed:ha", connectionFingerprint: "server-a"), ["light.desk"], "恢复布局保留独立HA实体选择")
    check(independentHA.setHomeAssistantEntities(for: "managed:ha", connectionFingerprint: "server-a", entityIDs: []), "用户可以明确取消所有中控实体")
    check(independentHA.homeAssistantSelections["managed:ha"] != nil, "显式空选择不会被当作未配置而自动补选")
    checkEqual(try decoder.decode(DeviceControlCenterLayout.self, from: encoder.encode(independentHA)), independentHA, "中控HA选择JSON往返保留显式空选择")

    var grouped = DeviceControlCenterLayout(cardSizes: layout.cardSizes,
                                           cardOrder: [weather, device, source, newSource])
    checkEqual(grouped.createGroup(title: " \n\t "), nil, "纯空白分组名不会创建空分区")
    let homeGroup = grouped.createGroup(title: "  家庭  ")!
    let workGroup = grouped.createGroup(title: "工作")!
    let offlineCard = "device:temporarily-unavailable"
    checkEqual(grouped.groups.map(\.title), ["家庭", "工作"], "创建分组时修剪名称两端空白")
    check(homeGroup != workGroup, "新分组使用独立稳定身份")
    check(grouped.setGroup(for: device, to: homeGroup), "设备可加入用户分组")
    check(grouped.setGroup(for: weather, to: homeGroup), "数据源可和设备加入同一分组")
    check(grouped.setGroup(for: offlineCard, to: homeGroup), "暂时不可用卡片可保留分组偏好")
    check(grouped.setGroup(for: source, to: workGroup), "另一分组可独立接收数据源")
    checkEqual(grouped.orderedIDs(for: all + [newSource], inGroup: homeGroup), [weather, device],
               "同一分组按全局顺序混排设备和数据源")
    checkEqual(grouped.orderedIDs(for: all + [newSource], inGroup: nil), [newSource],
               "未分组卡片单独形成默认混合网格")
    checkEqual(grouped.orderedIDs(for: all, inGroup: "unknown-group"), [], "未知分组查询不会显示未分组卡片")
    checkEqual(grouped.orderedIDs(for: all + [newSource]), [weather, device, source, newSource],
               "加入分组不重写全局排序")
    let groupedBeforeInvalid = grouped
    check(!grouped.setGroup(for: device, to: "unknown-group"), "拒绝未知分组归属")
    check(!grouped.setGroup(for: "", to: homeGroup), "拒绝空卡片身份的分组归属")
    check(!grouped.setGroup(for: device, to: homeGroup), "重复归属不触发布局保存")
    check(!grouped.renameGroup(homeGroup, title: " \n"), "重命名不能清空分组名称")
    check(!grouped.renameGroup("unknown-group", title: "新名称"), "未知分组不能重命名")
    check(!grouped.removeGroup("unknown-group"), "未知分组不能被删除")
    check(!grouped.moveGroup("unknown-group", to: 0), "未知分组不能移动")
    checkEqual(grouped, groupedBeforeInvalid, "无效分组操作不改变尺寸顺序和归属")
    check(grouped.renameGroup(homeGroup, title: "  我的家庭 \n"), "分组可重命名")
    checkEqual(grouped.groups.first?.id, homeGroup, "分组改名保留身份与归属")
    checkEqual(grouped.groups.first?.title, "我的家庭", "分组改名修剪两端空白")
    checkEqual(grouped.groupID(for: device), homeGroup, "改名不移动卡片")
    check(!grouped.renameGroup(homeGroup, title: "我的家庭"), "相同名称不触发保存")
    check(grouped.moveGroup(workGroup, to: -10), "分组顺序支持移动到开头")
    checkEqual(grouped.groups.map(\.id), [workGroup, homeGroup], "分组顺序按最终位置排列")
    check(grouped.moveGroup(workGroup, to: Int.max), "分组顺序支持移动到末尾")
    checkEqual(grouped.groups.map(\.id), [homeGroup, workGroup], "分组索引安全限制在有效范围")
    check(!grouped.moveGroup(homeGroup, to: 0), "分组未移动时不触发保存")
    let preservedSizes = grouped.cardSizes
    check(grouped.move(device, before: weather, availableIDs: grouped.orderedIDs(for: all, inGroup: homeGroup)),
          "分组内可重新排列混合卡片")
    checkEqual(grouped.orderedIDs(for: all, inGroup: homeGroup), [device, weather], "分组内排序应用到混合卡片")
    checkEqual(grouped.orderedIDs(for: all, inGroup: workGroup), [source], "分组内重排保留另一分组顺序")
    check(grouped.setGroup(for: weather, to: workGroup), "卡片可移动到另一分组")
    checkEqual(grouped.orderedIDs(for: all, inGroup: workGroup), [weather, source],
               "跨组移动保留全局相对顺序")
    check(grouped.setGroup(for: weather, to: nil), "卡片可移回未分组网格")
    checkEqual(grouped.groupID(for: weather), nil, "移出分组删除该卡片归属")
    checkEqual(grouped.cardSizes, preservedSizes, "重排分组和移动卡片不改尺寸")
    let groupedRoundTrip = try decoder.decode(DeviceControlCenterLayout.self, from: encoder.encode(grouped))
    checkEqual(groupedRoundTrip, grouped, "自定义组顺序归属和布局无损JSON往返")
    checkEqual(groupedRoundTrip.groupID(for: offlineCard), homeGroup, "不可用卡片归属在保存后仍然保留")
    let returningIDs = all + [offlineCard]
    checkEqual(groupedRoundTrip.orderedIDs(for: returningIDs, inGroup: homeGroup), [device, offlineCard],
               "暂时消失的卡片重新出现时恢复分组")
    let beforeDeleteOrder = grouped.cardOrder
    check(grouped.removeGroup(homeGroup), "用户可删除自定义分组")
    checkEqual(grouped.groupID(for: device), nil, "删除分组后现有卡片返回未分组")
    checkEqual(grouped.groupID(for: offlineCard), nil, "删除分组后不可用卡片也返回未分组")
    checkEqual(grouped.groupID(for: source), workGroup, "删除分组保留其他分组成员")
    checkEqual(grouped.cardOrder, beforeDeleteOrder, "删除分组不改卡片排序")
    checkEqual(grouped.cardSizes, preservedSizes, "删除分组不丢失尺寸偏好")
    checkEqual(grouped.orderedIDs(for: all, inGroup: nil), [device, weather], "删除分组后卡片可在默认网格找回")
    grouped.resetOrder()
    checkEqual(grouped.groupID(for: source), workGroup, "单独重置卡片顺序保留自定义分组")
    grouped.reset()
    checkEqual(grouped, DeviceControlCenterLayout(), "完整还原布局同时清除分组与归属")

    let malformedGroups = Data(#"{"groups":[{"id":"a","title":" A "},{"id":"a","title":"duplicate"},{"id":" ","title":"invalid"},{"id":"blank","title":" \n"},{"id":"broken","title":42},false,{"id":"b","title":"B"}],"cardGroups":{"device:present":"a","device:missing":"b","source:stale":"removed","":"a"},"cardOrder":["source:stale","device:present"]}"#.utf8)
    let repairedGroups = try decoder.decode(DeviceControlCenterLayout.self, from: malformedGroups)
    checkEqual(repairedGroups.groups.map(\.id), ["a", "b"], "解码移除重复身份空名称和损坏的分组但保留其余组")
    checkEqual(repairedGroups.groups.map(\.title), ["A", "B"], "解码同样修剪分组名称")
    checkEqual(repairedGroups.cardGroups, ["device:present": "a", "device:missing": "b"],
               "解码过滤未知组归属同时保留暂不可用卡片")
    checkEqual(repairedGroups.orderedIDs(for: ["source:stale", "device:present"], inGroup: nil), ["source:stale"],
               "失效组引用的卡片可在默认混合网格中恢复")

    decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Inf", negativeInfinity: "-Inf", nan: "NaN")
    let malformedSize = Data(#"{"preferredWidth":"NaN","preferredHeight":"Inf"}"#.utf8)
    checkEqual(try decoder.decode(DeviceControlCenterCardSize.self, from: malformedSize), defaults,
               "历史/导入JSON中的NaN与Infinity不会污染布局")
    let partialSize = Data(#"{"preferredWidth":"wrong","preferredHeight":700}"#.utf8)
    checkEqual(try decoder.decode(DeviceControlCenterCardSize.self, from: partialSize),
               .init(columnSpan: 1, rowSpan: 2), "损坏旧宽度只回退该轴，保留有效高度跨度")
    let oldSize = Data(#"{"preferredWidth":660,"preferredHeight":540}"#.utf8)
    checkEqual(try decoder.decode(DeviceControlCenterCardSize.self, from: oldSize),
               .init(columnSpan: 2, rowSpan: 1), "旧自由尺寸无需迁移标志即可吸附到固定网格")
    let spanPriority = Data(#"{"columnSpan":1,"rowSpan":2,"preferredWidth":900,"preferredHeight":300}"#.utf8)
    checkEqual(try decoder.decode(DeviceControlCenterCardSize.self, from: spanPriority),
               .init(columnSpan: 1, rowSpan: 2), "新跨度字段优先于旧版点尺寸")
    let partialSpans = Data(#"{"columnSpan":"wrong","rowSpan":2,"preferredWidth":658}"#.utf8)
    checkEqual(try decoder.decode(DeviceControlCenterCardSize.self, from: partialSpans), maximum,
               "单轴跨度损坏时可从该轴旧尺寸恢复")
    let encodedSize = try JSONSerialization.jsonObject(with: encoder.encode(maximum)) as! [String: Any]
    checkEqual(encodedSize["columnSpan"] as? Int, 2, "新设置持久化列跨度")
    checkEqual(encodedSize["rowSpan"] as? Int, 2, "新设置持久化行跨度")
    check(encodedSize["preferredWidth"] == nil && encodedSize["preferredHeight"] == nil,
          "新设置不再持久化任意点尺寸")
    checkEqual(try decoder.decode(DeviceControlCenterCardSize.self, from: encoder.encode(extraLarge)), extraLarge,
               "2×3新尺寸无损JSON往返")
    checkEqual(try decoder.decode(DeviceControlCenterCardSize.self,
        from: Data(#"{"preferredWidth":658,"preferredHeight":738}"#.utf8)), maximum,
        "合法旧2×2点尺寸不会迁移为2×3")
    checkEqual(try decoder.decode(DeviceControlCenterCardSize.self,
        from: Data(#"{"columnSpan":2,"rowSpan":3}"#.utf8)), extraLarge,
        "显式2×3跨度可直接载入")

    let settings = AppSettings()
    settings.devices = [ManagedDevice(type: .keyboard, name: "same", settings: DeviceSettings())]
    let capturedBefore = DeviceSettings.capture(from: settings, type: .keyboard)
    var changes = 0
    settings.onChange = { changes += 1 }
    var layoutChanges = 0
    settings.onControlCenterLayoutChange = { layoutChanges += 1 }
    settings.controlCenterLayout = layout
    checkEqual(layoutChanges, 1, "布局改动触发专用本机持久化回调")
    checkEqual(changes, 0, "布局改动不触发设备渲染与推送回调")
    checkEqual(DeviceSettings.capture(from: settings, type: .keyboard), capturedBefore,
               "桌面布局不进入设备捕获/推送配置")
    let settingsData = try encoder.encode(settings)
    let restoredSettings = try decoder.decode(AppSettings.self, from: settingsData)
    checkEqual(restoredSettings.controlCenterLayout, layout, "AppSettings持久化桌面布局")
    var oldJSON = try JSONSerialization.jsonObject(with: settingsData) as! [String: Any]
    oldJSON.removeValue(forKey: "controlCenterLayout")
    let oldSettings = try decoder.decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: oldJSON))
    checkEqual(oldSettings.controlCenterLayout, DeviceControlCenterLayout(), "旧设置缺字段自动得到默认布局")
    checkEqual(oldSettings.devices, settings.devices, "旧设置迁移不改设备身份与原配置")
    oldJSON["controlCenterLayout"] = "broken optional desktop preference"
    let repaired = try decoder.decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: oldJSON))
    checkEqual(repaired.controlCenterLayout, DeviceControlCenterLayout(), "损坏可选布局不会阻断原设置载入")

    let canonicalGrid = DeviceControlCenterLayoutEngine.grid(availableWidth: 996)
    checkEqual(canonicalGrid.snappedSize(original: defaults, translation: .init(width: 168, height: 162)),
               defaults, "不足半格的拖动不改变组合")
    checkEqual(canonicalGrid.snappedSize(original: defaults, translation: .init(width: 169, height: 163)),
               maximum, "跨越半格时同时吸附到两列两行")
    checkEqual(canonicalGrid.snappedSize(original: maximum, translation: .init(width: -168, height: -162)),
               maximum, "收缩不足半格仍保留原组合")
    checkEqual(canonicalGrid.snappedSize(original: maximum, translation: .init(width: -169, height: -163)),
               defaults, "收缩达到半格时吸附回单格")
    checkEqual(canonicalGrid.snappedSize(original: defaults, translation: .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)),
               extraLarge, "极大拖动不会溢出且限定为两列三行")
    checkEqual(canonicalGrid.snappedSize(original: maximum, translation: .init(width: -CGFloat.greatestFiniteMagnitude, height: -CGFloat.greatestFiniteMagnitude)),
               defaults, "极大负拖动不会溢出且限定为一格")
    for invalid in [Double.nan, .infinity, -.infinity] {
        checkEqual(canonicalGrid.snappedSize(original: maximum, translation: .init(width: invalid, height: 500)),
                   extraLarge, "非有限横向拖动保留两列，纵向仍可扩展到第三行")
        checkEqual(canonicalGrid.snappedSize(original: defaults, translation: .init(width: 500, height: invalid)),
                   .init(columnSpan: 2, rowSpan: 1), "非有限纵向拖动只忽略该轴，保留有效横向吸附")
        checkEqual(canonicalGrid.snappedSize(original: defaults, translation: .init(width: invalid, height: invalid)),
                   defaults, "两轴均无效的拖动保持原尺寸")
    }
    let singleColumnGrid = DeviceControlCenterLayoutEngine.grid(availableWidth: 240)
    let savedWide = DeviceControlCenterCardSize(columnSpan: 2, rowSpan: 1)
    checkEqual(singleColumnGrid.snappedSize(original: savedWide, translation: .init(width: 0, height: 189)),
               maximum, "窄窗只向下拖动时保留已保存的两列偏好")
    checkEqual(singleColumnGrid.snappedSize(original: savedWide, translation: .init(width: -129, height: 0)),
               defaults, "窄窗明确收缩一列时可改为单列")
    let responsiveGrid = DeviceControlCenterLayoutEngine.grid(availableWidth: 818)
    checkEqual(responsiveGrid.snappedSize(original: .init(columnSpan: 1, rowSpan: 2),
                                         translation: .init(width: 0, height: responsiveGrid.rowHeight)), extraLarge,
               "窄高卡向下扩展到第三行时选择支持的2×3")
    checkEqual(responsiveGrid.snappedSize(original: extraLarge,
        translation: .init(width: -(responsiveGrid.columnWidth + responsiveGrid.spacing), height: 0)),
        .init(columnSpan: 1, rowSpan: 2), "2×3明确收窄时回到1×2，不陷入不能缩小的尺寸")
    checkEqual(responsiveGrid.snappedSize(original: extraLarge,
        translation: .init(width: 0, height: -(responsiveGrid.rowHeight + responsiveGrid.spacing))), maximum,
        "2×3可以单独向上收缩回旧2×2")
    checkEqual(responsiveGrid.snappedSize(original: defaults, translation: .init(width: 139, height: 0)),
               defaults, "响应式列宽使用当前半格阈值")
    checkEqual(responsiveGrid.snappedSize(original: defaults, translation: .init(width: 140, height: 0)),
               savedWide, "响应式列宽越过当前半格后吸附")
    checkEqual(DeviceControlCenterLayoutEngine.grid(availableWidth: 600).columnCount, 2,
               "小窗可使用两列紧凑卡片，不再一张卡占满页面")
    checkEqual(DeviceControlCenterLayoutEngine.grid(availableWidth: 505).columnCount, 1,
               "两张最小卡片放不下时保持单列")
    checkEqual(DeviceControlCenterLayoutEngine.grid(availableWidth: 506).columnCount, 2,
               "两张244pt紧凑卡片加间距后增加一列")
    for width in [244.0, 320, 480, 506, 600, 658, 818, 996, 1240, 1480, 1920, 2560, 3840] {
        let grid = DeviceControlCenterLayoutEngine.grid(availableWidth: width)
        check(grid.columnWidth >= 244, "正常窗口列宽始终不小于紧凑内容最小宽")
        check(abs(Double(grid.columnCount) * grid.columnWidth + Double(grid.columnCount - 1) * grid.spacing - width) < 0.000_001,
              "中控所有网格列填满窗口可用宽度，不保留1480pt固定上限")
        check((264...320).contains(grid.rowHeight), "紧凑行高不再被360pt最低高度撑大")
    }
    check(DeviceControlCenterLayoutEngine.grid(availableWidth: 1920).columnCount > DeviceControlCenterLayoutEngine.grid(availableWidth: 1480).columnCount,
          "全屏新增可见列以利用横向空间")

    let items = [
        DeviceControlCenterLayoutItem(id: device, size: .init(columnSpan: 1, rowSpan: 2)),
        DeviceControlCenterLayoutItem(id: source, size: .init(columnSpan: 2, rowSpan: 1)),
        DeviceControlCenterLayoutItem(id: weather),
        DeviceControlCenterLayoutItem(id: device)
    ]
    func assertGrid(_ items: [DeviceControlCenterLayoutItem], width: Double, spacing: Double = 18) {
        let grid = DeviceControlCenterLayoutEngine.grid(availableWidth: width, spacing: spacing)
        let frames = DeviceControlCenterLayoutEngine.frames(items: items, availableWidth: width, spacing: spacing)
        var seen = Set<String>()
        checkEqual(frames.map(\.id), items.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }.map(\.id),
                   "密集排布仅改变frame，返回身份序列保持保存顺序")
        checkEqual(frames, DeviceControlCenterLayoutEngine.frames(items: items, availableWidth: width, spacing: spacing),
                   "相同输入的密集排布稳定，不因重复布局跳动")
        for (index, frame) in frames.enumerated() {
            check(frame.x >= 0 && frame.y >= 0 && frame.maxX <= width + 0.000_001 && frame.height > 0,
                  "网格卡片frame落在窗口可用宽度内")
            let columnOrigin = frame.x / (grid.columnWidth + grid.spacing)
            let rowOrigin = frame.y / (grid.rowHeight + grid.spacing)
            check(abs(columnOrigin - columnOrigin.rounded()) < 0.000_001,
                  "所有卡片左边缘均落在相同的列网格上")
            check(abs(rowOrigin - rowOrigin.rounded()) < 0.000_001,
                  "所有卡片顶边缘均落在相同的行网格上")
            let columns = (frame.width + grid.spacing) / (grid.columnWidth + grid.spacing)
            let rows = (frame.height + grid.spacing) / (grid.rowHeight + grid.spacing)
            check(abs(columns - columns.rounded()) < 0.000_001 && (1...2).contains(Int(columns.rounded())),
                  "卡片宽度为一格或两格并包含正确间距")
            check(abs(rows - rows.rounded()) < 0.000_001 && (1...3).contains(Int(rows.rounded())),
                  "卡片高度为一至三格并包含正确间距")
            check(rows < 3 || columns == 2, "三行布局只应用于新增2×3宽卡")
            for other in frames.dropFirst(index + 1) {
                check(!frame.rect.intersects(other.rect), "五种网格组合互不重叠")
            }
        }
    }
    for width in [120.0, 240, 480, 640, 658, 818, 996, 1040, 1600] {
        let frames = DeviceControlCenterLayoutEngine.frames(items: items, availableWidth: width)
        checkEqual(frames.map(\.id), all, "宽窄窗口都保留顺序并忽略重复身份")
        assertGrid(items, width: width)
    }
    let mixed = (0..<25).map { DeviceControlCenterLayoutItem(id: "mixed:\($0)", size: combinations[$0 % combinations.count]) }
    for width in [320.0, 658, 996, 1334, 1600, 1920, 2560, 3840] {
        assertGrid(mixed, width: width)
        assertGrid(mixed, width: width, spacing: 24)
    }
    let paired = DeviceControlCenterLayoutEngine.frames(items: items, availableWidth: 996)
    checkEqual(paired[1].x, 338, "宽卡对齐第二列起点")
    checkEqual(paired[1].y, 0, "一张窄卡加一张宽卡刚好占据三列")
    checkEqual(paired[2].x, 338, "下一行跳过高卡占用的第一列")
    checkEqual(paired[2].y, 325.2, "矮卡下方可放下一张卡，仍对齐响应式行高")
    checkEqual(paired[0].maxY, 632.4, "高卡底边恰好对齐两张单格卡的底边")
    let narrow = DeviceControlCenterLayoutEngine.frames(items: items, availableWidth: 120)
    checkEqual(narrow[1].width, 120, "窄窗口两列卡临时适配单列且不溢出")
    checkEqual(items[1].size.columnSpan, 2, "窄窗口不改保存的两列偏好")
    checkEqual(items[0].size.rowSpan, 2, "窄窗口不改保存的两行偏好")
    let expanded = DeviceControlCenterLayoutEngine.frames(items: items, availableWidth: 996)
    checkEqual(expanded[1].width, 658, "窗口恢复后自动恢复两列显示")
    let compactSix = (0..<6).map { DeviceControlCenterLayoutItem(id: "compact:\($0)") }
    let compactFrames = DeviceControlCenterLayoutEngine.frames(items: compactSix, availableWidth: 906)
    check(compactFrames.map(\.maxY).max()! <= 600,
          "常见小窗口内容区可在600pt内排下六张标准卡，不再需要三行超高卡片")
    let squareItem = DeviceControlCenterLayoutItem(id: "large", size: maximum)
    let collapsedSquare = DeviceControlCenterLayoutEngine.frames(items: [squareItem], availableWidth: 480)[0]
    check(collapsedSquare.height <= 320, "双列大卡在单列窗口临时紧凑，避免变成巨大的纵向卡")
    checkEqual(squareItem.size, maximum, "单列适配不改写保存的大卡偏好")
    let reopenedSquare = DeviceControlCenterLayoutEngine.frames(items: [squareItem], availableWidth: 818)[0]
    checkEqual(reopenedSquare.height, responsiveGrid.rowHeight * 2 + responsiveGrid.spacing,
               "窗口放大后恢复大卡的两行比例")
    let extraLargeItem = DeviceControlCenterLayoutItem(id: "extra-large", size: extraLarge)
    let collapsedExtraLarge = DeviceControlCenterLayoutEngine.frames(items: [extraLargeItem], availableWidth: 480)[0]
    check(collapsedExtraLarge.height <= 320, "2×3在单列小窗暂时折叠为单行而非巨大长卡")
    checkEqual(extraLargeItem.size, extraLarge, "单列投影不改写保存的2×3偏好")
    let expandedExtraLarge = DeviceControlCenterLayoutEngine.frames(items: [extraLargeItem], availableWidth: 818)[0]
    checkEqual(expandedExtraLarge.height, responsiveGrid.rowHeight * 3 + responsiveGrid.spacing * 2,
               "恢复宽窗后2×3重新显示三行高度")
    for invalid in [Double.nan, .infinity, -1, 0] {
        let frames = DeviceControlCenterLayoutEngine.frames(items: items, availableWidth: invalid, spacing: .nan)
        check(frames.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite },
              "窗口过渡的无效尺寸不会产生非有限frame")
    }

    // Five-column regression from the reported dashboard: media / Pico / pocket
    // display / keyboard occupy row zero; tall cards divide row one into holes.
    // The next wide card cannot fit them, but later 1×1 cards must backfill them.
    let fiveColumnWidth = 1292.0
    let fiveGrid = DeviceControlCenterLayoutEngine.grid(availableWidth: fiveColumnWidth)
    checkEqual(fiveGrid.columnCount, 5, "截图回归使用五列紧凑网格")
    let screenshotItems = [
        DeviceControlCenterLayoutItem(id: "media", size: .init(columnSpan: 2, rowSpan: 1)),
        DeviceControlCenterLayoutItem(id: "pico", size: .init(columnSpan: 1, rowSpan: 2)),
        DeviceControlCenterLayoutItem(id: "pocket"),
        DeviceControlCenterLayoutItem(id: "keyboard", size: .init(columnSpan: 1, rowSpan: 2)),
        DeviceControlCenterLayoutItem(id: "m5"),
        DeviceControlCenterLayoutItem(id: "wide", size: .init(columnSpan: 2, rowSpan: 1)),
        DeviceControlCenterLayoutItem(id: "printer-a"),
        DeviceControlCenterLayoutItem(id: "printer-b")
    ]
    let savedScreenshotItems = screenshotItems
    let screenshotFrames = DeviceControlCenterLayoutEngine.frames(items: screenshotItems, availableWidth: fiveColumnWidth)
    let screenshotByID = Dictionary(uniqueKeysWithValues: screenshotFrames.map { ($0.id, $0) })
    func cell(_ frame: DeviceControlCenterLayoutFrame) -> [Int] {
        [Int((frame.y / (fiveGrid.rowHeight + fiveGrid.spacing)).rounded()),
         Int((frame.x / (fiveGrid.columnWidth + fiveGrid.spacing)).rounded())]
    }
    checkEqual(cell(screenshotByID["media"]!), [0, 0], "截图媒体卡占首行前两格")
    checkEqual(cell(screenshotByID["pico"]!), [0, 2], "Pico高卡保留在第三列")
    checkEqual(cell(screenshotByID["pocket"]!), [0, 3], "口袋先知保留在第四列")
    checkEqual(cell(screenshotByID["keyboard"]!), [0, 4], "键盘高卡保留在第五列")
    checkEqual(cell(screenshotByID["m5"]!), [1, 0], "M5按保存顺序占用下一行首个可放位置")
    checkEqual(cell(screenshotByID["wide"]!), [2, 0], "宽卡不能占单格空洞，继续寻找完整两格")
    checkEqual(cell(screenshotByID["printer-a"]!), [1, 1], "后续打印机回扫填入宽卡跳过的单格")
    checkEqual(cell(screenshotByID["printer-b"]!), [1, 3], "后续小卡填入口袋先知下方原先不可用的空洞")
    checkEqual(screenshotItems, savedScreenshotItems, "密集投影不改保存的顺序或尺寸")
    checkEqual(screenshotFrames.map(\.id), screenshotItems.map(\.id), "物理补洞后逻辑序列仍保持原样")
    check(screenshotByID["printer-b"]!.y < screenshotByID["wide"]!.y,
          "补洞允许后续小卡在视觉上高于前面无法放入的宽卡")
    assertGrid(screenshotItems, width: fiveColumnWidth)
    let extraTallScreenshot = screenshotItems.map { item in
        item.id == "wide" ? DeviceControlCenterLayoutItem(id: item.id, size: extraLarge) : item
    }
    let tallFrames = DeviceControlCenterLayoutEngine.frames(items: extraTallScreenshot, availableWidth: fiveColumnWidth)
    checkEqual(cell(tallFrames.first { $0.id == "printer-b" }!), [1, 3],
               "2×3大卡跳过的口袋先知下方空洞仍被后续单格补齐")
    assertGrid(extraTallScreenshot, width: fiveColumnWidth)
    let extraLargeDropIndex = DeviceControlCenterLayoutEngine.insertionIndex(for: "wide",
        at: CGPoint(x: fiveGrid.columnWidth / 2, y: fiveGrid.rowHeight / 2),
        items: extraTallScreenshot, availableWidth: fiveColumnWidth)
    checkEqual(extraLargeDropIndex, 0, "2×3大卡本身可拖到首格，按移除后的序列返回索引")
    var movedExtraLarge = extraTallScreenshot.filter { $0.id != "wide" }
    movedExtraLarge.insert(extraTallScreenshot.first { $0.id == "wide" }!, at: extraLargeDropIndex!)
    let movedExtraLargeFrame = DeviceControlCenterLayoutEngine.frames(items: movedExtraLarge,
        availableWidth: fiveColumnWidth).first { $0.id == "wide" }!
    checkEqual(cell(movedExtraLargeFrame), [0, 0], "2×3实际拖动结果落在目标首格")
    checkEqual(movedExtraLargeFrame.height, fiveGrid.rowHeight * 3 + fiveGrid.spacing * 2,
               "2×3拖放不缩短大卡高度")
    checkEqual(movedExtraLarge.filter { $0.id != "wide" }, extraTallScreenshot.filter { $0.id != "wide" },
               "2×3拖放保留其余卡片顺序和尺寸")
    assertGrid(movedExtraLarge, width: fiveColumnWidth)

    // This empty cell is reachable by sequence insertion: moving the first 1×1
    // behind the four preceding cards places it in the uncovered row-two cell.
    let holeDropItems = [
        DeviceControlCenterLayoutItem(id: "dragged"),
        DeviceControlCenterLayoutItem(id: "wide-a", size: .init(columnSpan: 2, rowSpan: 1)),
        DeviceControlCenterLayoutItem(id: "square", size: maximum),
        DeviceControlCenterLayoutItem(id: "wide-b", size: .init(columnSpan: 2, rowSpan: 1)),
        DeviceControlCenterLayoutItem(id: "tall", size: .init(columnSpan: 1, rowSpan: 2))
    ]
    let holePoint = CGPoint(x: fiveGrid.columnWidth / 2,
                           y: 2 * (fiveGrid.rowHeight + fiveGrid.spacing) + fiveGrid.rowHeight / 2)
    let beforeDropFrames = DeviceControlCenterLayoutEngine.frames(items: holeDropItems, availableWidth: fiveColumnWidth)
    check(!beforeDropFrames.contains { $0.rect.contains(holePoint) }, "拖放目标确实是空网格，不依赖邻近卡片中心")
    let holeIndex = DeviceControlCenterLayoutEngine.insertionIndex(for: "dragged", at: holePoint,
        items: holeDropItems, availableWidth: fiveColumnWidth)
    checkEqual(holeIndex, 4, "空格命中返回移除拖动卡后的正确插入索引")
    var holeLayout = DeviceControlCenterLayout(cardSizes: Dictionary(uniqueKeysWithValues: holeDropItems.map { ($0.id, $0.size) }),
                                               cardOrder: holeDropItems.map(\.id))
    let holeSizes = holeLayout.cardSizes
    check(holeLayout.move("dragged", to: holeIndex!, availableIDs: holeDropItems.map(\.id)), "空格目标可以通过普通顺序移动保存")
    checkEqual(holeLayout.cardSizes, holeSizes, "拖入空格不改变任何卡片尺寸")
    let droppedItems = holeLayout.orderedIDs(for: holeDropItems.map(\.id)).map {
        DeviceControlCenterLayoutItem(id: $0, size: holeLayout.size(for: $0))
    }
    let droppedFrames = DeviceControlCenterLayoutEngine.frames(items: droppedItems, availableWidth: fiveColumnWidth)
    checkEqual(cell(droppedFrames.first { $0.id == "dragged" }!), [2, 0], "拖入后卡片实际落在选中的空格")
    checkEqual(holeLayout.orderedIDs(for: holeDropItems.map(\.id)).filter { $0 != "dragged" },
               holeDropItems.map(\.id).filter { $0 != "dragged" }, "拖放不打乱其余卡片相对顺序")
    assertGrid(droppedItems, width: fiveColumnWidth)
    checkEqual(DeviceControlCenterLayoutEngine.insertionIndex(for: "dragged", at: holePoint,
        items: droppedItems, availableWidth: fiveColumnWidth), 4, "相同位置再次拖放保留原索引，不引起配置抖动")
    var extraTallDrop = holeDropItems
    extraTallDrop[2] = .init(id: "square", size: extraLarge)
    let extraTallDropIndex = DeviceControlCenterLayoutEngine.insertionIndex(for: "dragged", at: holePoint,
        items: extraTallDrop, availableWidth: fiveColumnWidth)!
    let extraTallDragged = extraTallDrop.removeFirst()
    extraTallDrop.insert(extraTallDragged, at: extraTallDropIndex)
    checkEqual(cell(DeviceControlCenterLayoutEngine.frames(items: extraTallDrop, availableWidth: fiveColumnWidth)
        .first { $0.id == "dragged" }!), [2, 0], "含2×3大卡时拖入同一空格仍按实际可达位置求解")
    assertGrid(extraTallDrop, width: fiveColumnWidth)
    let unavailableHole = CGPoint(x: 3 * (fiveGrid.columnWidth + fiveGrid.spacing) + fiveGrid.columnWidth / 2,
                                  y: fiveGrid.rowHeight + fiveGrid.spacing + fiveGrid.rowHeight / 2)
    let shortScreenshot = Array(screenshotItems.prefix(5))
    let nearestIndex = DeviceControlCenterLayoutEngine.insertionIndex(for: "m5", at: unavailableHole,
        items: shortScreenshot, availableWidth: fiveColumnWidth)
    checkEqual(nearestIndex, 2, "纯顺序无法到达的孤立空格选最近合法位置，不伪造自由坐标")
    for invalid in [CGPoint(x: Double.nan, y: 0), CGPoint(x: 0, y: Double.infinity)] {
        checkEqual(DeviceControlCenterLayoutEngine.insertionIndex(for: "dragged", at: invalid,
            items: holeDropItems, availableWidth: fiveColumnWidth), nil, "非法指针坐标不产生拖放索引")
    }
    checkEqual(DeviceControlCenterLayoutEngine.insertionIndex(for: "missing", at: .zero,
        items: holeDropItems, availableWidth: fiveColumnWidth), nil, "已删除的拖动身份不能创建新卡片")
    checkEqual(DeviceControlCenterLayoutEngine.insertionIndex(for: "dragged", at: .zero,
        items: [.init(id: "dragged")], availableWidth: 244), 0, "跨组追加拖动卡后，空分组接受索引0")
    checkEqual(DeviceControlCenterLayoutEngine.insertionIndex(for: "dragged", at: holePoint,
        items: holeDropItems + [.init(id: ""), holeDropItems[0]], availableWidth: fiveColumnWidth), holeIndex,
        "空或重复身份与真实排布一致，不能偏移拖放索引")
    for extremePoint in [CGPoint(x: -Double.greatestFiniteMagnitude, y: -Double.greatestFiniteMagnitude),
                         CGPoint(x: Double.greatestFiniteMagnitude, y: Double.greatestFiniteMagnitude)] {
        let index = DeviceControlCenterLayoutEngine.insertionIndex(for: "dragged", at: extremePoint,
            items: holeDropItems, availableWidth: fiveColumnWidth)
        check(index.map { (0..<holeDropItems.count).contains($0) } ?? false,
              "极大但有限的指针坐标不会溢出，仍返回合法序列位置")
    }
    for width in [244.0, 506, fiveColumnWidth, 1920] {
        let grid = DeviceControlCenterLayoutEngine.grid(availableWidth: width)
        let frames = DeviceControlCenterLayoutEngine.frames(items: mixed, availableWidth: width)
        for (index, frame) in frames.enumerated() {
            let unchangedPoint = CGPoint(x: frame.x + grid.columnWidth / 2,
                                         y: frame.y + grid.rowHeight / 2)
            checkEqual(DeviceControlCenterLayoutEngine.insertionIndex(for: frame.id, at: unchangedPoint,
                items: mixed, availableWidth: width), index,
                "五种尺寸的左上目标格未改变时保留已有索引，宽窄切换不产生拖放抖动")
        }
        for dragIndex in [0, 1, 4, 12, 24] {
            let dragged = mixed[dragIndex]
            let others = mixed.filter { $0.id != dragged.id }
            for target in [(0, 0), (2, max(grid.columnCount - 2, 0)), (5, 0)] {
                let point = CGPoint(x: Double(target.1) * (grid.columnWidth + grid.spacing) + grid.columnWidth / 2,
                                    y: Double(target.0) * (grid.rowHeight + grid.spacing) + grid.rowHeight / 2)
                // Oracle: actually repack every possible insertion, independent
                // of the prefix optimization used by the drag resolver.
                let expected = (0...others.count).min { lhs, rhs in
                    func score(_ index: Int) -> (Double, Int) {
                        var sequence = others; sequence.insert(dragged, at: index)
                        let frame = DeviceControlCenterLayoutEngine.frames(items: sequence, availableWidth: width)
                            .first { $0.id == dragged.id }!
                        let dx = frame.x / (grid.columnWidth + grid.spacing) - Double(target.1)
                        let dy = frame.y / (grid.rowHeight + grid.spacing) - Double(target.0)
                        return (dx * dx + dy * dy, abs(index - dragIndex))
                    }
                    let a = score(lhs), b = score(rhs)
                    return a.0 < b.0 - 0.000_001 || (abs(a.0 - b.0) <= 0.000_001 && a.1 < b.1)
                }
                checkEqual(DeviceControlCenterLayoutEngine.insertionIndex(for: dragged.id, at: point,
                    items: mixed, availableWidth: width), expected,
                    "拖放前缀算法与逐个实际重排的最近合法格位一致，包含2×3和窄窗")
            }
        }
    }

    layout.resetSize(for: device)
    checkEqual(layout.size(for: device), defaults, "单卡尺寸可还原默认")
    checkEqual(layout.size(for: source).columnSpan, 2, "单卡重置保留其他卡的网格跨度")
    layout.resetOrder()
    checkEqual(layout.orderedIDs(for: all), all, "单独重置顺序回到现有默认顺序")
    layout.reset()
    checkEqual(layout, DeviceControlCenterLayout(), "整页重置同时清除排序和尺寸")
}
