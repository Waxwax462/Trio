import CoreData
import Foundation
import Swinject

/// Collects what the basal check needs from history: glucose, carbs, insulin and adjustments,
/// plus the basal and sensitivity schedules in effect now.
protocol SettingsTestDataProvider {
    func loadBasalTestInput(days: Int, now: Date) async throws -> BasalTestInput
}

final class BaseSettingsTestDataProvider: SettingsTestDataProvider, Injectable, @unchecked Sendable {
    @Injected() private var storage: FileStorage!

    private let makeContext: () -> NSManagedObjectContext

    init(resolver: Resolver, contextProvider: (() -> NSManagedObjectContext)? = nil) {
        makeContext = contextProvider ?? { CoreDataStack.shared.newTaskContext() }
        injectServices(resolver)
    }

    func loadBasalTestInput(days: Int, now: Date) async throws -> BasalTestInput {
        let rangeStart = now.addingTimeInterval(-Double(max(days, 1)) * 86400)
        // Events shortly before the range still disqualify its first hours.
        let eventStart = rangeStart.addingTimeInterval(-86400)

        var input = try await loadHistory(rangeStart: rangeStart, eventStart: eventStart, now: now)

        let basal = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
        input.basalSchedule = basal.map { BasalTestScheduleEntry(startMinute: $0.minutes, value: Double($0.rate)) }

        let sensitivities = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
        input.sensitivitySchedule = (sensitivities?.sensitivities ?? []).map {
            BasalTestScheduleEntry(startMinute: $0.offset, value: Double($0.sensitivity))
        }

        let carbRatios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)
        input.carbRatioSchedule = (carbRatios?.schedule ?? []).map {
            BasalTestScheduleEntry(startMinute: $0.offset, value: Double($0.ratio))
        }

        return input
    }

    private func loadHistory(rangeStart: Date, eventStart: Date, now: Date) async throws -> BasalTestInput {
        let context = makeContext()
        context.name = "settingsTestLoadHistory"

        return try await context.perform {
            var input = BasalTestInput()

            // Glucose
            let glucoseRequest = NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
            glucoseRequest.predicate = NSPredicate(format: "date >= %@ AND date <= %@", rangeStart as NSDate, now as NSDate)
            glucoseRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            input.glucose = try context.fetch(glucoseRequest).compactMap { row in
                guard let date = row.date, row.glucose > 0 else { return nil }
                return BasalTestGlucose(date: date, value: Double(row.glucose))
            }

            // Carbs, including the fat and protein equivalents spread over the following hours
            let carbRequest = NSFetchRequest<CarbEntryStored>(entityName: "CarbEntryStored")
            carbRequest.predicate = NSPredicate(format: "date >= %@", eventStart as NSDate)
            let carbRows = try context.fetch(carbRequest)
            input.carbDates = carbRows.compactMap { row in
                guard let date = row.date, row.carbs > 0 || row.isFPU else { return nil }
                return date
            }
            input.carbs = carbRows.compactMap { row in
                guard let date = row.date, row.carbs > 0, !row.isFPU else { return nil }
                return BasalTestCarb(date: date, grams: Double(row.carbs))
            }

            // Insulin
            let pumpRequest = NSFetchRequest<PumpEventStored>(entityName: "PumpEventStored")
            pumpRequest.predicate = NSPredicate(format: "timestamp >= %@", eventStart as NSDate)
            pumpRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            pumpRequest.relationshipKeyPathsForPrefetching = ["bolus", "tempBasal"]

            var openSuspension: Date?
            for event in try context.fetch(pumpRequest) {
                guard let timestamp = event.timestamp else { continue }

                if let bolus = event.bolus, let amount = bolus.amount?.doubleValue, amount > 0 {
                    input.boluses.append(
                        BasalTestBolus(date: timestamp, units: amount, isAutomatic: bolus.isSMB && !bolus.isExternal)
                    )
                } else if let tempBasal = event.tempBasal {
                    input.tempBasals.append(
                        BasalTestTempBasal(
                            start: timestamp,
                            durationMinutes: Double(tempBasal.duration),
                            rate: tempBasal.rate?.doubleValue ?? 0,
                            isScheduledBasal: tempBasal.isScheduledBasal
                        )
                    )
                } else if event.type == PumpEventStored.EventType.pumpSuspend.rawValue {
                    if openSuspension == nil { openSuspension = timestamp }
                } else if event.type == PumpEventStored.EventType.pumpResume.rawValue {
                    if let start = openSuspension {
                        input.suspensions.append(BasalTestSpan(start: start, end: timestamp))
                        openSuspension = nil
                    }
                }
            }
            if let start = openSuspension {
                input.suspensions.append(BasalTestSpan(start: start, end: now))
            }

            // Adjustments that ran in the past
            let overrideRunRequest = NSFetchRequest<OverrideRunStored>(entityName: "OverrideRunStored")
            overrideRunRequest.predicate = NSPredicate(format: "endDate >= %@", eventStart as NSDate)
            for run in try context.fetch(overrideRunRequest) {
                if let start = run.startDate, let end = run.endDate, end > start {
                    input.adjustments.append(BasalTestSpan(start: start, end: end))
                }
            }

            let tempTargetRunRequest = NSFetchRequest<TempTargetRunStored>(entityName: "TempTargetRunStored")
            tempTargetRunRequest.predicate = NSPredicate(format: "endDate >= %@", eventStart as NSDate)
            for run in try context.fetch(tempTargetRunRequest) {
                if let start = run.startDate, let end = run.endDate, end > start {
                    input.adjustments.append(BasalTestSpan(start: start, end: end))
                }
            }

            // Adjustments that are still running
            let activeOverrideRequest = NSFetchRequest<OverrideStored>(entityName: "OverrideStored")
            activeOverrideRequest.predicate = NSPredicate(format: "enabled == %@", true as NSNumber)
            for row in try context.fetch(activeOverrideRequest) {
                if let start = row.date, start < now {
                    input.adjustments.append(BasalTestSpan(start: start, end: now))
                }
            }

            let activeTempTargetRequest = NSFetchRequest<TempTargetStored>(entityName: "TempTargetStored")
            activeTempTargetRequest.predicate = NSPredicate(format: "enabled == %@", true as NSNumber)
            for row in try context.fetch(activeTempTargetRequest) {
                if let start = row.date, start < now {
                    input.adjustments.append(BasalTestSpan(start: start, end: now))
                }
            }

            return input
        }
    }
}
