import Foundation

struct MacroEstimate {
    let carbs: Decimal
    let fat: Decimal
    let protein: Decimal
    let confidence: Double // 0.0–1.0
}

// Keyword-based meal → macro estimator. Each DB entry represents one food category.
// Matched categories are summed (treating each as a meal component).
// Keyword groups are sorted longest-first to prefer specific matches.
struct MealEstimator {
    private static let db: [(keywords: [String], carbs: Double, fat: Double, protein: Double)] = [
        // Grains / starches — specific combos first to prevent subset overlap
        (["fried rice"], 42, 12, 5),
        (["brown rice", "white rice"], 45, 1, 4),
        (["rice"], 45, 1, 4),
        (["pasta", "spaghetti", "penne", "fettuccine", "linguine", "noodle"], 40, 2, 7),
        (["french fries", "fries"], 40, 15, 4),
        (["mashed potato", "mash"], 30, 5, 4),
        (["sweet potato"], 26, 0, 2),
        (["baked potato", "potato"], 37, 0, 4),
        (["sandwich", "sub", "hoagie"], 40, 10, 20),
        (["burrito", "wrap", "tortilla"], 50, 12, 18),
        (["pizza"], 35, 12, 15),
        (["oatmeal", "porridge", "oat"], 27, 3, 5),
        (["granola bar", "protein bar", "energy bar"], 30, 8, 15),
        (["granola", "cereal"], 40, 5, 5),
        (["bagel"], 55, 2, 10),
        (["croissant"], 30, 20, 7),
        (["pancake", "waffle"], 40, 8, 8),
        (["bread", "toast", "slice"], 15, 1, 3),
        (["cracker", "chips", "crisps"], 20, 10, 2),
        (["taco", "tacos"], 35, 12, 18),
        // Proteins
        (["chicken breast", "grilled chicken"], 0, 5, 30),
        (["chicken"], 0, 10, 25),
        (["ground beef", "mince"], 0, 18, 22),
        (["beef", "steak", "burger", "hamburger"], 0, 20, 26),
        (["pork", "ham"], 0, 15, 22),
        (["bacon", "sausage", "bratwurst", "wurst", "hot dog"], 3, 25, 14),
        (["salmon", "tuna", "cod", "tilapia", "shrimp", "prawns", "seafood", "fish"], 0, 10, 25),
        (["scrambled eggs", "boiled egg", "omelette", "omelet", "egg", "eggs"], 2, 10, 12),
        (["tofu", "tempeh", "edamame"], 5, 8, 15),
        (["turkey"], 0, 3, 28),
        (["lamb", "veal"], 0, 20, 25),
        (["meatball", "meatballs", "bolognese"], 8, 15, 18),
        // Dairy
        (["cream cheese"], 3, 25, 5),
        (["cheese", "cheddar", "mozzarella", "parmesan", "feta", "gouda"], 2, 20, 14),
        (["greek yogurt", "quark"], 10, 1, 17),
        (["yogurt"], 15, 3, 10),
        (["milk"], 12, 8, 8),
        (["ice cream", "gelato"], 30, 14, 4),
        // Vegetables — low carb, skip unless dominant
        (["avocado"], 6, 21, 2),
        (["peas", "sweetcorn", "corn"], 20, 1, 4),
        (["beans", "lentils", "chickpeas", "legume"], 20, 1, 8),
        (["salad", "lettuce", "greens"], 5, 3, 2),
        (["broccoli", "cauliflower", "asparagus", "spinach", "kale"], 7, 1, 4),
        (["carrot", "carrots", "tomato", "tomatoes", "cucumber"], 8, 0, 1),
        // Fruits
        (["banana"], 27, 0, 1),
        (["apple", "pear"], 25, 0, 0),
        (["mango", "pineapple"], 25, 0, 1),
        (["grapes"], 20, 0, 0),
        (["orange", "mandarin", "clementine", "grapefruit"], 15, 0, 1),
        (["berries", "strawberry", "blueberry", "raspberry", "cherry"], 12, 0, 1),
        (["watermelon", "melon"], 12, 0, 1),
        // Mixed / cuisine
        (["stir fry", "stir-fry"], 20, 10, 20),
        (["curry", "dal", "daal"], 40, 12, 15),
        (["sushi", "maki", "roll"], 35, 2, 15),
        (["soup", "stew", "chowder"], 15, 8, 10),
        (["smoothie", "shake"], 40, 5, 8),
        (["juice"], 25, 0, 1),
        (["chocolate", "cake", "brownie", "muffin", "donut", "doughnut"], 40, 15, 4),
        (["cookie", "candy", "sweets"], 30, 10, 2),
        (["nuts", "almonds", "walnuts", "cashews", "pistachios"], 6, 18, 7),
        (["peanut butter", "almond butter"], 8, 16, 8),
        (["peanuts"], 6, 14, 7),
        (["hummus"], 12, 10, 5),
    ]

    func estimate(from text: String) -> MacroEstimate {
        let lower = text.lowercased()
        var totalCarbs = 0.0
        var totalFat = 0.0
        var totalProtein = 0.0
        var matchedCount = 0
        var consumedRanges: [Range<String.Index>] = []

        for entry in Self.db {
            guard let (_, range) = entry.keywords
                .sorted(by: { $0.count > $1.count }) // longest keyword wins
                .compactMap({ kw -> (String, Range<String.Index>)? in
                    guard let r = lower.range(of: kw) else { return nil }
                    return (kw, r)
                })
                .first(where: { _, r in !consumedRanges.contains(where: { $0.overlaps(r) }) })
            else { continue }

            totalCarbs += entry.carbs
            totalFat += entry.fat
            totalProtein += entry.protein
            matchedCount += 1
            consumedRanges.append(range)
        }

        guard matchedCount > 0 else {
            return MacroEstimate(carbs: 0, fat: 0, protein: 0, confidence: 0)
        }

        let confidence = min(1.0, Double(matchedCount) / 3.0)
        return MacroEstimate(
            carbs: Decimal(Int(totalCarbs.rounded())),
            fat: Decimal(Int(totalFat.rounded())),
            protein: Decimal(Int(totalProtein.rounded())),
            confidence: confidence
        )
    }
}
