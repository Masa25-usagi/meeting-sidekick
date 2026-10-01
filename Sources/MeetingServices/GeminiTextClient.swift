import Foundation

@MainActor
public final class GeminiTextClient {
    public init() {}
    public func generate(apiKey: String, model: String, prompt: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ServiceError.missingKey }
        guard !model.isEmpty, model.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { throw ServiceError.invalidEndpoint }
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!, timeoutInterval: 45)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["contents": [["role": "user", "parts": [["text": prompt]]]], "generationConfig": ["maxOutputTokens": 1200]])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw ServiceError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]], let content = candidates.first?["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else { throw ServiceError.invalidResponse }
        let result = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        guard !result.isEmpty else { throw ServiceError.invalidResponse }
        return result
    }
}
