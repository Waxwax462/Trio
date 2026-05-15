import Charts
import SwiftUI
import Swinject

extension Reflections {
    struct RootView: BaseView {
        let resolver: Resolver

        @State var state = StateModel()
        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var glucoseFormatter: NumberFormatter {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            return f
        }

        var body: some View {
            ScrollView {
                VStack(spacing: 20) {
                    periodPicker
                        .padding(.horizontal)

                    if state.isLoading {
                        ProgressView()
                            .padding(.top, 40)
                    } else {
                        tirSection
                        averageGlucoseSection
                        sampleCountSection
                    }
                }
                .padding(.vertical)
            }
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(String(localized: "Reflections", comment: "Tab title"))
            .navigationBarTitleDisplayMode(.large)
            .onAppear(perform: configureView)
        }

        // MARK: - Period Picker

        private var periodPicker: some View {
            Picker(
                String(localized: "Period", comment: "Reflections period picker label"),
                selection: Binding(
                    get: { state.selectedPeriod },
                    set: { state.changePeriod($0) }
                )
            ) {
                ForEach(Period.allCases) { period in
                    Text(period.displayName).tag(period)
                }
            }
            .pickerStyle(.segmented)
        }

        // MARK: - TIR Section

        private var tirSection: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Time in Range")
                    .font(.headline)
                    .padding(.horizontal)

                if state.sampleCount == 0 {
                    ContentUnavailableView(
                        String(localized: "No glucose data available.", comment: "Empty TIR state"),
                        systemImage: "chart.bar"
                    )
                    .padding()
                } else {
                    tirBarChart
                    tirLegend
                }
            }
            .padding()
            .background(Color.chart.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }

        private var tirBarChart: some View {
            let tir = state.tirResult
            let data: [(label: String, value: Double, color: Color)] = [
                (String(localized: "In Range", comment: "TIR label"), tir.inRange, .loopGreen),
                (String(localized: "High", comment: "TIR hyper label"), tir.hyper, .loopYellow),
                (String(localized: "Low", comment: "TIR hypo label"), tir.hypo, .red)
            ]

            return Chart(data, id: \.label) { item in
                BarMark(
                    x: .value("Category", item.label),
                    y: .value("Percent", item.value)
                )
                .foregroundStyle(item.color)
                .cornerRadius(6)
                .annotation(position: .top, alignment: .center) {
                    Text(String(format: "%.1f%%", item.value))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .chartYScale(domain: 0 ... 100)
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))%").font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 180)
        }

        private var tirLegend: some View {
            HStack(spacing: 16) {
                legendItem(color: .loopGreen, label: String(localized: "In Range", comment: "TIR label"))
                legendItem(color: .loopYellow, label: String(localized: "High", comment: "TIR hyper label"))
                legendItem(color: .red, label: String(localized: "Low", comment: "TIR hypo label"))
            }
            .padding(.top, 4)
        }

        @ViewBuilder private func legendItem(color: Color, label: String) -> some View {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }

        // MARK: - Average Glucose Section

        private var averageGlucoseSection: some View {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Average Glucose")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(
                        (glucoseFormatter.string(from: NSNumber(value: state.tirResult.average)) ?? "--") +
                            " mg/dL"
                    )
                    .font(.title2)
                    .fontWeight(.semibold)
                    .fontDesign(.rounded)
                }
                Spacer()
                Image(systemName: "drop.fill")
                    .font(.largeTitle)
                    .foregroundStyle(averageGlucoseColor)
            }
            .padding()
            .background(Color.chart.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }

        private var averageGlucoseColor: Color {
            let avg = state.tirResult.average
            if avg < 70 { return .red }
            if avg > 180 { return .loopYellow }
            return .loopGreen
        }

        // MARK: - Sample Count Section

        private var sampleCountSection: some View {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Readings Analyzed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(state.sampleCount)")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .fontDesign(.rounded)
                }
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.chart.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }
    }
}
