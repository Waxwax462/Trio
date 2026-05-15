import SwiftUI

struct MealLogSheet: View {
    let state: Home.StateModel
    @Environment(\.dismiss) private var dismiss

    @State private var mode: InputMode = .quick
    @State private var quickCarbs: String = ""
    @State private var description: String = ""
    @State private var estimate: MacroEstimate?
    @State private var carbs: String = ""
    @State private var fat: String = ""
    @State private var protein: String = ""
    @State private var note: String = ""

    private let estimator = MealEstimator()

    enum InputMode: String, CaseIterable {
        case quick = "Quick"
        case describe = "Describe"
        case macros = "Macros"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(InputMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                switch mode {
                case .quick: quickSection
                case .describe: describeSection
                case .macros: macrosSection
                }

                if mode == .macros || !note.isEmpty {
                    noteSection
                }
            }
            .navigationTitle("Log Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") { logMeal() }
                        .disabled(!canLog)
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var quickSection: some View {
        Section("Carbs") {
            HStack {
                TextField("0", text: $quickCarbs)
                    .keyboardType(.decimalPad)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                Text("g")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
        }
    }

    @ViewBuilder private var describeSection: some View {
        Section("What did you eat?") {
            TextField("e.g. chicken pasta with salad", text: $description)
                .autocorrectionDisabled()
            Button("Estimate") { runEstimate() }
                .disabled(description.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let e = estimate {
            Section("Estimated Macros") {
                macroRow("Carbs", value: e.carbs, unit: "g")
                macroRow("Fat", value: e.fat, unit: "g")
                macroRow("Protein", value: e.protein, unit: "g")
                if e.confidence < 0.4 {
                    Text("Low confidence — switch to Macros tab to adjust")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder private var macrosSection: some View {
        Section("Macros") {
            macroField("Carbs", binding: $carbs)
            macroField("Fat", binding: $fat)
            macroField("Protein", binding: $protein)
        }
    }

    private var noteSection: some View {
        Section("Note") {
            TextField("Optional note", text: $note)
        }
    }

    // MARK: - Helpers

    private func macroRow(_ label: String, value: Decimal, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value.asRoundedString) \(unit)")
                .foregroundStyle(.secondary)
        }
    }

    private func macroField(_ label: String, binding: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            TextField("0", text: binding)
                .keyboardType(.decimalPad)
            Text("g").foregroundStyle(.secondary)
        }
    }

    private var canLog: Bool {
        switch mode {
        case .quick: return (Decimal(string: quickCarbs) ?? 0) > 0
        case .describe: return estimate != nil
        case .macros:
            return (Decimal(string: carbs) ?? 0) > 0
                || (Decimal(string: fat) ?? 0) > 0
                || (Decimal(string: protein) ?? 0) > 0
        }
    }

    private func runEstimate() {
        let e = estimator.estimate(from: description)
        estimate = e
        carbs = "\(e.carbs.asRoundedString)"
        fat = "\(e.fat.asRoundedString)"
        protein = "\(e.protein.asRoundedString)"
    }

    private func logMeal() {
        switch mode {
        case .quick:
            let c = Decimal(string: quickCarbs) ?? 0
            state.logMeal(carbs: c, fat: nil, protein: nil, note: nil)
        case .describe:
            guard let e = estimate else { return }
            let n = description.isEmpty ? nil : description
            state.logMeal(carbs: e.carbs, fat: e.fat > 0 ? e.fat : nil, protein: e.protein > 0 ? e.protein : nil, note: n)
        case .macros:
            let c = Decimal(string: carbs) ?? 0
            let f = Decimal(string: fat) ?? 0
            let p = Decimal(string: protein) ?? 0
            let n = note.isEmpty ? nil : note
            state.logMeal(carbs: c, fat: f > 0 ? f : nil, protein: p > 0 ? p : nil, note: n)
        }
        dismiss()
    }
}

private extension Decimal {
    var asRoundedString: String {
        let n = NSDecimalNumber(decimal: self)
        return "\(Int(n.doubleValue.rounded()))"
    }
}
