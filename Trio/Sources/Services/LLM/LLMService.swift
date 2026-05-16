import Foundation
import Security

// MARK: - Error types

enum LLMError: Error {
    case badResponse
    case invalidAPIKey
    case rateLimited
    case missingAPIKey

    var localizedDescription: String {
        switch self {
        case .invalidAPIKey: return "Invalid API key. Check Settings → Services → AI Settings."
        case .rateLimited: return "Rate limit reached. Please wait a moment before trying again."
        case .badResponse, .missingAPIKey: return "Could not reach AI service. Check your API key and try again."
        }
    }
}

// MARK: - Provider

enum LLMProvider: String, CaseIterable, Identifiable {
    case anthropic = "anthropic"
    case openai = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI (GPT)"
        }
    }

    var apiKeyPlaceholder: String {
        switch self {
        case .anthropic: return "sk-ant-..."
        case .openai: return "sk-..."
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-5"
        case .openai: return "gpt-4o"
        }
    }

    var availableModels: [String] {
        switch self {
        case .anthropic: return ["claude-sonnet-4-5", "claude-haiku-4-5", "claude-opus-4-5"]
        case .openai: return ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo"]
        }
    }

    var modelDefaultsKey: String { "rheos.llm.\(rawValue).model" }

    static let selectedProviderKey = "rheos.llm.selectedProvider"

    // Legacy UserDefaults keys — read-only, used only for one-time migration to Keychain.
    private var legacyApiKeyDefaultsKey: String {
        switch self {
        case .anthropic: return "rheos.anthropicApiKey"
        case .openai: return "rheos.llm.openai.apiKey"
        }
    }

    private static let keychainService = "com.rheos.llmservice"

    var storedApiKey: String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: LLMProvider.keychainService,
            kSecAttrAccount as String: rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let key = String(data: data, encoding: .utf8),
           !key.isEmpty
        {
            return key
        }
        // One-time migration from UserDefaults. saveApiKey handles the UserDefaults cleanup.
        let legacy = UserDefaults.standard.string(forKey: legacyApiKeyDefaultsKey) ?? ""
        if !legacy.isEmpty {
            saveApiKey(legacy)
        }
        return legacy
    }

    var storedModel: String {
        guard let saved = UserDefaults.standard.string(forKey: modelDefaultsKey),
              availableModels.contains(saved) else { return defaultModel }
        return saved
    }

    @discardableResult
    func saveApiKey(_ key: String) -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: LLMProvider.keychainService,
            kSecAttrAccount as String: rawValue
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        // Remove from insecure storage before writing to Keychain so the plaintext
        // is not left behind even if the Keychain write fails.
        UserDefaults.standard.removeObject(forKey: legacyApiKeyDefaultsKey)
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return true }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: LLMProvider.keychainService,
            kSecAttrAccount as String: rawValue,
            kSecValueData as String: data,
            // WhenUnlockedThisDeviceOnly: accessible only while device is unlocked and
            // never synced to iCloud Keychain or device backups.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            debug(.default, "LLMProvider: Keychain write failed for \(rawValue): \(status)")
        }
        return status == errSecSuccess
    }

    #if DEBUG
    func deleteApiKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: LLMProvider.keychainService,
            kSecAttrAccount as String: rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
    #endif

    func saveModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: modelDefaultsKey)
    }

    static var stored: LLMProvider {
        guard let raw = UserDefaults.standard.string(forKey: selectedProviderKey),
              let provider = LLMProvider(rawValue: raw)
        else { return .anthropic }
        return provider
    }

    static func saveSelected(_ provider: LLMProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: selectedProviderKey)
    }
}

// MARK: - Protocol

protocol LLMService: AnyObject {
    func stream(messages: [ChatMessage], systemPrompt: String) -> AsyncThrowingStream<String, Error>
}

// MARK: - Anthropic

final class AnthropicLLMService: LLMService {
    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(apiKey: String, model: String = LLMProvider.anthropic.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    func stream(messages: [ChatMessage], systemPrompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { [self] in
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")

                    let body: [String: Any] = [
                        "model": model,
                        "max_tokens": 1024,
                        "stream": true,
                        "system": systemPrompt,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                        switch httpResponse.statusCode {
                        case 401: continuation.finish(throwing: LLMError.invalidAPIKey)
                        case 429: continuation.finish(throwing: LLMError.rateLimited)
                        default: continuation.finish(throwing: LLMError.badResponse)
                        }
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

// MARK: - OpenAI

final class OpenAILLMService: LLMService {
    private let apiKey: String
    private let model: String
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    init(apiKey: String, model: String = LLMProvider.openai.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    func stream(messages: [ChatMessage], systemPrompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { [self] in
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var allMessages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
                    allMessages += messages.map { ["role": $0.role.rawValue, "content": $0.content] }

                    let body: [String: Any] = [
                        "model": model,
                        "max_tokens": 1024,
                        "stream": true,
                        "messages": allMessages
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                        switch httpResponse.statusCode {
                        case 401: continuation.finish(throwing: LLMError.invalidAPIKey)
                        case 429: continuation.finish(throwing: LLMError.rateLimited)
                        default: continuation.finish(throwing: LLMError.badResponse)
                        }
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let data = String(line.dropFirst(6))
                        guard data != "[DONE]",
                              let jsonData = data.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let text = delta["content"] as? String
                        else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Factory

enum LLMServiceFactory {
    static func makeService() -> (any LLMService)? {
        let provider = LLMProvider.stored
        let key = provider.storedApiKey
        guard !key.isEmpty else { return nil }
        let model = provider.storedModel
        switch provider {
        case .anthropic: return AnthropicLLMService(apiKey: key, model: model)
        case .openai: return OpenAILLMService(apiKey: key, model: model)
        }
    }
}
