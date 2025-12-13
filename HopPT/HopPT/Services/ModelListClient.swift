import Foundation

struct ModelListClient {
    let apiBase: String
    let apiKey: String

    func fetchModels() async throws -> [String] {
        // 1) Try OpenAI-compatible /v1/models (or base + /models)
        if let url = openAIModelsURL(from: apiBase) {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            authHeaders(for: apiKey).forEach { k, v in req.setValue(v, forHTTPHeaderField: k) }

            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let list = try? JSONDecoder().decode(OpenAIModelList.self, from: data) {
                let ids = list.data.map(\.id).sorted()
                if !ids.isEmpty { return ids }
            }
        }

        // 2) Fallback: Ollama native list at /api/tags
        if let url = ollamaTagsURL(from: apiBase) {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let tags = try? JSONDecoder().decode(OllamaTags.self, from: data) {
                let names = tags.models.map(\.name).sorted()
                if !names.isEmpty { return names }
            }
        }

        throw NSError(
            domain: "ModelListClient",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Couldn't fetch models from /models or /api/tags."]
        )
    }

    // MARK: - Helpers

    private func openAIModelsURL(from base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let baseURL = URL(string: trimmed),
              let scheme = baseURL.scheme, (scheme == "http" || scheme == "https"),
              baseURL.host != nil else { return nil }
        return baseURL.appendingPathComponent("models")
    }

    private func ollamaTagsURL(from base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let baseURL = URL(string: trimmed),
              let scheme = baseURL.scheme, (scheme == "http" || scheme == "https"),
              baseURL.host != nil else { return nil }
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comps?.path = "/api/tags"
        return comps?.url
    }

    private func authHeaders(for key: String) -> [String:String] {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [:] : ["Authorization": "Bearer \(trimmed)"]
    }

    private struct OpenAIModelList: Decodable { let data: [OpenAIModel] }
    private struct OpenAIModel: Decodable { let id: String }
    private struct OllamaTags: Decodable { let models: [OllamaModel] }
    private struct OllamaModel: Decodable { let name: String }
}
