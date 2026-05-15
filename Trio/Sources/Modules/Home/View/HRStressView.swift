import Charts
import SwiftUI

struct HRStressView: View {
    let state: Home.StateModel

    var body: some View {
        HStack(spacing: 12) {
            bpmLabel
            stressSparkline
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var bpmLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(bpmText)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(state.isHRStale ? .secondary : .primary)
                Text("BPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Heart Rate")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 72, alignment: .leading)
    }

    private var bpmText: String {
        if let bpm = state.currentBPM {
            return String(format: "%.0f", bpm)
        }
        return "--"
    }

    @ViewBuilder
    private var stressSparkline: some View {
        let points = state.hrStressPoints
        if points.count >= 2 {
            Chart(points.indices, id: \.self) { i in
                AreaMark(
                    x: .value("Time", points[i].timestamp),
                    y: .value("BPM/min", points[i].value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [sparklineColor(points[i].value).opacity(0.5), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Time", points[i].timestamp),
                    y: .value("BPM/min", points[i].value)
                )
                .foregroundStyle(sparklineColor(points[i].value))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 36)
        } else {
            Color.clear.frame(height: 36)
        }
    }

    private func sparklineColor(_ value: Double) -> Color {
        if value > 5 { return .red }
        if value < -5 { return .teal }
        return .green
    }
}
