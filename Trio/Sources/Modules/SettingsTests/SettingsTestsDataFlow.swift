import Foundation

enum SettingsTests {
    enum Config {
        /// How far back the basal check looks.
        static let lookbackDays = 14
    }
}

protocol SettingsTestsProvider {}
