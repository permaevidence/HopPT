import Foundation

struct EndpointConfig: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var apiBase: String = ""
    var selectedModels: [String] = []
    var preferredModel: String? = nil

    // API key is NOT part of Codable - stored separately in Keychain
    var apiKey: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, apiBase, selectedModels, preferredModel
        // apiKey intentionally excluded
    }

    // Keychain key for this endpoint's API key
    var keychainKey: String { "endpoint_apiKey_\(id.uuidString)" }

    // Load API key from Keychain
    mutating func loadApiKeyFromKeychain() {
        apiKey = KeychainHelper.load(for: keychainKey) ?? ""
    }

    // Save API key to Keychain
    func saveApiKeyToKeychain() {
        if apiKey.isEmpty {
            KeychainHelper.delete(for: keychainKey)
        } else {
            KeychainHelper.save(apiKey, for: keychainKey)
        }
    }

    // Delete API key from Keychain (call when deleting endpoint)
    func deleteApiKeyFromKeychain() {
        KeychainHelper.delete(for: keychainKey)
    }
}
