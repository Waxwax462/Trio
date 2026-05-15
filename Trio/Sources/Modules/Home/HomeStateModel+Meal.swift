import Foundation

extension Home.StateModel {
    func logMeal(carbs: Decimal, fat: Decimal?, protein: Decimal?, note: String?) {
        let entry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: Date(),
            actualDate: nil,
            carbs: carbs,
            fat: fat,
            protein: protein,
            note: note,
            enteredBy: CarbsEntry.local,
            isFPU: false,
            fpuID: nil
        )
        Task {
            try? await carbsStorage.storeCarbs([entry], areFetchedFromRemote: false)
        }
    }
}
