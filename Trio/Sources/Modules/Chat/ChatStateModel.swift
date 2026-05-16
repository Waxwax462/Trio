import Foundation
import Observation

extension Chat {
    @Observable final class StateModel {
        var messages: [ChatMessage] = []
        var inputText: String = ""
        var isStreaming: Bool = false
        var context: ChatContext = .empty
        var apiKey: String = UserDefaults.standard.string(forKey: AnthropicLLMService.apiKeyDefaultsKey) ?? ""

        @ObservationIgnored private var llmService: (any LLMService)?

        /// Maximum retained messages to prevent unbounded memory growth.
        private static let maxMessages = 50

        @MainActor
        func sendMessage() async {
            let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isStreaming else { return }

            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                let errMsg = ChatMessage(
                    id: UUID(),
                    role: .assistant,
                    content: "Please enter your Anthropic API key to use Rheos AI.",
                    timestamp: Date()
                )
                messages.append(errMsg)
                return
            }

            if llmService == nil {
                llmService = AnthropicLLMService(apiKey: key)
            }

            // Use guard to avoid force-unwrap; service is always non-nil here
            guard let service = llmService else { return }

            let userMessage = ChatMessage(id: UUID(), role: .user, content: text, timestamp: Date())
            messages.append(userMessage)
            inputText = ""
            isStreaming = true
            defer { isStreaming = false }

            // Cap history at maxMessages to avoid unbounded memory growth
            if messages.count > Self.maxMessages {
                messages.removeFirst(messages.count - Self.maxMessages)
            }

            let assistantMessage = ChatMessage(id: UUID(), role: .assistant, content: "", timestamp: Date())
            messages.append(assistantMessage)
            let lastIndex = messages.count - 1

            let prompt = buildSystemPrompt()
            let conversationMessages = Array(messages.dropLast())

            do {
                // @MainActor ensures all messages mutations happen on the main thread
                for try await token in service.stream(messages: conversationMessages, systemPrompt: prompt) {
                    messages[lastIndex].content += token
                }
            } catch {
                messages[lastIndex].content = "Sorry, I couldn't connect. Please check your API key and try again."
            }
        }

        func saveAPIKey() {
            UserDefaults.standard.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: AnthropicLLMService.apiKeyDefaultsKey)
            llmService = nil
        }

        private func buildSystemPrompt() -> String {
            // SAFETY: The LLM is informational ONLY and must never suggest dosing.
            var parts: [String] = [
                "You are a diabetes information assistant. You provide educational information only.",
                "You must NEVER suggest specific insulin doses, basal rates, or insulin-to-carb ratios.",
                "All dosing decisions are made exclusively by the algorithm.",
                "Do not recommend changes to any therapy settings.",
                "Always encourage the user to consult their healthcare provider for medical advice.",
                "Be concise and direct. Use plain language."
            ]

            var contextParts: [String] = []
            if let glucose = context.currentGlucose {
                contextParts.append("Current glucose: \(Int(glucose)) \(context.glucoseUnit)")
            }
            if let iob = context.iob, iob > 0 {
                contextParts.append(String(format: "IOB: %.2f U", iob))
            }
            if let cob = context.cob, cob > 0 {
                contextParts.append(String(format: "COB: %.0f g", cob))
            }
            if let hr = context.heartRate {
                contextParts.append("Heart rate: \(Int(hr)) bpm")
            }
            if context.currentCaffeineMg >= 1 {
                contextParts.append("Active caffeine: \(Int(context.currentCaffeineMg)) mg")
            }
            if context.isSickDayModeActive {
                contextParts.append("Sick day mode is active.")
            }

            if !contextParts.isEmpty {
                parts.append("Current user context: " + contextParts.joined(separator: ", ") + ".")
            }

            return parts.joined(separator: "\n")
        }
    }
}
