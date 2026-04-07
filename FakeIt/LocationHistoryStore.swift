import Foundation

final class LocationHistoryStore {
    private let key: String
    private let maxCount: Int

    init(key: String = "fakeit.spoofHistory", maxCount: Int = 10) {
        self.key = key
        self.maxCount = maxCount
    }

    func load() -> [SavedSpoofLocation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedSpoofLocation].self, from: data) else {
            return []
        }
        return list
    }

    func save(_ locations: [SavedSpoofLocation]) {
        let trimmed = Array(locations.prefix(maxCount))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func prepend(_ entry: SavedSpoofLocation) {
        var list = load()
        list.removeAll { abs($0.latitude - entry.latitude) < 1e-8 && abs($0.longitude - entry.longitude) < 1e-8 }
        list.insert(entry, at: 0)
        save(list)
    }

    func remove(id: UUID) {
        var list = load()
        list.removeAll { $0.id == id }
        save(list)
    }

    func clearAll() {
        save([])
    }
}
