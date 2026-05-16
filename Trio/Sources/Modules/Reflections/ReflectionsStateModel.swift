import CoreData
import Foundation
import Observation

extension Reflections {
    @Observable final class StateModel: BaseStateModel<Provider> {
        var selectedPeriod: Period = .sevenDays
        var tirResult: TIRResult = TIRResult(inRange: 0, hypo: 0, hyper: 0, average: 0)
        var isLoading: Bool = false
        var sampleCount: Int = 0
        var llmNarrative: String? = nil
        var isAnalyzing: Bool = false
        var hasLLMProvider: Bool = false
        /// Deterministically detected glucose patterns for the selected period.
        var detectedPatterns: [DetectedPattern] = []

        private let coredataContext = CoreDataStack.shared.newTaskContext()

        override func subscribe() {
            refreshProviderStatus()
            Task { await fetchAndComputeTIR() }
        }

        func refreshProviderStatus() {
            hasLLMProvider = LLMServiceFactory.makeService() != nil
        }

        func changePeriod(_ period: Period) {
            selectedPeriod = period
            llmNarrative = nil
            Task { await fetchAndComputeTIR() }
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

            // Pattern detection runs after TIR so the loading indicator covers both.
            detectedPatterns = await detectPatterns(since: startDate)
        }

        // MARK: - Pattern Detection

        private func detectPatterns(since startDate: Date) async -> [DetectedPattern] {
            let context = coredataContext
            return await context.perform {
                // Fetch glucose samples
                let glucoseFR = NSFetchRequest<GlucoseStored>(entityName: "GlucoseStored")
                glucoseFR.predicate = NSPredicate(format: "date >= %@", startDate as NSDate)
                glucoseFR.sortDescriptors = [NSSortDescriptor(keyPath: \GlucoseStored.date, ascending: true)]

                let glucoseSamples: [(date: Date, glucose: Double)]
                do {
                    let stored = try context.fetch(glucoseFR)
                    glucoseSamples = stored.compactMap { entry -> (Date, Double)? in
                        guard let date = entry.date else { return nil }
                        return (date, Double(entry.glucose))
                    }
                } catch {
                    debug(.default, "PatternDetector: failed to fetch glucose: \(error)")
                    return []
                }

                // Fetch carb entries
                let carbFR = NSFetchRequest<CarbEntryStored>(entityName: "CarbEntryStored")
                carbFR.predicate = NSPredicate(format: "date >= %@ AND isFPU == NO", startDate as NSDate)
                carbFR.sortDescriptors = [NSSortDescriptor(keyPath: \CarbEntryStored.date, ascending: true)]

                let carbEntries: [Date]
                do {
                    let stored = try context.fetch(carbFR)
                    carbEntries = stored.compactMap { entry -> Date? in
                        entry.date
                    }
                } catch {
                    debug(.default, "PatternDetector: failed to fetch carbs: \(error)")
                    carbEntries = []
                }

                return PatternDetector.detect(glucoseSamples: glucoseSamples, carbEntries: carbEntries)
            }
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

        // MARK: - LLM Analysis

        @MainActor
        func analyze() async {
            guard !isAnalyzing, sampleCount > 0 else { return }

            guard let service = LLMServiceFactory.makeService() else {
                llmNarrative = "No AI provider configured. Go to Settings → Services → AI Settings to add an API key."
                return
            }

            llmNarrative = nil
            isAnalyzing = true
            defer { isAnalyzing = false }

            let systemPrompt = """
            You are a warm and encouraging diabetes management assistant. \
            Analyze the glucose statistics and provide a 2-3 sentence retrospective. \
            Mention what went well and one pattern to watch. \
            Never suggest specific insulin doses, basal rates, or therapy settings changes. \
            Always recommend consulting a healthcare provider for medical decisions. \
            Be concise and use plain language.
            """

            let userMessage = ChatMessage(
                id: UUID(),
                role: .user,
                content: buildAnalysisPrompt(),
                timestamp: Date()
            )

            var narrative = ""
            do {
                for try await token in service.stream(messages: [userMessage], systemPrompt: systemPrompt) {
                    narrative += token
                    llmNarrative = narrative
                }
            } catch let error as LLMError {
                llmNarrative = error.localizedDescription
            } catch {
                llmNarrative = "Could not reach AI service. Check your API key in Settings → Services → AI Settings."
            }
        }

        private func buildAnalysisPrompt() -> String {
            let tir = tirResult
            return """
            My glucose data for the last \(selectedPeriod.days) days (\(sampleCount) readings):
            - Time In Range (70–180 mg/dL): \(String(format: "%.1f", tir.inRange))%
            - Time High (>180 mg/dL): \(String(format: "%.1f", tir.hyper))%
            - Time Low (<70 mg/dL): \(String(format: "%.1f", tir.hypo))%
            - Average glucose: \(Int(tir.average)) mg/dL

            Please give me a brief, warm retrospective of my glucose management for this period.
            """
        }
    }
}
