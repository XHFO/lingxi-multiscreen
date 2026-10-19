import Foundation

@main
struct NativeTransportContract {
    static func main() async throws {
        let client = C6StandaloneClient(testingBaseURL: URL(string: "http://" + CommandLine.arguments[1])!)
        let headers = ["X-Lingxi-Card": "printer", "X-Lingxi-Serial": "same-serial",
                       "X-Lingxi-Brand": "formlabs", "X-Lingxi-Source": "formlabs",
                       "X-Lingxi-Origin": "fixture-cloud-client", "X-Lingxi-Native": "1",
                       "Authorization": "must-not-forward", "Cookie": "must-not-forward"]
        for expected in [200, 204, 404] {
            let result = try await client.selectNativeCard(token: "1234abcd1234abcd", headers: headers)
            precondition(result == expected)
        }
        do {
            _ = try await client.selectNativeCard(token: "1234abcd1234abcd", headers: headers)
            preconditionFailure("401 must fail")
        } catch C6StandaloneError.unauthorized {}
        do {
            _ = try await client.selectNativeCard(token: "1234abcd1234abcd", headers: headers)
            preconditionFailure("500 must not be mistaken for fallback")
        } catch C6StandaloneError.response(500) {}
        do {
            _ = try await client.selectNativeCard(token: "invalid", headers: headers)
            preconditionFailure("Invalid credentials must not enter transport")
        } catch C6StandaloneError.unauthorized {}
        let members: [[String: String]] = [
            ["X-Lingxi-Card": "clock"],
            ["X-Lingxi-Card": "ha", "X-Lingxi-Group": "1", "X-Lingxi-Origin": "192.168.1.10:8123:0"],
            headers
        ]
        for member in members {
            let status = try await client.selectNativeCard(token: "1234abcd1234abcd", headers: member, explicitNative: true)
            precondition(status == 200)
        }
        print("C6 native Swift v2 transport: exact scoped headers, explicit opt-in, HA grouping, no body, 200/204/404 routing, 401/500 and invalid-token rejection passed")
    }
}
