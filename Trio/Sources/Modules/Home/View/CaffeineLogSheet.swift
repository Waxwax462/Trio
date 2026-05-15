import SwiftUI

struct CaffeineLogSheet: View {
    let state: Home.StateModel
    @Environment(\.dismiss) private var dismiss

    @State private var customMg: String = ""
    @FocusState private var customFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                currentLevelSection
                quickAddSection
                customSection
                if !(state.caffeineService?.entries.isEmpty ?? true) { entriesSection }
            }
            .navigationTitle("Caffeine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var currentLevelSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active Caffeine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f mg", state.currentCaffeineMg))
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("IR Effect")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let pct = (state.caffeineIRMultiplier - 1.0) * 100
                    Text(pct < 1 ? "None" : String(format: "+%.0f%%", pct))
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(pct < 5 ? .secondary : .orange)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var quickAddSection: some View {
        Section("Quick Add") {
            ForEach(CaffeineSource.allCases.filter { $0 != .custom }, id: \.self) { source in
                Button {
                    state.caffeineService?.log(mg: source.defaultMg, source: source)
                } label: {
                    HStack {
                        Text(source.emoji).font(.title3)
                        Text(source.displayName)
                        Spacer()
                        Text("\(Int(source.defaultMg)) mg")
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private var customSection: some View {
        Section("Custom") {
            HStack {
                TextField("Amount", text: $customMg)
                    .keyboardType(.numberPad)
                    .focused($customFieldFocused)
                Text("mg")
                    .foregroundStyle(.secondary)
                Button("Add") {
                    if let mg = Double(customMg), mg > 0 {
                        state.caffeineService?.log(mg: mg, source: .custom)
                        customMg = ""
                        customFieldFocused = false
                    }
                }
                .disabled(Double(customMg) == nil || (Double(customMg) ?? 0) <= 0)
            }
        }
    }

    private var entriesSection: some View {
        Section("Today") {
            ForEach(state.caffeineService?.entries ?? []) { entry in
                HStack {
                    Text(entry.source.emoji)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.source.displayName)
                        Text(entry.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(entry.mg)) mg")
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { indexSet in
                let visible = state.caffeineService?.entries ?? []
                indexSet.forEach { i in
                    state.caffeineService?.remove(id: visible[i].id)
                }
            }
        }
    }
}
