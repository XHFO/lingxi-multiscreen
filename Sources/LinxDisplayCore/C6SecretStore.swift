import Foundation

/// Installation-local C6 device credentials (AES-GCM files under Application Support).
/// Does not use the system Keychain; never prompts for Keychain unlock.
public enum C6SecretStore {
  private static let subdirectory = "c6-credentials"

  public static func read(deviceID: UUID, allowUserInteraction: Bool = false) -> String {
    _ = allowUserInteraction
    return SealedCredentialStore.read(account: deviceID.uuidString, subdirectory: subdirectory)
  }

  public static func save(_ value: String, deviceID: UUID, allowUserInteraction: Bool = false) -> Bool {
    _ = allowUserInteraction
    return SealedCredentialStore.save(value, account: deviceID.uuidString, subdirectory: subdirectory)
  }

  /// Test / tooling entry that targets an explicit directory (same layout as production).
  static func read(deviceID: UUID, directory: URL) -> String {
    SealedCredentialStore.read(account: deviceID.uuidString, directory: directory)
  }

  static func save(_ value: String, deviceID: UUID, directory: URL) -> Bool {
    SealedCredentialStore.save(value, account: deviceID.uuidString, directory: directory)
  }
}
