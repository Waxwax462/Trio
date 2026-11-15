import AppIntents
import Foundation
import Swinject

/// A sport profile as the Shortcuts app sees it.
struct SportProfileEntity: AppEntity, Identifiable {
    static var defaultQuery = SportProfileEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sport Profile"
}

struct SportProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [SportProfileEntity.ID]) async throws -> [SportProfileEntity] {
        SportProfileIntentRequest.allProfiles().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SportProfileEntity] {
        SportProfileIntentRequest.allProfiles()
    }
}

/// What the sport profile actions do, in one place.
enum SportProfileIntentRequest {
    private static var manager: SportProfileManager? {
        TrioApp.resolver.resolve(SportProfileManager.self)
    }

    static func allProfiles() -> [SportProfileEntity] {
        (manager?.profiles() ?? []).map { SportProfileEntity(id: $0.id, name: $0.name) }
    }

    /// Starts a profile. With `skipPreparation` it begins at the first "during" phase.
    static func start(_ entity: SportProfileEntity, skipPreparation: Bool) async -> Bool {
        guard let manager, let profile = manager.profiles().first(where: { $0.id == entity.id }) else { return false }
        let index = skipPreparation ? (profile.phases.firstIndex(where: { $0.kind == .during }) ?? 0) : 0
        do {
            try await manager.start(profileID: profile.id, phaseIndex: index)
            return true
        } catch {
            debug(.default, "Shortcut could not start sport profile: \(error)")
            return false
        }
    }

    static func nextPhase() async -> Bool {
        guard let manager else { return false }
        do {
            try await manager.skipToNextPhase()
            return true
        } catch {
            debug(.default, "Shortcut could not advance sport profile: \(error)")
            return false
        }
    }

    static func stop() async -> Bool {
        guard let manager else { return false }
        do {
            try await manager.cancel()
            return true
        } catch {
            debug(.default, "Shortcut could not stop sport profile: \(error)")
            return false
        }
    }
}
