import SwiftUI
import UIKit

extension Chat {
    struct RootView: View {
        let context: ChatContext
        @State var state = StateModel()
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    messageList
                    Divider()
                    inputBar
                }
                .navigationTitle("Rheos AI")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        apiKeyButton
                    }
                }
            }
            .onAppear { state.context = context }
        }

        private var messageList: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    if state.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "key.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Set API key to start chatting with Rheos AI")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Set API key…") { showAPIKeyAlert() }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(state.messages) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }
                            if state.isStreaming, let last = state.messages.last, last.content.isEmpty {
                                HStack {
                                    ProgressView()
                                        .padding(.leading, 16)
                                    Spacer()
                                }
                                .id("typing")
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .onChange(of: state.messages.count) {
                    if let lastId = state.messages.last?.id {
                        withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                    }
                }
                .onChange(of: state.messages.last?.content) {
                    if let lastId = state.messages.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }

        @ViewBuilder
        private func messageBubble(_ message: ChatMessage) -> some View {
            HStack {
                if message.role == .user { Spacer(minLength: 48) }
                Text(message.content.isEmpty ? " " : message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.role == .user
                            ? Color.blue
                            : Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .font(.body)
                    .textSelection(.enabled)
                if message.role == .assistant { Spacer(minLength: 48) }
            }
            .padding(.horizontal, 12)
        }

        private var inputBar: some View {
            HStack(spacing: 8) {
                TextField("Ask Rheos AI…", text: $state.inputText, axis: .vertical)
                    .lineLimit(1 ... 5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .onSubmit {
                        Task { await state.sendMessage() }
                    }

                Button {
                    Task { await state.sendMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isStreaming ? Color.secondary : Color.blue)
                }
                .disabled(state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isStreaming)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }

        private var apiKeyButton: some View {
            Button {
                showAPIKeyAlert()
            } label: {
                Image(systemName: "key")
            }
        }

        private func showAPIKeyAlert() {
            let alert = UIAlertController(
                title: "Anthropic API Key",
                message: "Enter your API key to enable Rheos AI chat.",
                preferredStyle: .alert
            )
            alert.addTextField { field in
                field.placeholder = "sk-ant-..."
                field.text = state.apiKey
                field.isSecureTextEntry = true
            }
            alert.addAction(UIAlertAction(title: "Save", style: .default) { _ in
                state.apiKey = alert.textFields?.first?.text ?? ""
                state.saveAPIKey()
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.windows.first?.rootViewController
            else { return }
            var topVC = root
            while let presented = topVC.presentedViewController { topVC = presented }
            topVC.present(alert, animated: true)
        }
    }
}
