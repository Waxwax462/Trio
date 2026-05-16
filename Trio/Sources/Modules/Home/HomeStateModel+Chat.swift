import Foundation

extension Home.StateModel {
    var chatContext: ChatContext {
        let cobValue = enactedAndNonEnactedDeterminations.first.map { Double($0.cob) }
        return ChatContext(
            currentGlucose: recentGlucose.map { Double($0.glucose) },
            glucoseUnit: units == .mmolL ? "mmol/L" : "mg/dL",
            iob: Double(currentIOB),
            cob: cobValue,
            heartRate: currentBPM,
            currentCaffeineMg: currentCaffeineMg,
            isSickDayModeActive: isSickDayModeActive
        )
    }
}
