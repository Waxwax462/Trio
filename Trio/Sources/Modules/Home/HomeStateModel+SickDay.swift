import Foundation

extension Home.StateModel {
    private static let sickDayKey = "rheos.sickDayMode"
    private static let sickDayActivatedAtKey = "rheos.sickDayActivatedAt"

    func toggleSickDayMode() {
        isSickDayModeActive.toggle()
        UserDefaults.standard.set(isSickDayModeActive, forKey: Self.sickDayKey)
        if isSickDayModeActive {
            UserDefaults.standard.set(Date(), forKey: Self.sickDayActivatedAtKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sickDayActivatedAtKey)
        }
    }

    var sickDayHoursActive: Double? {
        guard isSickDayModeActive,
              let since = UserDefaults.standard.object(forKey: Self.sickDayActivatedAtKey) as? Date
        else { return nil }
        return Date().timeIntervalSince(since) / 3600
    }
}
