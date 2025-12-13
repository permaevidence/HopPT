import Foundation
import SwiftUI
import Combine

final class AppSettings: ObservableObject {
    // --- Bridge fields used by the rest of the app (always reflect ACTIVE endpoint) ---
    @Published var apiBase: String = "" { didSet { UserDefaults.standard.set(apiBase, forKey: "apiBase") } }

    // API key now uses Keychain
    @Published var apiKey: String = "" {
        didSet {
            if apiKey.isEmpty {
                KeychainHelper.delete(for: "bridge_apiKey")
            } else {
                KeychainHelper.save(apiKey, for: "bridge_apiKey")
            }
            // Sync into active endpoint
            if let idx = endpoints.firstIndex(where: { $0.id == activeEndpointID }) {
                if endpoints[idx].apiKey != apiKey {
                    endpoints[idx].apiKey = apiKey
                    endpoints[idx].saveApiKeyToKeychain()
                }
            }
        }
    }

    @Published var model: String = "" {
        didSet {
            UserDefaults.standard.set(model, forKey: "model")
            if let idx = endpoints.firstIndex(where: { $0.id == activeEndpointID }) {
                if endpoints[idx].preferredModel != model {
                    endpoints[idx].preferredModel = model
                    saveEndpoints()
                }
            }
        }
    }

    @Published var selectedModels: [String] = [] {
        didSet {
            UserDefaults.standard.set(selectedModels, forKey: "selectedModels")
            ensureActiveModelIsValid()
            if let idx = endpoints.firstIndex(where: { $0.id == activeEndpointID }) {
                if endpoints[idx].selectedModels != selectedModels {
                    endpoints[idx].selectedModels = selectedModels
                    saveEndpoints()
                }
            }
        }
    }

    // --- Web search config (now using Keychain for API keys) ---
    @Published var serperApiKey: String = "" {
        didSet {
            if serperApiKey.isEmpty {
                KeychainHelper.delete(for: "serperApiKey")
            } else {
                KeychainHelper.save(serperApiKey, for: "serperApiKey")
            }
        }
    }

    @Published var jinaApiKey: String = "" {
        didSet {
            if jinaApiKey.isEmpty {
                KeychainHelper.delete(for: "jinaApiKey")
            } else {
                KeychainHelper.save(jinaApiKey, for: "jinaApiKey")
            }
        }
    }

    @Published private var scrapingModeStorage: String = "" { didSet { UserDefaults.standard.set(scrapingModeStorage, forKey: "scrapingMode") } }
    var scrapingMode: ScrapingMode {
        get { ScrapingMode(rawValue: scrapingModeStorage) ?? .localWebKit }
        set { scrapingModeStorage = newValue.rawValue }
    }

    // --- Multi-endpoint store ---
    @Published var endpoints: [EndpointConfig] = [] {
        didSet {
            saveEndpoints()
            syncActiveEndpointFields()
        }
    }

    @Published var activeEndpointID: UUID? = nil {
        didSet {
            UserDefaults.standard.set(activeEndpointID?.uuidString, forKey: "activeEndpointID")
            syncActiveEndpointFields()
        }
    }

    // TTS toggle
    @Published var ttsEnabled: Bool = false {
        didSet { UserDefaults.standard.set(ttsEnabled, forKey: "ttsEnabled") }
    }

    var activeEndpoint: EndpointConfig? {
        endpoints.first(where: { $0.id == activeEndpointID }) ?? endpoints.first
    }

    // --- Init with migration ---
    init() {
        let defaults = UserDefaults.standard

        // Old keys (for migration)
        let initialApiBase = defaults.string(forKey: "apiBase") ?? ""
        let initialModel = defaults.string(forKey: "model") ?? ""
        let initialScraping = defaults.string(forKey: "scrapingMode") ?? ScrapingMode.localWebKit.rawValue
        let initialSelected: [String] = (defaults.array(forKey: "selectedModels") as? [String]) ?? (initialModel.isEmpty ? [] : [initialModel])

        // Migrate API keys from UserDefaults to Keychain (one-time)
        let initialApiKey: String
        if let oldApiKey = defaults.string(forKey: "apiKey"), !oldApiKey.isEmpty {
            KeychainHelper.save(oldApiKey, for: "bridge_apiKey")
            defaults.removeObject(forKey: "apiKey") // Remove from UserDefaults after migration
            initialApiKey = oldApiKey
        } else {
            initialApiKey = KeychainHelper.load(for: "bridge_apiKey") ?? ""
        }

        let initialSerper: String
        if let oldSerper = defaults.string(forKey: "serperApiKey"), !oldSerper.isEmpty {
            KeychainHelper.save(oldSerper, for: "serperApiKey")
            defaults.removeObject(forKey: "serperApiKey")
            initialSerper = oldSerper
        } else {
            initialSerper = KeychainHelper.load(for: "serperApiKey") ?? ""
        }

        let initialJina: String
        if let oldJina = defaults.string(forKey: "jinaApiKey"), !oldJina.isEmpty {
            KeychainHelper.save(oldJina, for: "jinaApiKey")
            defaults.removeObject(forKey: "jinaApiKey")
            initialJina = oldJina
        } else {
            initialJina = KeychainHelper.load(for: "jinaApiKey") ?? ""
        }

        // Load endpoints and their API keys from Keychain
        if let data = defaults.data(forKey: "endpoints.v1"),
           var decoded = try? JSONDecoder().decode([EndpointConfig].self, from: data) {
            // Load API keys from Keychain for each endpoint
            for i in decoded.indices {
                decoded[i].loadApiKeyFromKeychain()
            }
            self.endpoints = decoded
        } else {
            var migrated: [EndpointConfig] = []
            if !initialApiBase.isEmpty || !initialApiKey.isEmpty || !initialSelected.isEmpty {
                let guessName: String = {
                    let b = initialApiBase.lowercased()
                    if b.contains("localhost") || b.contains("127.0.0.1") { return "Local" }
                    return "Default"
                }()
                var newEndpoint = EndpointConfig(
                    name: guessName,
                    apiBase: initialApiBase,
                    selectedModels: initialSelected,
                    preferredModel: initialModel.isEmpty ? initialSelected.first : initialModel
                )
                newEndpoint.apiKey = initialApiKey
                newEndpoint.saveApiKeyToKeychain()
                migrated = [newEndpoint]
            }
            self.endpoints = migrated
            saveEndpoints()
        }

        if let s = defaults.string(forKey: "activeEndpointID"),
           let uuid = UUID(uuidString: s),
           endpoints.contains(where: { $0.id == uuid }) {
            self.activeEndpointID = uuid
        } else {
            self.activeEndpointID = endpoints.first?.id
        }

        self.serperApiKey = initialSerper
        self.jinaApiKey = initialJina
        self.scrapingModeStorage = initialScraping

        self.apiBase = initialApiBase
        self.apiKey = initialApiKey
        self.model = initialModel
        self.selectedModels = initialSelected
        self.ttsEnabled = defaults.bool(forKey: "ttsEnabled")

        syncActiveEndpointFieldsWithModelPreservation()

        defaults.removeObject(forKey: "temperature")
    }

    private func syncActiveEndpointFieldsWithModelPreservation() {
        guard let ep = activeEndpoint else {
            if endpoints.isEmpty {
                apiBase = ""; apiKey = ""; model = ""; selectedModels = []
            }
            return
        }

        if apiBase != ep.apiBase { apiBase = ep.apiBase }
        if apiKey != ep.apiKey { apiKey = ep.apiKey }
        if selectedModels != ep.selectedModels { selectedModels = ep.selectedModels }

        let currentSavedModel = UserDefaults.standard.string(forKey: "model") ?? ""

        if !currentSavedModel.isEmpty && ep.selectedModels.contains(currentSavedModel) {
            model = currentSavedModel
            if let idx = endpoints.firstIndex(where: { $0.id == ep.id }) {
                if endpoints[idx].preferredModel != currentSavedModel {
                    endpoints[idx].preferredModel = currentSavedModel
                    saveEndpoints()
                }
            }
        } else {
            let targetModel = ep.preferredModel ?? ep.selectedModels.first ?? ""
            if model != targetModel { model = targetModel }
        }

        ensureActiveModelIsValid()
    }

    private func saveEndpoints() {
        // Save API keys to Keychain for each endpoint
        for ep in endpoints {
            ep.saveApiKeyToKeychain()
        }
        // Save the rest (without apiKey) to UserDefaults
        if let data = try? JSONEncoder().encode(endpoints) {
            UserDefaults.standard.set(data, forKey: "endpoints.v1")
        }
    }

    private func syncActiveEndpointFields() {
        guard let ep = activeEndpoint else {
            if endpoints.isEmpty && !(apiBase.isEmpty && apiKey.isEmpty && model.isEmpty && selectedModels.isEmpty) {
                apiBase = ""; apiKey = ""; model = ""; selectedModels = []
            }
            return
        }

        if apiBase != ep.apiBase { apiBase = ep.apiBase }
        if apiKey != ep.apiKey { apiKey = ep.apiKey }
        if selectedModels != ep.selectedModels { selectedModels = ep.selectedModels }

        if !model.isEmpty && ep.selectedModels.contains(model) {
            if ep.preferredModel != model {
                if let idx = endpoints.firstIndex(where: { $0.id == ep.id }) {
                    endpoints[idx].preferredModel = model
                    saveEndpoints()
                }
            }
        } else {
            let targetModel = ep.preferredModel ?? ep.selectedModels.first ?? ""
            if model != targetModel { model = targetModel }
        }

        ensureActiveModelIsValid()
    }

    func upsertEndpoint(_ ep: EndpointConfig) {
        ep.saveApiKeyToKeychain()
        if let idx = endpoints.firstIndex(where: { $0.id == ep.id }) {
            endpoints[idx] = ep
        } else {
            endpoints.append(ep)
        }
    }

    func deleteEndpoint(_ ep: EndpointConfig) {
        ep.deleteApiKeyFromKeychain()
        endpoints.removeAll { $0.id == ep.id }
        if activeEndpointID == ep.id {
            activeEndpointID = endpoints.first?.id
        }
    }

    func setActiveModel(_ model: String, on endpointID: UUID) {
        activeEndpointID = endpointID
        self.model = model
        if let idx = endpoints.firstIndex(where: { $0.id == endpointID }) {
            if endpoints[idx].preferredModel != model {
                endpoints[idx].preferredModel = model
                saveEndpoints()
            }
        }
    }

    var chatCompletionsURL: URL? {
        let base = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !base.isEmpty,
            let baseURL = URL(string: base),
            let scheme = baseURL.scheme, (scheme == "http" || scheme == "https"),
            baseURL.host != nil
        else { return nil }
        return baseURL.appendingPathComponent("chat/completions")
    }

    var modelsURL: URL? {
        let base = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !base.isEmpty,
            let baseURL = URL(string: base),
            let scheme = baseURL.scheme, (scheme == "http" || scheme == "https"),
            baseURL.host != nil
        else { return nil }
        return baseURL.appendingPathComponent("models")
    }

    var ollamaTagsURL: URL? {
        let base = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !base.isEmpty,
            let baseURL = URL(string: base),
            let scheme = baseURL.scheme, (scheme == "http" || scheme == "https"),
            baseURL.host != nil
        else { return nil }
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comps?.path = "/api/tags"
        return comps?.url
    }

    var isChatConfigured: Bool {
        !apiBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var authHeaders: [String:String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"]
    }

    func ensureActiveModelIsValid() {
        if !selectedModels.contains(model) {
            model = selectedModels.first ?? ""
        }
    }
}
