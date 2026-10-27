import Foundation

// Rendering uses an empty serial inventory and never opens an actual device.
public struct ESPSerialPort: Identifiable, Equatable, Hashable {
    public let path: String
    public var id: String { path }
    public var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
    public init(path: String) { self.path = path }
}
public enum ESP8266FirmwareFlasher {
    public static func discoverM5StickS3SerialPorts() -> [ESPSerialPort] { [] }
}
