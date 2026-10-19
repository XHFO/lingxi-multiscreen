import Foundation
import LinxDisplayCore

func testC6MergedCards() throws {
    var config = C6StandaloneConfiguration()
    config.enabled = true; config.weather = true; config.weatherCity = "测试城市"
    config.ha.enabled = true; config.ha.host = "192.168.1.10"
    config.ha.entities = (0..<6).map { C6HAEntity(id: "sensor.test_\($0)", name: "实体 \($0)") }
    var bambu = C6PrinterConfiguration()
    bambu.serial = "SAME"; bambu.name = "工作室打印机"; bambu.host = "192.168.1.20"; bambu.trustLAN = true
    var form = C6PrinterConfiguration()
    form.serial = "SAME"; form.name = bambu.name; form.sourceFormlabs = true; form.formClientID = "test-client"
    config.printers = [bambu, form]
    let bambuKey = C6MergedCardPolicy.printerIdentity(bambu, configuration: config)
    let formKey = C6MergedCardPolicy.printerIdentity(form, configuration: config)
    let native = C6MergedCardPolicy.nativeCards(configuration: config,
        printerDisplayModes: [bambuKey: .bambuLab, formKey: .formlabs])
    checkEqual(native.filter { $0.kind == "ha" }.count, 2, "Six entities produce two exact native groups")
    checkEqual(native.filter { $0.kind == "overview" }.count, 1, "Two enabled native printers add one overview")
    checkEqual(native.filter { $0.kind == "printer" }.map(\.title), [bambu.name, form.name], "Native names use configured user names")
    check(Set(native.map(\.id)).count == native.count, "Same serial and title across brands have unique native IDs")
    check(native.allSatisfy { $0.headers["X-Lingxi-Native"] == "1" }, "Every native descriptor uses explicit-native handoff")
    let haCards = native.filter { $0.kind == "ha" }
    checkEqual(haCards.map { $0.headers["X-Lingxi-Group"] }, ["0", "1"], "HA group selection is explicit, not a hidden cyclic side effect")
    checkEqual(haCards[0].headers["X-Lingxi-Origin"], "192.168.1.10:8123:0", "HA origin header matches firmware contract")
    let printers = native.filter { $0.kind == "printer" }
    checkEqual(printers[0].headers["X-Lingxi-Origin"], bambu.host, "MQTT origin header uses the configured printer host")
    checkEqual(printers[1].headers["X-Lingxi-Origin"], form.formClientID, "Formlabs origin header uses the cloud client identity")
    var renamed = config; renamed.printers.reverse(); renamed.printers[0].name = "重新命名"
    let reordered = C6MergedCardPolicy.nativeCards(configuration: renamed)
    checkEqual(Set(reordered.filter { $0.kind == "printer" }.map(\.id)), Set(printers.map(\.id)), "Native IDs survive printer reorder and rename")
    var changed = config; changed.printers[1].formClientID = "different-client"
    check(C6MergedCardPolicy.nativeCards(configuration: changed).filter { $0.kind == "printer" }[1].id != printers[1].id,
          "Changing a cloud account never reuses the prior native ID")
    changed = config; changed.printers[0].sourceHA = true; changed.printers[0].statusEntity = "sensor.print_status"
    check(C6MergedCardPolicy.nativeCards(configuration: changed).filter { $0.kind == "printer" }[0].id != printers[0].id,
          "Switching MQTT to HA never reuses the prior native ID")
    changed = config; changed.ha.host = "192.168.1.11"
    check(C6MergedCardPolicy.nativeCards(configuration: changed).filter { $0.kind == "ha" }[0].id != haCards[0].id,
          "HA origin isolates group identity even when entity IDs match")

    let modes: [DisplayMode] = [.nowPlaying, .aiMacClock, .weather, .homeAssistant, .bambuLab, .formlabs]
    var screen = AIMacScreenDeviceSettings(mode: .card,
        cardPanels: modes.map(\.rawValue), cardRotationModes: modes.map(\.rawValue), cardRotationEnabled: true)
    let independent = C6MergedCardPolicy.descriptors(settings: screen, configuration: config,
        softwareModes: modes, printerDisplayModes: [bambuKey: .bambuLab, formKey: .formlabs])
    checkEqual(independent.filter { $0.displayMode == .aiMacClock }.count, 1, "Clock has one native item, never a duplicate software frame")
    check(independent.first { $0.displayMode == .aiMacClock }?.nativeCard?.kind == "clock", "Migrated clock selects the local renderer")
    check(independent.contains { $0.displayMode == .weather && $0.nativeCard == nil }
          && independent.contains { $0.nativeCard?.kind == "weather" }, "Software-first exposes distinct software and local sources")
    check(independent.contains { $0.displayMode == .nowPlaying && $0.visible && $0.nativeCard == nil }, "Computer-only music survives native catalogue merge")
    check(C6MergedCardPolicy.rotationTargets(in: independent).contains(.native("clock"))
          && C6MergedCardPolicy.rotationTargets(in: independent).contains(.software(.nowPlaying)), "One playlist includes both local clock and software music")
    config.localFirst = true
    let preferred = C6MergedCardPolicy.descriptors(settings: screen, configuration: config,
        softwareModes: modes, printerDisplayModes: [bambuKey: .bambuLab, formKey: .formlabs])
    check(!preferred.contains { $0.displayMode == .weather && $0.nativeCard == nil }, "Native preference replaces only matching software weather")
    check(!preferred.contains { $0.displayMode == .bambuLab && $0.nativeCard == nil }, "Native preference replaces exact matched printer")
    check(preferred.contains { $0.displayMode == .nowPlaying && $0.nativeCard == nil }, "Native preference does not hide unsupported computer-only cards")
    screen.c6NativeCardPanels = []
    let hidden = C6MergedCardPolicy.descriptors(settings: screen, configuration: config, softwareModes: modes)
    check(hidden.filter { $0.nativeCard != nil }.allSatisfy { !$0.visible && !$0.participatesInRotation }, "Explicit empty native selections are not reset to firmware defaults")
    check(hidden.contains { $0.displayMode == .weather && $0.nativeCard == nil }, "Hidden native cards cannot veto software counterparts")
    screen.c6NativeCardPanels = ["clock", "diagnostics"]
    screen.c6NativeCardRotationIDs = ["clock"]
    screen.c6NativeCardID = "diagnostics"
    screen.c6MergedCardOrder = ["native:diagnostics", "software:\(DisplayMode.nowPlaying.rawValue)", "native:clock"]
    screen.c6LastSyncedInputKey = String(repeating: "a", count: 64)
    screen.c6LastSyncedSelection = config
    let ordered = C6MergedCardPolicy.descriptors(settings: screen, configuration: config, softwareModes: modes)
    checkEqual(Array(ordered.prefix(3).map(\.id)), screen.c6MergedCardOrder!, "Mixed native/software order is stable")
    check(!ordered.first { $0.id == "native:diagnostics" }!.participatesInRotation, "Visible native card need not rotate")
    let restored = try JSONDecoder().decode(AIMacScreenDeviceSettings.self, from: JSONEncoder().encode(screen))
    checkEqual(restored, screen, "Per-device mixed selection, display, rotation and order persist together")
    checkEqual(restored.c6LastSyncedSelection, config, "Resolved non-secret ownership checkpoint persists across software restart")
    let persistedCheckpoint = String(data: try JSONEncoder().encode(restored), encoding: .utf8)!
    check(!persistedCheckpoint.contains("haToken") && !persistedCheckpoint.contains("form_client_secret")
          && !persistedCheckpoint.contains("access_code\""), "Ownership checkpoint contains no source credentials")
    var otherScreen = AIMacScreenDeviceSettings(mode: .card, c6NativeCardPanels: [])
    otherScreen.c6NativeCardID = "clock"
    check(otherScreen.c6NativeCardPanels?.isEmpty == true && screen.c6NativeCardPanels?.count == 2,
          "Another screen's local visibility is not inherited or overwritten")
    var oldObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(screen)) as! [String: Any]
    for key in ["c6NativeCardID", "c6NativeCardPanels", "c6NativeCardRotationIDs", "c6MergedCardOrder", "smartRotationReturnC6NativeCardID",
                "c6LastSyncedInputKey", "c6LastSyncedSelection"] {
        oldObject.removeValue(forKey: key)
    }
    let old = try JSONDecoder().decode(AIMacScreenDeviceSettings.self, from: JSONSerialization.data(withJSONObject: oldObject))
    check(old.c6NativeCardPanels == nil && old.c6NativeCardRotationIDs == nil && old.c6MergedCardOrder == nil,
          "Missing fields remain nil for lossless firmware/legacy migration")
    check(old.c6LastSyncedInputKey == nil && old.c6LastSyncedSelection == nil, "Older profiles do not fabricate a first-sync ownership checkpoint")
    oldObject["c6LastSyncedInputKey"] = String(repeating: "b", count: 64)
    oldObject["c6LastSyncedSelection"] = ["schema_version": 999]
    let futureCheckpoint = try JSONDecoder().decode(AIMacScreenDeviceSettings.self, from: JSONSerialization.data(withJSONObject: oldObject))
    check(futureCheckpoint.c6LastSyncedInputKey == nil && futureCheckpoint.c6LastSyncedSelection == nil
          && futureCheckpoint.cardPanels == screen.cardPanels, "Unsupported optional checkpoint does not discard the user's device profile")
    var returnPoint = screen
    returnPoint.smartRotationReturnContentMode = .card
    returnPoint.smartRotationReturnCardModeRawValue = nil
    returnPoint.smartRotationReturnC6NativeCardID = printers[1].id
    returnPoint.clamp()
    checkEqual(returnPoint.smartRotationReturnC6NativeCardID, printers[1].id, "Native smart-rotation return survives without a software mode")
    returnPoint.smartRotationReturnContentMode = nil; returnPoint.clamp()
    check(returnPoint.smartRotationReturnC6NativeCardID == nil, "Consumed takeover clears the native return token")
    checkEqual(C6MergedCardPolicy.normalizedOrder(["native:clock", "native:clock", "missing"],
        availableIDs: ["native:clock", "native:weather"]), ["native:clock", "native:weather"], "Order removes duplicate/stale IDs and appends discovered cards")
    screen.c6NativeCardPanels = ["clock", "clock", "bad value", ""]
    screen.c6MergedCardOrder = ["native:clock", "native:clock", "invalid", "software:-1"]
    screen.clamp()
    checkEqual(screen.c6NativeCardPanels, ["clock"], "Native ID normalization rejects malformed persisted IDs")
    checkEqual(screen.c6MergedCardOrder, ["native:clock"], "Mixed order normalization removes malformed tokens")
    screen.c6LastSyncedInputKey = "not-a-digest"; screen.clamp()
    check(screen.c6LastSyncedInputKey == nil && screen.c6LastSyncedSelection == nil, "Malformed ownership digest cannot suppress initial synchronization")
    var duplicateRecord = bambu
    duplicateRecord.name = "重复记录不同名称"; duplicateRecord.enabled = false; duplicateRecord.rotate = false
    var duplicateConfig = config
    duplicateConfig.printers = [bambu, duplicateRecord]
    let badDecoded = try JSONDecoder().decode(C6StandaloneConfiguration.self, from: JSONEncoder().encode(duplicateConfig))
    check(!badDecoded.isValid, "Remote decoding alone does not validate duplicate native identities")
    let duplicateCards = C6MergedCardPolicy.nativeCards(configuration: badDecoded)
    let duplicatePrinters = duplicateCards.filter { $0.kind == "printer" }
    checkEqual(duplicatePrinters.count, 1, "Exact repeated native source identities are deduplicated before UI indexing")
    check(duplicatePrinters[0].title == bambu.name && duplicatePrinters[0].defaultVisible,
          "Duplicate records do not merge another record's name, visibility or rotation into the first")
    check(!duplicateCards.contains { $0.kind == "overview" }, "One real source duplicated in a malformed response cannot create multi-printer overview")
    let duplicateDescriptors = C6MergedCardPolicy.descriptors(settings: screen,
        configuration: badDecoded, softwareModes: [.nowPlaying, .nowPlaying, .aiMacClock, .aiMacClock])
    checkEqual(Set(duplicateDescriptors.map(\.id)).count, duplicateDescriptors.count,
               "Malformed native duplicates and repeated software modes cannot trap Dictionary initialization")
    var otherOrigin = bambu; otherOrigin.host = "192.168.1.21"; otherOrigin.name = "另一来源"; otherOrigin.rotate = false
    duplicateConfig.printers = [bambu, otherOrigin, form]
    let isolated = C6MergedCardPolicy.nativeCards(configuration: duplicateConfig).filter { $0.kind == "printer" }
    checkEqual(isolated.count, 3, "Same serial in distinct origins or brands never collapses into one native identity")
    checkEqual(Set(isolated.compactMap { $0.headers["X-Lingxi-Origin"] }),
               Set([bambu.host, otherOrigin.host, form.formClientID]), "Distinct native source headers stay attached to their own complete records")
    check(isolated[0].defaultVisible && !isolated[1].defaultVisible && isolated[2].defaultVisible,
          "Cross-origin visibility flags are not OR-merged")
    var oversized = config
    oversized.ha.entities = (0..<100).map { C6HAEntity(id: "sensor.excess_\($0)") }
    oversized.printers = (0..<20).map { index in var item = bambu; item.serial = "P\(index)"; return item }
    let bounded = C6MergedCardPolicy.nativeCards(configuration: oversized)
    checkEqual(bounded.filter { $0.kind == "ha" }.count, 2, "Malformed remote arrays cannot produce more HA pages than firmware capacity")
    checkEqual(bounded.filter { $0.kind == "printer" }.count, 3, "Malformed remote arrays cannot build an unbounded printer catalogue")
    var ambiguousSerial = bambu; ambiguousSerial.serial = "SAME|other-origin"
    var ambiguousSource = form; ambiguousSource.sourceHA = true
    var headerControl = form; headerControl.formClientID = "client\r\nX-Injected: invalid"
    oversized.printers = [ambiguousSerial, ambiguousSource, headerControl]
    check(C6MergedCardPolicy.nativeCards(configuration: oversized).allSatisfy { $0.kind != "printer" },
          "Unvalidated delimiters, ambiguous source flags and header-control input never become native printer requests")
    var missingOrigin = bambu; missingOrigin.host = ""
    oversized.printers = [missingOrigin]
    check(!C6MergedCardPolicy.nativeCards(configuration: oversized).contains { $0.kind == "printer" },
          "A missing local origin cannot reuse an otherwise valid serial identity")
    print("  C6 电脑/本地混合卡片通过")
}
