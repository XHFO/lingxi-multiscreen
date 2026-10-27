import Foundation

@main struct PowerStatusTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool) { precondition(value); checks += 1 }
        func power(_ known: Bool, _ charging: Bool, _ external: Bool, _ battery: Int = 86) -> [String: Any] {
            ["known": known, "charging": charging, "external_power": external, "battery_percent": battery, "revision": 7]
        }
        let canvas: [String: Any] = ["supported": true, "width": 684, "height": 1216, "formats": ["image/bmp"], "max_bytes": 420000]
        let base: [String: Any] = ["protocol": 1, "canvas": canvas]
        func caps(_ report: Any? = nil) throws -> ReadPicoCapabilities {
            var body = base; body["power"] = report
            return try JSONDecoder().decode(ReadPicoCapabilities.self, from: JSONSerialization.data(withJSONObject: body))
        }
        let startBase: [String: Any] = ["device": "read-pico", "route": 0, "storage_busy": false, "mounted": true, "read_verified": true, "write_verified": true]
        let boardBase: [String: Any] = ["usb_board": true, "protocol": 1, "gray_levels": 16, "max_bytes": 420000, "task": "", "state": "idle"]
        func line(_ base: [String: Any], _ report: Any? = nil) throws -> String {
            var object = base; object["power"] = report
            return "RPICO " + String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\r\n"
        }
        check(try caps().power == nil)
        for fixture in [power(true, true, true), power(true, false, true), power(true, false, false), power(false, false, false, -1)] {
            let decoded = try caps(fixture).power!
            check(decoded.known == fixture["known"] as! Bool)
            check(decoded.charging == fixture["charging"] as! Bool)
            check(decoded.externalPower == fixture["external_power"] as! Bool)
            check(decoded.batteryPercent == fixture["battery_percent"] as! Int)
            check(decoded.revision == 7)
            check(try ReadPicoUSBTransferClient.parseStatus(line(startBase, fixture)).power == decoded)
            check(try ReadPicoUSBBoardStatus(line: line(boardBase, fixture)).power == decoded)
        }
        var malformed: [Any] = [power(true, true, false), power(false, true, true), power(false, false, true), power(true, false, false, 101), power(true, false, false, -2), "charging", NSNull()]
        for (key, value) in [("known", 1 as Any), ("revision", true as Any), ("revision", -1 as Any), ("revision", 4_294_967_296 as Any), ("battery_percent", 1.5 as Any), ("charging", "true" as Any)] {
            var bad = power(true, true, true); bad[key] = value; malformed.append(bad)
        }
        for fixture in malformed {
            check(try caps(fixture).power == nil)
            check(try ReadPicoUSBTransferClient.parseStatus(line(startBase, fixture)).power == nil)
            check(try ReadPicoUSBBoardStatus(line: line(boardBase, fixture)).power == nil)
        }
        check(try ReadPicoUSBTransferClient.parseStatus(line(startBase)).power == nil)
        check(try ReadPicoUSBBoardStatus(line: line(boardBase)).power == nil)
        let unsafe = ReadPicoPowerStatus(known: true, charging: true, batteryPercent: 50, revision: 1, externalPower: false)
        check(!unsafe.known && !unsafe.charging && !unsafe.externalPower)
        let unknown = ReadPicoPowerStatus(known: false, charging: true, batteryPercent: 50, revision: 1, externalPower: true)
        check(!unknown.known && !unknown.charging && !unknown.externalPower)
        let badBattery = ReadPicoPowerStatus(known: true, charging: true, batteryPercent: 101, revision: 1, externalPower: true)
        check(!badBattery.known && !badBattery.charging && !badBattery.externalPower && badBattery.batteryPercent == -1)
        print("PASS: \(checks) power telemetry checks; charging/full/battery/unknown, malformed optional reports and old firmware compatibility; no hardware or user data.")
    }
}
