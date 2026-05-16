import Foundation
import Testing

@testable import Trio

@Suite("Chat State Model Tests") struct ChatStateModelTests {

    @Test("Initial state is empty")
    func testInitialState() {
        let model = Chat.StateModel()
        #expect(model.messages.isEmpty)
        #expect(model.inputText == "")
        #expect(model.isStreaming == false)
    }

    @Test("sendMessage does nothing when inputText is empty")
    @MainActor func testSendMessageWithEmptyInput() async {
        let model = Chat.StateModel()
        model.inputText = "   "
        await model.sendMessage()
        #expect(model.messages.isEmpty)
    }

    @Test("sendMessage does nothing while already streaming")
    @MainActor func testSendMessageWhileStreaming() async {
        let model = Chat.StateModel()
        model.inputText = "What is my glucose?"
        model.isStreaming = true
        await model.sendMessage()
        #expect(model.messages.isEmpty)
    }

    @Test("sendMessage with no provider configured appends error message")
    @MainActor func testSendMessageWithNoApiKey() async {
        let savedAnthropic = LLMProvider.anthropic.storedApiKey
        let savedOpenai = LLMProvider.openai.storedApiKey
        defer {
            if !savedAnthropic.isEmpty { LLMProvider.anthropic.saveApiKey(savedAnthropic) }
            if !savedOpenai.isEmpty { LLMProvider.openai.saveApiKey(savedOpenai) }
        }
        LLMProvider.anthropic.deleteApiKey()
        LLMProvider.openai.deleteApiKey()

        let model = Chat.StateModel()
        model.inputText = "What is my glucose?"
        await model.sendMessage()
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.role == .assistant)
        #expect(model.messages.first?.content.contains("AI provider") == true)
    }

    @Test("LLMProvider stores and retrieves API key via Keychain")
    func testLLMProviderPersistsKey() {
        let provider = LLMProvider.anthropic
        defer { provider.deleteApiKey() }
        let testKey = "sk-test-key-123"
        provider.saveApiKey(testKey)
        #expect(provider.storedApiKey == testKey)
    }

    @Test("deleteApiKey causes storedApiKey to return empty")
    func testDeleteApiKeyReturnsEmpty() {
        let provider = LLMProvider.anthropic
        defer { provider.deleteApiKey() }
        provider.saveApiKey("sk-ant-some-key")
        provider.deleteApiKey()
        #expect(provider.storedApiKey == "")
    }

    @Test("saveApiKey with empty string removes existing Keychain entry")
    func testSaveEmptyKeyDeletesEntry() {
        let provider = LLMProvider.anthropic
        defer { provider.deleteApiKey() }
        provider.saveApiKey("sk-ant-some-key")
        provider.saveApiKey("")
        #expect(provider.storedApiKey == "")
    }

    @Test("Anthropic and OpenAI keys are stored independently")
    func testProviderIsolation() {
        defer {
            LLMProvider.anthropic.deleteApiKey()
            LLMProvider.openai.deleteApiKey()
        }
        LLMProvider.anthropic.saveApiKey("sk-ant-abc")
        LLMProvider.openai.saveApiKey("sk-openai-xyz")
        #expect(LLMProvider.anthropic.storedApiKey == "sk-ant-abc")
        #expect(LLMProvider.openai.storedApiKey == "sk-openai-xyz")

        LLMProvider.anthropic.saveApiKey("sk-ant-updated")
        #expect(LLMProvider.openai.storedApiKey == "sk-openai-xyz")
    }

    @Test("storedApiKey migrates legacy UserDefaults key to Keychain on first read")
    func testLegacyKeychainMigration() {
        let legacyKey = "rheos.anthropicApiKey"
        let testKey = "sk-ant-legacy-migrated"
        LLMProvider.anthropic.deleteApiKey()
        defer {
            LLMProvider.anthropic.deleteApiKey()
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }

        // Seed legacy UserDefaults entry (simulates pre-migration install)
        UserDefaults.standard.set(testKey, forKey: legacyKey)

        // First read should trigger migration and return the legacy value
        let read1 = LLMProvider.anthropic.storedApiKey
        #expect(read1 == testKey)

        // Legacy UserDefaults entry must be cleaned up after migration
        #expect(UserDefaults.standard.string(forKey: legacyKey) == nil)

        // Second read must return the same value from Keychain (not UserDefaults)
        let read2 = LLMProvider.anthropic.storedApiKey
        #expect(read2 == testKey)
    }

    @Test("ChatContext.empty has correct default values")
    func testChatContextEmptyDefaults() {
        let ctx = ChatContext.empty
        #expect(ctx.currentGlucose == nil)
        #expect(ctx.glucoseUnit == "mg/dL")
        #expect(ctx.iob == nil)
        #expect(ctx.cob == nil)
        #expect(ctx.heartRate == nil)
        #expect(ctx.currentCaffeineMg == 0)
        #expect(ctx.isSickDayModeActive == false)
    }

    @Test("Each ChatMessage gets a unique ID")
    func testChatMessageUniqueIDs() {
        let msg1 = ChatMessage(id: UUID(), role: .user, content: "hello", timestamp: Date())
        let msg2 = ChatMessage(id: UUID(), role: .assistant, content: "hi", timestamp: Date())
        #expect(msg1.id != msg2.id)
    }

    @Test("ChatRole raw values match API expectation")
    func testChatRoleRawValues() {
        #expect(ChatRole.user.rawValue == "user")
        #expect(ChatRole.assistant.rawValue == "assistant")
    }
}
