//
//  CredentialStore.swift
//  TaskHubCore
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation
import LocalAuthentication
import Security

public enum CredentialStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput
    case unavailable
    case readFailed
    case saveFailed

    public var errorDescription: String? {
        switch self {
        case .invalidInput: "認証情報またはリポジトリ識別子の形式が不正です。"
        case .unavailable: "端末のロック解除後に認証情報へアクセスしてください。再起動後の初回ロック解除までは自動同期できません。"
        case .readFailed: "Keychainから認証情報を読み込めません。接続設定を確認してください。"
        case .saveFailed: "認証情報をKeychainに保存できません。端末の状態を確認してください。"
        }
    }
}

public enum CredentialStore {
    public static func read(for identity: String) throws -> String? {
        var query = try baseQuery(for: identity)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try requireSuccess(status, otherwise: .readFailed)
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8),
              (try? GitHubClient.validateToken(token)) != nil else { throw CredentialStoreError.readFailed }
        return token
    }

    public static func save(_ token: String, for identity: String) throws {
        let query = try baseQuery(for: identity)
        do { try GitHubClient.validateToken(token) }
        catch { throw CredentialStoreError.invalidInput }
        // Background refresh can read after first unlock; credentials never migrate to another device.
        let attributes: [CFString: Any] = [
            kSecValueData: Data(token.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        try requireSuccess(status, otherwise: .saveFailed)
    }

    private static func baseQuery(for identity: String) throws -> [CFString: Any] {
        guard (1...1024).contains(identity.utf8.count),
              !identity.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CredentialStoreError.invalidInput
        }
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecUseAuthenticationContext: context,
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "dev.taskhub.ios.github",
            kSecAttrAccount: identity,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true
        ]
    }

    private static func requireSuccess(_ status: OSStatus, otherwise error: CredentialStoreError) throws {
        guard status != errSecSuccess else { return }
        if status == errSecInteractionNotAllowed || status == errSecNotAvailable {
            throw CredentialStoreError.unavailable
        }
        throw error
    }
}
