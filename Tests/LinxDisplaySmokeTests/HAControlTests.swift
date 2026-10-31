import Foundation
import LinxDisplayCore

/// Home Assistant 灯光、风扇、空调与温湿度传感器的解析和控制映射回归。
func testHAControls() throws {
    func entity(_ json: String) throws -> HAEntity {
        try HomeAssistantClient.parseState(data: Data(json.utf8))
    }

    let light = try entity("""
    {"entity_id":"light.living_room","state":"on","last_changed":"2026-10-31T10:00:00+08:00",
     "attributes":{"friendly_name":"客厅灯","brightness":128,
       "supported_color_modes":["brightness"],"icon":"mdi:lightbulb"}}
    """)
    checkEqual(light.domain, "light", "灯光实体域")
    check(light.isDimmableLight, "有亮度的灯应识别为可调光")
    checkEqual(light.brightness, 128, "灯光原始亮度")
    checkEqual(light.brightnessPercent, 50, "灯光亮度百分比")
    check(ControlCenterHAControlPolicy.isPowerOn(light), "开启的灯电源状态为开")
    let onoff = try entity("""
    {"entity_id":"light.plain","state":"on","attributes":{"friendly_name":"普通灯",
     "supported_color_modes":["onoff"]}}
    """)
    check(!onoff.isDimmableLight, "仅 onoff 的灯不显示亮度滑块")
    let lightCommand = ControlCenterHAControlPolicy.brightnessCommand(
        for: light, selectedEntityIDs: [light.entityId], expectedFingerprint: "fp",
        currentFingerprint: "fp", percent: 60)
    checkEqual(lightCommand?.service, "turn_on", "非零亮度调用 turn_on")
    checkEqual(lightCommand?.brightnessPercent, 60, "亮度参数")
    let lightOff = ControlCenterHAControlPolicy.brightnessCommand(
        for: light, selectedEntityIDs: [light.entityId], expectedFingerprint: "fp",
        currentFingerprint: "fp", percent: 0)
    checkEqual(lightOff?.service, "turn_off", "0% 亮度直接关灯")

    let fan = try entity("""
    {"entity_id":"fan.bedroom","state":"on","attributes":{"friendly_name":"卧室风扇",
     "percentage":60,"percentage_step":10}}
    """)
    check(fan.isSpeedFan, "风扇识别")
    checkEqual(fan.percentage, 60, "风扇百分比")
    let fanCommand = ControlCenterHAControlPolicy.fanCommand(
        for: fan, selectedEntityIDs: [fan.entityId], expectedFingerprint: "fp",
        currentFingerprint: "fp", percent: 80)
    checkEqual(fanCommand?.service, "set_percentage", "风扇调速服务")
    checkEqual(fanCommand?.percentage, 80, "风扇目标百分比")

    let climate = try entity("""
    {"entity_id":"climate.living","state":"heat","attributes":{"friendly_name":"客厅空调",
     "temperature":24.5,"current_temperature":23.0,"min_temp":16,"max_temp":30,
     "target_temp_step":0.5,"hvac_action":"heating","current_humidity":55}}
    """)
    check(climate.isClimate, "空调识别")
    check(ControlCenterHAControlPolicy.isPowerOn(climate), "制热中的空调视为电源开启")
    checkEqual(climate.targetTemperature, 24.5, "空调目标温度")
    checkEqual(climate.currentTemperature, 23, "空调室温")
    checkEqual(climate.currentHumidity, 55, "空调湿度")
    checkEqual(climate.hvacAction, "heating", "空调动作")
    let climateCommand = ControlCenterHAControlPolicy.climateTemperatureCommand(
        for: climate, selectedEntityIDs: [climate.entityId], expectedFingerprint: "fp",
        currentFingerprint: "fp", temperature: 40)
    checkEqual(climateCommand?.service, "set_temperature", "空调调温服务")
    checkEqual(climateCommand?.temperature, 30, "空调温度上限钳制")
    check(ControlCenterHAControlPolicy.isControllable(climate), "空调可控制")

    let temperature = try entity("""
    {"entity_id":"sensor.living_temperature","state":"23.4","attributes":{
     "friendly_name":"客厅温度","unit_of_measurement":"°C","device_class":"temperature"}}
    """)
    let humidity = try entity("""
    {"entity_id":"sensor.living_humidity","state":"55","attributes":{
     "friendly_name":"客厅湿度","unit_of_measurement":"%","device_class":"humidity"}}
    """)
    check(temperature.isClimateSensor, "温度传感器归入温湿度合集")
    check(humidity.isClimateSensor, "湿度传感器归入温湿度合集")
    check(!ControlCenterHAControlPolicy.isControllable(temperature), "温度传感器只读")

    let request = HomeAssistantClient.makeServiceRequest(
        server: "http://192.168.1.20:8123", token: "token",
        command: HAServiceCommand(domain: "climate", service: "set_temperature",
                                  entityID: "climate.living", temperature: 25.5))
    let body = try JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any]
    checkEqual(body?["entity_id"] as? String, "climate.living", "服务请求实体")
    checkEqual(body?["temperature"] as? Double, 25.5, "服务请求温度")

    let fanRequest = HomeAssistantClient.makeServiceRequest(
        server: "http://192.168.1.20:8123", token: "token",
        command: HAServiceCommand(domain: "fan", service: "set_percentage",
                                  entityID: "fan.bedroom", percentage: 70))
    let fanBody = try JSONSerialization.jsonObject(with: fanRequest?.httpBody ?? Data()) as? [String: Any]
    checkEqual(fanBody?["percentage"] as? Int, 70, "服务请求风扇百分比")

    let lightRequest = HomeAssistantClient.makeServiceRequest(
        server: "http://192.168.1.20:8123", token: "token",
        command: HAServiceCommand(domain: "light", service: "turn_on",
                                  entityID: "light.living_room", brightnessPercent: 65))
    let lightBody = try JSONSerialization.jsonObject(with: lightRequest?.httpBody ?? Data()) as? [String: Any]
    checkEqual(lightBody?["brightness_pct"] as? Int, 65, "服务请求亮度百分比")

    print("  Home Assistant 灯光/风扇/空调/温湿度通过")
}
