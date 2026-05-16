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
        let t = AppleHealthIRThresholds.current
        switch tile {
        case .steps:
            let s = state.stepCount
            return [
                ThresholdItem(range: "< \(t.stepsLowMin.formatted()) steps",
                              effect: "None",
                              isCurrent: s < t.stepsLowMin),
                ThresholdItem(range: "\(t.stepsLowMin.formatted()) – \((t.stepsMediumMin - 1).formatted())",
                              effect: String(format: "%+.0f%% IR", t.stepsLowIREffect),
                              isCurrent: s >= t.stepsLowMin && s < t.stepsMediumMin),
                ThresholdItem(range: "\(t.stepsMediumMin.formatted()) – \((t.stepsHighMin - 1).formatted())",
                              effect: String(format: "%+.0f%% IR", t.stepsMediumIREffect),
                              isCurrent: s >= t.stepsMediumMin && s < t.stepsHighMin),
                ThresholdItem(range: "≥ \(t.stepsHighMin.formatted()) steps",
                              effect: String(format: "%+.0f%% IR", t.stepsHighIREffect),
                              isCurrent: s >= t.stepsHighMin)
            ]
        case .hrv, .bpm:
            let h = state.hrv
            return [
                ThresholdItem(range: "< \(Int(t.hrvVeryLowMax)) ms",
                              effect: String(format: "+%.0f%% IR", t.hrvVeryLowIREffect),
                              isCurrent: h.map { $0 < t.hrvVeryLowMax } ?? false),
                ThresholdItem(range: "\(Int(t.hrvVeryLowMax)) – \(Int(t.hrvLowMax) - 1) ms",
                              effect: String(format: "+%.0f%% IR", t.hrvLowIREffect),
                              isCurrent: h.map { $0 >= t.hrvVeryLowMax && $0 < t.hrvLowMax } ?? false),
                ThresholdItem(range: "\(Int(t.hrvLowMax)) – \(Int(t.hrvNormalMax)) ms",
                              effect: "None",
                              isCurrent: h.map { $0 >= t.hrvLowMax && $0 <= t.hrvNormalMax } ?? false),
                ThresholdItem(range: "> \(Int(t.hrvNormalMax)) ms",
                              effect: String(format: "%.0f%% IR", t.hrvHighIREffect),
                              isCurrent: h.map { $0 > t.hrvNormalMax } ?? false)
            ]
        case .sleep:
            let sl = state.sleepHours
            return [
                ThresholdItem(range: "< \(String(format: "%.0f", t.sleepSevereDeprivationMax)) h",
                              effect: String(format: "+%.0f%% IR", t.sleepSevereIREffect),
                              isCurrent: sl.map { $0 < t.sleepSevereDeprivationMax } ?? false),
                ThresholdItem(range: "\(String(format: "%.0f", t.sleepSevereDeprivationMax)) – \(String(format: "%.0f", t.sleepMildDeprivationMax)) h",
                              effect: String(format: "+%.0f – +%.0f%% IR", t.sleepMildIREffect, t.sleepSevereIREffect),
                              isCurrent: sl.map { $0 >= t.sleepSevereDeprivationMax && $0 < t.sleepMildDeprivationMax } ?? false),
                ThresholdItem(range: "≥ \(String(format: "%.0f", t.sleepMildDeprivationMax)) h",
                              effect: "None",
                              isCurrent: sl.map { $0 >= t.sleepMildDeprivationMax } ?? false)
            ]
        case .exercise:
            let ex = (state.exerciseHours ?? 0) * 60
            return [
                ThresholdItem(range: "< \(Int(t.exerciseMinThreshold)) min",
                              effect: "None",
                              isCurrent: ex < t.exerciseMinThreshold),
                ThresholdItem(range: "\(Int(t.exerciseMinThreshold)) – \(Int(t.exerciseModerateMax) - 1) min",
                              effect: String(format: "%.0f%% IR", t.exerciseModerateIREffect),
                              isCurrent: ex >= t.exerciseMinThreshold && ex < t.exerciseModerateMax),
                ThresholdItem(range: "\(Int(t.exerciseModerateMax)) – \(Int(t.exerciseSubstantialMax) - 1) min",
                              effect: String(format: "%.0f%% IR", t.exerciseSubstantialIREffect),
                              isCurrent: ex >= t.exerciseModerateMax && ex < t.exerciseSubstantialMax),
                ThresholdItem(range: "≥ \(Int(t.exerciseSubstantialMax)) min",
                              effect: String(format: "%.0f%% IR", t.exerciseHeavyIREffect),
                              isCurrent: ex >= t.exerciseSubstantialMax)
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
