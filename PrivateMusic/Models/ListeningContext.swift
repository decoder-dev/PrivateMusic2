import Foundation

enum ListeningContext: String, CaseIterable, Identifiable {
    case road, work, evening
    var id: String { rawValue }
    var title: String {
        switch self {
        case .road: L10n.text("context.road")
        case .work: L10n.text("context.work")
        case .evening: L10n.text("context.evening")
        }
    }
    var symbol: String {
        switch self { case .road: "car.fill"; case .work: "laptopcomputer"; case .evening: "moon.fill" }
    }
    var fallbackMood: MixMoodPreference { self == .road ? .energetic : .calm }
    private var markers: [String] {
        switch self {
        case .road: ["дорог", "поездк", "drive", "driving", "road"]
        case .work: ["работ", "учёб", "учеб", "focus", "study", "work"]
        case .evening: ["вечер", "спокой", "evening", "relax", "calm"]
        }
    }
    func matches(_ title: String) -> Bool {
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return markers.contains { marker in
            // "Work" is a word; "Workout" and "Broadway" are different contexts.
            if marker.utf8.allSatisfy({ $0 < 128 }) { return words.contains(marker) }
            return title.localizedCaseInsensitiveContains(marker)
        }
    }

    func selection(tuning: MixTuning?, mixes: [MusicMix]) -> ListeningContextSelection {
        if let tuning {
            for category in tuning.categories {
                if let option = category.options.first(where: { matches($0.title) }) {
                    return .tuned(tuning.mix(applying: [category.id: [option.id]], to: .common))
                }
            }
        }
        if let mix = mixes.first(where: { matches($0.title) }) { return .catalog(mix) }
        return .mood(fallbackMood)
    }
}

enum ListeningContextSelection {
    case tuned(MusicMix), catalog(MusicMix), mood(MixMoodPreference)
    var detail: String {
        switch self {
        case .tuned(let mix), .catalog(let mix): mix.title
        case .mood(let mood): mood.title
        }
    }
}
