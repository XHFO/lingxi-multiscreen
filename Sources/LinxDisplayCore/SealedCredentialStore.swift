import Foundation
import CryptoKit

/// Installation-local AES-GCM credential files under Application Support.
/// Same pattern as the former C6-only store: no SecItem / Keychain APIs,
/// so macOS never prompts for Keychain unlock.
enum SealedCredentialStore {
    private static let lock = NSLock()

    static var supportFolderName: String {
        Bundle.main.bundleIdentifier == "com.lingxi.multiscreen.beta2" ? "LinxDisplayBeta2" : "LinxDisplay"
    }

    static func directory(_ subdirectory: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent(supportFolderName, isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true)
    }

    static func read(account: String, subdirectory: String) -> String {
        read(account: account, directory: directory(subdirectory))
    }

    @discardableResult
    static func save(_ value: String, account: String, subdirectory: String) -> Bool {
        save(value, account: account, directory: directory(subdirectory))
    }

    private static func prepare(_ directory: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            guard try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var target = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }

    private static func key(_ directory: URL, create: Bool) throws -> SymmetricKey {
        let url = directory.appendingPathComponent("installation.key")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path), create {
            let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            do { try bytes.write(to: url, options: .withoutOverwriting) }
            catch { if !fm.fileExists(atPath: url.path) { throw error } }
        }
        guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadNoPermission)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let bytes = try Data(contentsOf: url)
        guard bytes.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        return SymmetricKey(data: bytes)
    }

    static func read(account: String, directory: URL) -> String {
        lock.lock(); defer { lock.unlock() }
        let safe = account.replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent(safe + ".sealed")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return "" }
        do {
            try prepare(directory)
            guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else { return "" }
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
            let bytes = try AES.GCM.open(box, using: key(directory, create: false), authenticating: Data(account.utf8))
            return String(data: bytes, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    static func save(_ value: String, account: String, directory: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let safe = account.replacingOccurrences(of: "/", with: "_")
        let url = directory.appendingPathComponent(safe + ".sealed")
        let fm = FileManager.default
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
            let box = try AES.GCM.seal(Data(value.utf8), using: key(directory, create: true), authenticating: Data(account.utf8))
            guard let bytes = box.combined else { return false }
            try bytes.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
