import SwiftUI

struct AppleHealthIRSheet: View {
    let state: Home.StateModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                combinedEffectSection
                breakdownSection
                let entries = state.appleHealthIRService?.entries ?? []
                if !entries.isEmpty {
                    recentSnapshotsSection(entries)
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

    private var combinedEffectSection: some View {
        let deltas = state.appleHealthIRService?.currentDeltas ?? AppleHealthIRDeltas()
        let pct = deltas.combined
        return Section {
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
                    Text(deltaLabel(pct))
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(deltaColor(pct))
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Data refreshes automatically when Apple Health updates.")
                .font(.caption2)
        }
    }

    private var breakdownSection: some View {
        let deltas = state.appleHealthIRService?.currentDeltas ?? AppleHealthIRDeltas()
        return Section("Breakdown") {
            breakdownRow(
                source: .sleep,
                value: state.sleepHours.map { String(format: "%.1f h", $0) } ?? "—",
                delta: deltas.sleep
            )
            breakdownRow(
                source: .steps,
                value: state.stepCount > 0 ? state.stepCount.formatted() : "—",
                delta: deltas.steps
            )
            breakdownRow(
                source: .hrv,
                value: state.hrv.map { String(format: "%.0f ms", $0) } ?? "—",
                delta: deltas.hrv
            )
            breakdownRow(
                source: .exercise,
                value: state.exerciseHours.map { String(format: "%.0f min", $0 * 60) } ?? "—",
                delta: deltas.exercise
            )
        }
    }

    private func breakdownRow(source: AppleHealthIRSource, value: String, delta: Double) -> some View {
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
            Text(deltaLabel(delta))
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(deltaColor(delta))
        }
    }

    private func recentSnapshotsSection(_ entries: [AppleHealthIREntry]) -> some View {
        let grouped = Dictionary(grouping: entries) { entry -> String in
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f.string(from: entry.timestamp)
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
                Text(entry.details)
                    .font(.subheadline)
                Text(entry.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(deltaLabel(entry.irDeltaPercent))
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(deltaColor(entry.irDeltaPercent))
        }
    }

    // MARK: - Helpers

    private func deltaLabel(_ pct: Double) -> String {
        if abs(pct) < 0.5 { return "None" }
        return String(format: "%+.0f%%", pct)
    }

    private func deltaColor(_ pct: Double) -> AnyShapeStyle {
        if abs(pct) < 0.5 { return AnyShapeStyle(.secondary) }
        return pct > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.green)
    }
}
