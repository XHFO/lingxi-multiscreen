import Foundation

@main struct PayloadTests {
    static func main() throws {
        let fixture: [String: Any] = [
            "serial": "FORM-FIXTURE", "name": "Studio Form 4", "alias": "Workshop", "user_facing_name": "Form 4", "is_connected": true,
            "user": ["email": "must-not-cross@example.invalid"], "group": ["name": "private"],
            "token": "must-not-cross", "printer_status": [
                "status": "PRINTING", "last_pinged_at": "2026-11-23T00:00:00Z",
                "access_token": "must-not-cross", "current_print_run": [
                    "id": 17, "guid": "job-guid-17", "name": "Fixture job", "status": "PRINTING", "currently_printing_layer": 20,
                    "layer_count": 100, "user": ["email": "must-not-cross"], "password": "must-not-cross",
                    "print_thumbnail": ["thumbnail": "https://files.formlabs.com/test.png", "token": "must-not-cross"]
                ]
            ], "cartridge_status": [["cartridge": ["serial": "C1", "display_name": "Clear", "user": "must-not-cross"]]]
        ]
        let data = FormlabsDashboardPayload.sanitized(fixture, serial: "FORM-FIXTURE")!
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(object["serial"] as? String == "FORM-FIXTURE")
        precondition(object["alias"] as? String == "Workshop" && object["user_facing_name"] as? String == "Form 4")
        let run = (object["printer_status"] as! [String: Any])["current_print_run"] as! [String: Any]
        precondition(run["guid"] as? String == "job-guid-17")
        precondition(!String(decoding: data, as: UTF8.self).contains("must-not-cross"))
        precondition(object["user"] == nil && object["group"] == nil && object["token"] == nil)
        precondition(FormlabsDashboardPayload.sanitized(fixture, serial: "OTHER") == nil)
        var nullFixture = fixture; nullFixture["printer_status"] = ["status": "UNKNOWN", "current_print_run": NSNull()]
        let unknown = try JSONSerialization.jsonObject(with: FormlabsDashboardPayload.sanitized(nullFixture, serial: "FORM-FIXTURE")!) as! [String: Any]
        precondition((unknown["printer_status"] as! [String: Any])["current_print_run"] is NSNull)
        var long = fixture; long["name"] = String(repeating: "x", count: 10_000)
        let bounded = try JSONSerialization.jsonObject(with: FormlabsDashboardPayload.sanitized(long, serial: "FORM-FIXTURE")!) as! [String: Any]
        precondition((bounded["name"] as! String).count == 2048)
        if CommandLine.arguments.count == 2 {
            try FormlabsDashboardPayload.observationScript(serial: "FORM-FIXTURE").write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        }
        print("Dashboard payload: target serial, nested printer-only allowlist, no account/credential fields, null preservation and bounded strings passed")
    }
}
