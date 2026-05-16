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

    @Test("sendMessage with no API key appends error message")
    @MainActor func testSendMessageWithNoApiKey() async {
        let model = Chat.StateModel()
        model.inputText = "What is my glucose?"
        model.apiKey = ""
        await model.sendMessage()
        #expect(model.messages.count == 1)
        #expect(model.messages.first?.role == .assistant)
        #expect(model.messages.first?.content.contains("API key") == true)
    }

    @Test("saveAPIKey persists trimmed value to UserDefaults")
    func testSaveAPIKeyPersistsToUserDefaults() {
        let model = Chat.StateModel()
        model.apiKey = "  sk-test-key-123  "
        model.saveAPIKey()
        let stored = UserDefaults.standard.string(forKey: AnthropicLLMService.apiKeyDefaultsKey)
        #expect(stored == "sk-test-key-123")
        UserDefaults.standard.removeObject(forKey: AnthropicLLMService.apiKeyDefaultsKey)
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
