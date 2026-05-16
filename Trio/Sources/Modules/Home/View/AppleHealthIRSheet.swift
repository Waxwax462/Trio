import SwiftUI

struct AppleHealthIRSheet: View {
    let state: Home.StateModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                combinedEffectSection
                breakdownSection
                if !(state.appleHealthIRService?.entries.isEmpty ?? true) {
                    recentSnapshotsSection
                }
            }
            .navigationTitle("Health IR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    /// Top summary: combined multiplier rendered as a signed percentage.
    private var combinedEffectSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Combined IR Effect")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Apple Health Sources")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Multiplier")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let pct = (state.appleHealthIRMultiplier - 1.0) * 100
                    Text(combinedLabel(pct))
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(combinedColor(pct))
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Data refreshes automatically when Apple Health updates.")
                .font(.caption2)
        }
    }

    /// Per-source breakdown using the current live biometric values.
    private var breakdownSection: some View {
        Section("Breakdown") {
            breakdownRow(
                source: .sleep,
                value: state.sleepHours.map { String(format: "%.1f h", $0) } ?? "—",
                delta: sleepDeltaDisplay(state.sleepHours)
            )
            breakdownRow(
                source: .steps,
                value: state.stepCount > 0 ? state.stepCount.formatted() : "—",
                delta: stepsDeltaDisplay(state.stepCount)
            )
            breakdownRow(
                source: .hrv,
                value: state.hrv.map { String(format: "%.0f ms", $0) } ?? "—",
                delta: hrvDeltaDisplay(state.hrv)
            )
        }
    }

    private func breakdownRow(source: AppleHealthIRSource, value: String, delta: String) -> some View {
        HStack {
            Image(systemName: source.systemImage)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.displayName)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(delta)
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(deltaColor(delta))
        }
    }

    /// Chronological list of individual snapshots, grouped by calendar date.
    private var recentSnapshotsSection: some View {
        let allEntries = state.appleHealthIRService?.entries ?? []
        let grouped = Dictionary(grouping: allEntries) { entry -> String in
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: entry.timestamp)
        }
        let sortedKeys = grouped.keys.sorted(by: >)

        return ForEach(sortedKeys, id: \.self) { key in
            Section(key) {
                ForEach(grouped[key] ?? []) { entry in
                    snapshotRow(entry)
                }
            }
        }
    }

    private func snapshotRow(_ entry: AppleHealthIREntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.source.systemImage)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.source.displayName)
                    .font(.subheadline)
                Text(entry.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formattedDelta(entry.irDeltaPercent))
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(entry.irDeltaPercent > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.green))
        }
    }

    // MARK: - Formatting Helpers

    private func combinedLabel(_ pct: Double) -> String {
        if abs(pct) < 1 { return "None" }
        return String(format: "%+.0f%%", pct)
    }

    private func combinedColor(_ pct: Double) -> AnyShapeStyle {
        if abs(pct) < 1 { return AnyShapeStyle(.secondary) }
        if pct > 0 { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(Color.green)
    }

    private func formattedDelta(_ delta: Double) -> String {
        String(format: "%+.1f%%", delta)
    }

    private func deltaColor(_ text: String) -> AnyShapeStyle {
        if text.hasPrefix("+") { return AnyShapeStyle(Color.orange) }
        if text.hasPrefix("-") { return AnyShapeStyle(Color.green) }
        return AnyShapeStyle(Color.secondary)
    }

    // MARK: - Live Delta Calculations (mirrors AppleHealthIRService math, read-only)

    private func sleepDeltaDisplay(_ hours: Double?) -> String {
        guard let h = hours else { return "—" }
        let delta: Double
        if h < 5 {
            delta = 20.0
        } else if h < 7 {
            delta = 5.0 + (7.0 - h) / 2.0 * 10.0
        } else {
            delta = 0.0
        }
        return delta == 0 ? "None" : String(format: "%+.1f%%", delta)
    }

    private func stepsDeltaDisplay(_ steps: Int) -> String {
        let delta: Double
        if steps < 2_000 {
            delta = 0.0
        } else if steps < 5_000 {
            delta = -3.0
        } else if steps < 10_000 {
            delta = -5.0
        } else {
            delta = -8.0
        }
        return delta == 0 ? "None" : String(format: "%+.1f%%", delta)
    }

    private func hrvDeltaDisplay(_ hrv: Double?) -> String {
        guard let ms = hrv else { return "—" }
        let delta: Double
        if ms < 20 {
            delta = 15.0
        } else if ms < 40 {
            delta = 8.0
        } else if ms <= 60 {
            delta = 0.0
        } else {
            delta = -5.0
        }
        return delta == 0 ? "None" : String(format: "%+.1f%%", delta)
    }
}
