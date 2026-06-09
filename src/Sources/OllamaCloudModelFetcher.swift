import Foundation

struct OllamaAPITagResponse: Codable {
    struct Model: Codable {
        let name: String
        enum CodingKeys: String, CodingKey { case name }
    }
    let models: [Model]
}

enum OllamaCloudModelFetcherError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case httpError(Int, String)
    case decodingError(Error)
    case noModelsAvailable

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL."
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .httpError(401, _): return "Invalid API key (401). Check ollama.com/settings/keys."
        case .httpError(let code, _): return "API error \(code). Please try again."
        case .decodingError: return "Unexpected response format."
        case .noModelsAvailable: return "No models found for this account."
        }
    }
}

final class OllamaCloudModelFetcher {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    /// Fetches all available models from Ollama Cloud via GET https://ollama.com/api/tags.
    func fetchCloudModels(apiKey: String) async throws -> [String] {
        guard let url = URL(string: "https://ollama.com/api/tags") else {
            throw OllamaCloudModelFetcherError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OllamaCloudModelFetcherError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaCloudModelFetcherError.httpError(0, "")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaCloudModelFetcherError.httpError(http.statusCode, body)
        }

        let tagResponse: OllamaAPITagResponse
        do {
            tagResponse = try JSONDecoder().decode(OllamaAPITagResponse.self, from: data)
        } catch {
            throw OllamaCloudModelFetcherError.decodingError(error)
        }

        let names = tagResponse.models.map(\.name).filter { !$0.isEmpty }.sorted()
        guard !names.isEmpty else { throw OllamaCloudModelFetcherError.noModelsAvailable }
        return names
    }
}
