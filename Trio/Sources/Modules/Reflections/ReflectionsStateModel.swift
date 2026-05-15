import CoreData
import Foundation
import Observation

extension Reflections {
    @Observable final class StateModel: BaseStateModel<Provider> {
        var selectedPeriod: Period = .sevenDays
        var tirResult: TIRResult = TIRResult(inRange: 0, hypo: 0, hyper: 0, average: 0)
        var isLoading: Bool = false
        var sampleCount: Int = 0

        private let coredataContext = CoreDataStack.shared.newTaskContext()

        override func subscribe() {
            Task {
                await fetchAndComputeTIR()
            }
        }

        func changePeriod(_ period: Period) {
            selectedPeriod = period
            Task {
                await fetchAndComputeTIR()
            }
        }

        @MainActor
        private func fetchAndComputeTIR() async {
            isLoading = true
            defer { isLoading = false }

            let days = selectedPeriod.days
            let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

            let result = await fetchGlucoseTIR(since: startDate)
            tirResult = result.tir
            sampleCount = result.count
        }

        private func fetchGlucoseTIR(since startDate: Date) async -> (tir: TIRResult, count: Int) {
            let context = coredataContext
            return await context.perform {
                let fr = NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
                fr.predicate = NSPredicate(format: "date >= %@", startDate as NSDate)
                fr.sortDescriptors = [NSSortDescriptor(keyPath: \GlucoseStored.date, ascending: true)]
                do {
                    let samples = try context.fetch(fr)
                    guard !samples.isEmpty else {
                        return (TIRResult(inRange: 0, hypo: 0, hyper: 0, average: 0), 0)
                    }
                    let total = Double(samples.count)
                    let low: Double = 70, high: Double = 180
                    let inRange = Double(samples.filter { Double($0.glucose) >= low && Double($0.glucose) <= high }.count)
                    let hypo = Double(samples.filter { Double($0.glucose) < low }.count)
                    let hyper = Double(samples.filter { Double($0.glucose) > high }.count)
                    let avg = samples.map { Double($0.glucose) }.reduce(0, +) / total
                    return (TIRResult(
                        inRange: inRange / total * 100,
                        hypo: hypo / total * 100,
                        hyper: hyper / total * 100,
                        average: avg
                    ), samples.count)
                } catch {
                    debug(.default, "ReflectionsStateModel: failed to fetch glucose: \(error)")
                    return (TIRResult(inRange: 0, hypo: 0, hyper: 0, average: 0), 0)
                }
            }
        }
    }
}
