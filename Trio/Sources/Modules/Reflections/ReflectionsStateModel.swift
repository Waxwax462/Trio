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
            await coredataContext.perform { [weak self] in
                guard let self = self else {
                    return (TIRResult(inRange: 0, hypo: 0, hyper: 0, average: 0), 0)
                }

                let fr = NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
                fr.predicate = NSPredicate(format: "date >= %@", startDate as NSDate)
                fr.sortDescriptors = [NSSortDescriptor(keyPath: \GlucoseStored.date, ascending: true)]

                do {
                    let samples = try self.coredataContext.fetch(fr)
                    let tir = self.computeTIR(samples: samples)
                    return (tir, samples.count)
                } catch {
                    debug(.default, "ReflectionsStateModel: failed to fetch glucose: \(error)")
                    return (TIRResult(inRange: 0, hypo: 0, hyper: 0, average: 0), 0)
                }
            }
        }

        private func computeTIR(
            samples: [GlucoseStored],
            low: Double = 70,
            high: Double = 180
        ) -> TIRResult {
            guard !samples.isEmpty else {
                return TIRResult(inRange: 0, hypo: 0, hyper: 0, average: 0)
            }
            let total = Double(samples.count)
            let inRange = samples.filter { Double($0.glucose) >= low && Double($0.glucose) <= high }.count
            let hypo = samples.filter { Double($0.glucose) < low }.count
            let hyper = samples.filter { Double($0.glucose) > high }.count
            let avg = samples.map { Double($0.glucose) }.reduce(0, +) / total
            return TIRResult(
                inRange: Double(inRange) / total * 100,
                hypo: Double(hypo) / total * 100,
                hyper: Double(hyper) / total * 100,
                average: avg
            )
        }
    }
}
