import Foundation

// MARK: - Error types

enum LLMError: Error {
    case badResponse
    case invalidAPIKey
    case missingAPIKey
}

// MARK: - Protocol

protocol LLMService: AnyObject {
    func stream(messages: [ChatMessage], systemPrompt: String) -> AsyncThrowingStream<String, Error>
}

// MARK: - Concrete implementation

final class AnthropicLLMService: LLMService {
    /// API key is stored and read from UserDefaults under this key.
    static let apiKeyDefaultsKey = "rheos.anthropicApiKey"

    private let apiKey: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-sonnet-4-6"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func stream(messages: [ChatMessage], systemPrompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    var request = URLRequest(url: self.endpoint)
                    request.httpMethod = "POST"
                    request.setValue(self.apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")

                    let body: [String: Any] = [
                        "model": self.model,
                        "max_tokens": 1024,
                        "stream": true,
                        "system": systemPrompt,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200
                    else {
                        continuation.finish(throwing: LLMError.badResponse)
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let data = String(line.dropFirst(6))
                        guard data != "[DONE]",
                              let jsonData = data.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let delta = (json["delta"] as? [String: Any])?["text"] as? String
                        else { continue }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
