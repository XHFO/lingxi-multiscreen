import Foundation
import CryptoKit

/// Installation-local credentials, separate from exportable settings.
/// The encryption key shares the private directory; this is not equivalent to
/// Keychain protection against other processes running as the same user.
public enum C6SecretStore {
  private static let lock = NSLock()
  private static var directory: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let folder = Bundle.main.bundleIdentifier == "com.lingxi.multiscreen.beta2" ? "LinxDisplayBeta2" : "LinxDisplay"
    return support.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("c6-credentials", isDirectory: true)
  }
  public static func read(deviceID: UUID, allowUserInteraction: Bool = false) -> String {
    read(deviceID: deviceID, directory: directory)
  }
  public static func save(_ value: String, deviceID: UUID, allowUserInteraction: Bool = false) -> Bool {
    save(value, deviceID: deviceID, directory: directory)
  }
  private static func prepare(_ directory: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: directory.path) {
      guard try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteNoPermission) }
    } else {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    var target = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
    try target.setResourceValues(values)
  }
  private static func key(_ directory: URL, create: Bool) throws -> SymmetricKey {
    let url = directory.appendingPathComponent("installation.key"), fm = FileManager.default
    if !fm.fileExists(atPath: url.path), create {
      let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
      do { try bytes.write(to: url, options: .withoutOverwriting) }
      catch { if !fm.fileExists(atPath: url.path) { throw error } }
    }
    guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadNoPermission) }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let bytes = try Data(contentsOf: url)
    guard bytes.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
    return SymmetricKey(data: bytes)
  }
  static func read(deviceID: UUID, directory: URL) -> String {
    lock.lock(); defer { lock.unlock() }
    let url = directory.appendingPathComponent(deviceID.uuidString + ".sealed"), fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return "" }
    do {
      try prepare(directory)
      guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { return "" }
      let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
      let bytes = try AES.GCM.open(box, using: key(directory, create: false), authenticating: Data(deviceID.uuidString.utf8))
      return String(data: bytes, encoding: .utf8) ?? ""
    } catch { return "" }
  }
  static func save(_ value: String, deviceID: UUID, directory: URL) -> Bool {
    lock.lock(); defer { lock.unlock() }
    let url = directory.appendingPathComponent(deviceID.uuidString + ".sealed"), fm = FileManager.default
    do {
      if value.isEmpty {
        if fm.fileExists(atPath: url.path) {
          guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { return false }
          try fm.removeItem(at: url)
        }
        return true
      }
      try prepare(directory)
      if fm.fileExists(atPath: url.path) {
        guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { return false }
      }
      let box = try AES.GCM.seal(Data(value.utf8), using: key(directory, create: true), authenticating: Data(deviceID.uuidString.utf8))
      guard let bytes = box.combined else { return false }
      try bytes.write(to: url, options: .atomic)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return true
    } catch { return false }
  }
}
