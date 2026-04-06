import Foundation

enum SpoofButtonPhase: Equatable {
    case idle
    case injecting
    case success
    case failure(String)
}

struct SavedSpoofLocation: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var savedAt: Date

    init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double, savedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.savedAt = savedAt
    }
}
