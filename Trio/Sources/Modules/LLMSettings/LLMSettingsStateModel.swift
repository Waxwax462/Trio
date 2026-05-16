import Foundation
import Observation

extension LLMSettings {
    final class Provider: BaseProvider, LLMSettingsProvider {}

    @Observable final class StateModel: BaseStateModel<Provider> {
        var selectedProvider: LLMProvider = .anthropic
        var anthropicKey: String = ""
        var openAIKey: String = ""
        var anthropicModel: String = ""
        var openAIModel: String = ""

        override func subscribe() {
            load()
        }

        func load() {
            selectedProvider = LLMProvider.stored
            anthropicKey = LLMProvider.anthropic.storedApiKey
            openAIKey = LLMProvider.openai.storedApiKey
            anthropicModel = LLMProvider.anthropic.storedModel
            openAIModel = LLMProvider.openai.storedModel
        }

        func save() {
            LLMProvider.saveSelected(selectedProvider)
            LLMProvider.anthropic.saveApiKey(anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines))
            LLMProvider.openai.saveApiKey(openAIKey.trimmingCharacters(in: .whitespacesAndNewlines))
            LLMProvider.anthropic.saveModel(
                anthropicModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? LLMProvider.anthropic.defaultModel
                    : anthropicModel.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            LLMProvider.openai.saveModel(
                openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? LLMProvider.openai.defaultModel
                    : openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
