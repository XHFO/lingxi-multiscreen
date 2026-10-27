import Foundation
import LinxDisplayCore

/// A successful request proves both the current website and the current draft credential.
/// Keeping only a snapshot would not detect a Token changed after navigating back.
struct CloudflareSourceValidationProof {
    private let configuration: CloudflareAnalyticsSettings
    private let credentialRevision: UUID

    init(configuration: CloudflareAnalyticsSettings, credentialRevision: UUID) {
        self.configuration = CloudflareSourceDraftPolicy.normalized(configuration)
        self.credentialRevision = credentialRevision
    }

    func matches(_ configuration: CloudflareAnalyticsSettings, credentialRevision: UUID) -> Bool {
        self.configuration == CloudflareSourceDraftPolicy.normalized(configuration)
            && self.credentialRevision == credentialRevision
    }
}

/// Side-effect-free draft validation. A guide visit or cancelled draft never saves credentials.
enum CloudflareSourceDraftPolicy {
    static func normalized(_ configuration: CloudflareAnalyticsSettings) -> CloudflareAnalyticsSettings {
        var draft = configuration
        draft.zoneID = draft.zoneID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        draft.zoneName = draft.zoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.hostname = draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return draft
    }

    static func canReadSites(token: String, retainingCredential: Bool) -> Bool {
        if retainingCredential { return true }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count < 4096
            && value.allSatisfy { $0.isASCII && !$0.isWhitespace && !$0.isNewline }
    }

    static func canFinish(name: String, configuration: CloudflareAnalyticsSettings,
                          snapshot: CloudflareAnalyticsSnapshot?, validation: CloudflareSourceValidationProof?,
                          credentialRevision: UUID) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && normalized(configuration).isValid && snapshot?.matches(normalized(configuration)) == true
            && validation?.matches(configuration, credentialRevision: credentialRevision) == true
    }
}

enum CloudflareSourceCommitError: LocalizedError {
    case credentialSave, sourceMissing
    var errorDescription: String? {
        switch self {
        case .credentialSave: return "Token 无法保存到本机加密凭据，请检查输入或磁盘权限后重试。"
        case .sourceMissing: return "此数据源已被移除，请取消后重新添加。"
        }
    }
}

/// Only the final wizard action enters this transaction. Injected functions keep tests away from the sealed store.
enum CloudflareSourceCredentialTransaction {
    static func commit(replacementToken: String?, credentialID: UUID, previousCredentialID: UUID?,
                       saveSecret: (String, UUID) -> Bool,
                       persistSource: () -> Bool,
                       credentialIsReferenced: (UUID) -> Bool) throws {
        if let replacementToken, !saveSecret(replacementToken, credentialID) {
            throw CloudflareSourceCommitError.credentialSave
        }
        guard persistSource() else {
            if replacementToken != nil { _ = saveSecret("", credentialID) }
            throw CloudflareSourceCommitError.sourceMissing
        }
        if replacementToken != nil, let previousCredentialID,
           previousCredentialID != credentialID, !credentialIsReferenced(previousCredentialID) {
            _ = saveSecret("", previousCredentialID)
        }
    }
}
