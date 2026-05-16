import SwiftUI

// MARK: - Tile Model

enum BiometricTile: String, Identifiable, Hashable {
    case steps
    case hrv
    case sleep
    case exercise
    case bpm

    var id: String { rawValue }

    /// The IR source this tile maps to (nil = informational only).
    var irSource: AppleHealthIRSource? {
        switch self {
        case .steps: return .steps
        case .hrv: return .hrv
        case .sleep: return .sleep
        case .exercise: return .exercise
        case .bpm: return .hrv
        }
    }

    var displayName: String {
        switch self {
        case .steps: return "Steps"
        case .hrv: return "HRV"
        case .sleep: return "Sleep"
        case .exercise: return "Exercise"
        case .bpm: return "Heart Rate"
        }
    }

    var systemImage: String {
        switch self {
        case .steps: return "shoe.fill"
        case .hrv: return "waveform.path.ecg"
        case .sleep: return "bed.double.fill"
        case .exercise: return "figure.run"
        case .bpm: return "heart.fill"
        }
    }
}

// MARK: - Detail View

struct BiometricIRDetailView: View {
    let tile: BiometricTile
    let state: Home.StateModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                effectSection
                thresholdSection
                let recent = recentEntries
                if !recent.isEmpty {
                    recentSection(recent)
                }
            }
            .navigationTitle(tile.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Effect Section

    private var effectSection: some View {
        Section {
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(deltaAccentColor(currentDelta).opacity(0.15))
                            .frame(width: 56, height: 56)
                        Image(systemName: tile.systemImage)
                            .font(.title2)
                            .foregroundStyle(deltaAccentColor(currentDelta))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentValueLabel)
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                        Text(tile.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(deltaLabel(currentDelta))
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(deltaColor(currentDelta))
                        Text("IR Effect")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if abs(currentDelta) >= 0.5 {
                    HStack(spacing: 8) {
                        Image(systemName: currentDelta > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(deltaAccentColor(currentDelta))
                        Text(currentDelta > 0
                             ? "Insulin needs may be higher than usual"
                             : "Insulin sensitivity is improved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.vertical, 6)
        } footer: {
            if tile == .bpm {
                Text("Live heart rate is shown. HRV (heart rate variability) derived from your HR data drives IR calculations.")
                    .font(.caption2)
            }
        }
    }

    // MARK: - Thresholds Section

    private var thresholdSection: some View {
        Section("Thresholds") {
            ForEach(thresholds, id: \.range) { item in
                HStack {
                    if item.isCurrent {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 14)
                    } else {
                        Color.clear.frame(width: 14)
                    }
                    Text(item.range)
                        .font(.subheadline)
                        .fontWeight(item.isCurrent ? .semibold : .regular)
                    Spacer()
                    Text(item.effect)
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(thresholdColor(item.effect))
                }
                .listRowBackground(item.isCurrent ? Color.accentColor.opacity(0.10) : Color.clear)
            }
        }
    }

    // MARK: - Recent Section

    private func recentSection(_ entries: [AppleHealthIREntry]) -> some View {
        Section("Recent (24 h)") {
            ForEach(entries.prefix(8)) { entry in
                HStack {
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
        }
    }

    // MARK: - Computed Values

    private var currentDelta: Double {
        guard let source = tile.irSource,
              let deltas = state.appleHealthIRService?.currentDeltas
        else { return 0 }
        return deltas.delta(for: source)
    }

    private var currentValueLabel: String {
        switch tile {
        case .steps:
            return state.stepCount > 0 ? "\(state.stepCount.formatted()) steps" : "— steps"
        case .hrv:
            return state.hrv.map { String(format: "%.0f ms HRV", $0) } ?? "— ms HRV"
        case .sleep:
            return state.sleepHours.map { String(format: "%.1f h sleep", $0) } ?? "— h sleep"
        case .exercise:
            return state.exerciseHours.map { String(format: "%.0f min exercise", $0 * 60) } ?? "— min exercise"
        case .bpm:
            if let bpm = state.currentBPM {
                let hrv = state.hrv.map { ", HRV \(Int($0)) ms" } ?? ""
                return String(format: "%.0f BPM\(hrv)", bpm)
            }
            return state.hrv.map { String(format: "HRV %.0f ms", $0) } ?? "— BPM"
        }
    }

    private var recentEntries: [AppleHealthIREntry] {
        guard let source = tile.irSource else { return [] }
        return state.appleHealthIRService?.entries.filter { $0.source == source } ?? []
    }

    // MARK: - Threshold Definitions

    private struct ThresholdItem {
        let range: String
        let effect: String
        let isCurrent: Bool
    }

    private var thresholds: [ThresholdItem] {
        switch tile {
        case .steps:
            let s = state.stepCount
            return [
                ThresholdItem(range: "< 2,000 steps",   effect: "None",   isCurrent: s < 2_000),
                ThresholdItem(range: "2,000 – 4,999",   effect: "−3% IR", isCurrent: s >= 2_000 && s < 5_000),
                ThresholdItem(range: "5,000 – 9,999",   effect: "−5% IR", isCurrent: s >= 5_000 && s < 10_000),
                ThresholdItem(range: "≥ 10,000 steps",  effect: "−8% IR", isCurrent: s >= 10_000)
            ]
        case .hrv, .bpm:
            let h = state.hrv
            return [
                ThresholdItem(range: "< 20 ms",    effect: "+15% IR", isCurrent: h.map { $0 < 20 } ?? false),
                ThresholdItem(range: "20 – 39 ms", effect: "+8% IR",  isCurrent: h.map { $0 >= 20 && $0 < 40 } ?? false),
                ThresholdItem(range: "40 – 60 ms", effect: "None",    isCurrent: h.map { $0 >= 40 && $0 <= 60 } ?? false),
                ThresholdItem(range: "> 60 ms",    effect: "−5% IR",  isCurrent: h.map { $0 > 60 } ?? false)
            ]
        case .sleep:
            let sl = state.sleepHours
            return [
                ThresholdItem(range: "< 5 h",   effect: "+20% IR",     isCurrent: sl.map { $0 < 5 } ?? false),
                ThresholdItem(range: "5 – 7 h", effect: "+5 – 15% IR", isCurrent: sl.map { $0 >= 5 && $0 < 7 } ?? false),
                ThresholdItem(range: "7 – 9 h", effect: "None",         isCurrent: sl.map { $0 >= 7 && $0 <= 9 } ?? false),
                ThresholdItem(range: "> 9 h",   effect: "None",         isCurrent: sl.map { $0 > 9 } ?? false)
            ]
        case .exercise:
            let ex = (state.exerciseHours ?? 0) * 60
            return [
                ThresholdItem(range: "< 20 min",     effect: "None",    isCurrent: ex < 20),
                ThresholdItem(range: "20 – 59 min",  effect: "−5% IR",  isCurrent: ex >= 20 && ex < 60),
                ThresholdItem(range: "60 – 119 min", effect: "−10% IR", isCurrent: ex >= 60 && ex < 120),
                ThresholdItem(range: "≥ 120 min",    effect: "−15% IR", isCurrent: ex >= 120)
            ]
        }
    }

    // MARK: - Formatting

    private func deltaLabel(_ pct: Double) -> String {
        if abs(pct) < 0.5 { return "None" }
        return String(format: "%+.0f%%", pct)
    }

    private func deltaColor(_ pct: Double) -> AnyShapeStyle {
        if abs(pct) < 0.5 { return AnyShapeStyle(Color.secondary) }
        return pct > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.green)
    }

    private func deltaAccentColor(_ pct: Double) -> Color {
        if abs(pct) < 0.5 { return .secondary }
        return pct > 0 ? .orange : .green
    }

    private func thresholdColor(_ effect: String) -> AnyShapeStyle {
        if effect == "None" { return AnyShapeStyle(Color.secondary) }
        if effect.hasPrefix("+") { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(Color.green)
    }
}
