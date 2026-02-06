import Foundation
import Security

struct KeychainService {
    private let service = "oppy.huggingface.token"
    private let account = "default"

    func saveToken(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw NSError(domain: "Oppy", code: 2001, userInfo: [NSLocalizedDescriptionKey: "Could not encode token"])
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var createQuery = query
            createQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(createQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: "Oppy", code: Int(addStatus), userInfo: [NSLocalizedDescriptionKey: "Could not save token to Keychain"])
            }
            return
        }

        throw NSError(domain: "Oppy", code: Int(updateStatus), userInfo: [NSLocalizedDescriptionKey: "Could not update Keychain token"])
    }

    func readToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return "" }
        guard status == errSecSuccess else {
            throw NSError(domain: "Oppy", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not read token from Keychain"])
        }
        guard
            let data = item as? Data,
            let token = String(data: data, encoding: .utf8)
        else {
            throw NSError(domain: "Oppy", code: 2002, userInfo: [NSLocalizedDescriptionKey: "Invalid token in Keychain"])
        }
        return token
    }

    func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: "Oppy", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not delete Keychain token"])
        }
    }
}
