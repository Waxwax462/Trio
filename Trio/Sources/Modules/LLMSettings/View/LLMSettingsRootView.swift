import SwiftUI
import Swinject

extension LLMSettings {
    struct RootView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()
        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            Form {
                providerSection
                keySection
                modelSection
                infoSection
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("AI Settings")
            .navigationBarTitleDisplayMode(.automatic)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        state.save()
                    }
                }
            }
            .onAppear(perform: configureView)
        }

        private var providerSection: some View {
            Section(header: Text("Provider")) {
                Picker("Active Provider", selection: Binding(
                    get: { state.selectedProvider },
                    set: { state.selectedProvider = $0 }
                )) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.chart)
        }

        private var keySection: some View {
            Section(header: Text("API Keys"), footer: Text("Keys are stored in the device Keychain.")) {
                providerKeyRow(provider: .anthropic, binding: $state.anthropicKey)
                providerKeyRow(provider: .openai, binding: $state.openAIKey)
            }
            .listRowBackground(Color.chart)
        }

        @ViewBuilder private func providerKeyRow(provider: LLMProvider, binding: Binding<String>) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(provider.displayName)
                        .font(.subheadline)
                        .fontWeight(state.selectedProvider == provider ? .semibold : .regular)
                    if state.selectedProvider == provider {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                SecureField(provider.apiKeyPlaceholder, text: binding)
                    .font(.caption)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.vertical, 2)
        }

        private var modelSection: some View {
            Section(header: Text("Models")) {
                modelRow(
                    provider: .anthropic,
                    binding: $state.anthropicModel,
                    placeholder: LLMProvider.anthropic.defaultModel
                )
                modelRow(
                    provider: .openai,
                    binding: $state.openAIModel,
                    placeholder: LLMProvider.openai.defaultModel
                )
            }
            .listRowBackground(Color.chart)
        }

        @ViewBuilder private func modelRow(
            provider: LLMProvider,
            binding: Binding<String>,
            placeholder: String
        ) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.displayName)
                    .font(.subheadline)
                Picker("Model", selection: binding) {
                    ForEach(provider.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .onAppear {
                    if binding.wrappedValue.isEmpty {
                        binding.wrappedValue = placeholder
                    }
                }
            }
            .padding(.vertical, 2)
        }

        private var infoSection: some View {
            Section(header: Text("Usage")) {
                Label(
                    "The active provider is used for Reflections analysis and AI Chat.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Label(
                    "The LLM never controls insulin delivery — it provides information only.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.chart)
        }
    }
}
