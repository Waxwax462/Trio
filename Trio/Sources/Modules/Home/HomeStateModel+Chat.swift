import Foundation

extension Home.StateModel {
    var chatContext: ChatContext {
        let cobValue = enactedAndNonEnactedDeterminations.first.map { Double($0.cob) }
        return ChatContext(
            currentGlucose: recentGlucose?.glucose.map { Double($0) },
            glucoseUnit: units == .mmolL ? "mmol/L" : "mg/dL",
            iob: Double(truncating: currentIOB as NSNumber),
            cob: cobValue,
            heartRate: currentBPM,
            currentCaffeineMg: currentCaffeineMg,
            isSickDayModeActive: isSickDayModeActive
        )
    }
}
