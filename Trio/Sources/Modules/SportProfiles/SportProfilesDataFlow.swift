import Foundation

enum SportProfiles {
    enum Config {}
}

protocol SportProfilesProvider {}

extension SportPhaseKind {
    var localizedName: String {
        switch self {
        case .pre: return String(localized: "Before Sport", comment: "Sport profile phase")
        case .during: return String(localized: "During Sport", comment: "Sport profile phase")
        case .recovery: return String(localized: "Recovery", comment: "Sport profile phase")
        }
    }
}
