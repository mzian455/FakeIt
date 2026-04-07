import Combine
import CoreLocation
import Foundation
import MapKit

final class SearchCompleterModel: NSObject, ObservableObject {
    @Published var queryFragment: String = ""
    @Published var completions: [MKLocalSearchCompletion] = []
    @Published var isSearching: Bool = false

    private let completer = MKLocalSearchCompleter()
    private var cancellables = Set<AnyCancellable>()
    private var regionBiasWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        if #available(macOS 13.0, *) {
            completer.pointOfInterestFilter = .includingAll
        }
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 360)
        )

        $queryFragment
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] q in
                self?.completer.queryFragment = q
                self?.isSearching = !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .store(in: &cancellables)
    }

    /// Clears the field, suggestion list, and completer state immediately (no debounce wait).
    func clearSearch() {
        queryFragment = ""
        completions = []
        isSearching = false
        completer.queryFragment = ""
    }

    /// Keep suggestions biased to what the user sees (same idea as Apple Maps).
    func updateMapRegion(_ region: MKCoordinateRegion) {
        regionBiasWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.completer.region = region
        }
        regionBiasWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    func resolve(_ completion: MKLocalSearchCompletion, handler: @escaping (Result<MKMapItem, Error>) -> Void) {
        let request = MKLocalSearch.Request(completion: completion)
        request.region = completer.region
        if #available(macOS 13.0, *) {
            request.resultTypes = [.address, .pointOfInterest]
        }
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            if let error {
                handler(.failure(error))
                return
            }
            guard let item = response?.mapItems.first else {
                handler(.failure(NSError(domain: "FakeIt", code: 1, userInfo: [NSLocalizedDescriptionKey: "No results"])))
                return
            }
            handler(.success(item))
        }
    }

    /// Full query search (Return key) — matches typed text like the Maps search field, not only completions.
    func searchNaturalLanguage(
        query: String,
        biasRegion: MKCoordinateRegion,
        handler: @escaping (Result<MKMapItem, Error>) -> Void
    ) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            handler(.failure(NSError(domain: "FakeIt", code: 2, userInfo: [NSLocalizedDescriptionKey: "Empty query"])))
            return
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        // Slightly widen tiny spans so “world view” still returns useful hits.
        var region = biasRegion
        let minLat = 0.08
        let minLon = 0.08
        if region.span.latitudeDelta < minLat {
            region.span.latitudeDelta = minLat
        }
        if region.span.longitudeDelta < minLon {
            region.span.longitudeDelta = minLon
        }
        request.region = region
        if #available(macOS 13.0, *) {
            request.resultTypes = [.address, .pointOfInterest]
            request.pointOfInterestFilter = .includingAll
        }

        let search = MKLocalSearch(request: request)
        search.start { [trimmed] response, error in
            if let error {
                handler(.failure(error))
                return
            }
            let items = response?.mapItems ?? []
            guard let best = Self.pickBestMapItem(items, query: trimmed, regionCenter: region.center) else {
                handler(.failure(NSError(domain: "FakeIt", code: 3, userInfo: [NSLocalizedDescriptionKey: "No results"])))
                return
            }
            handler(.success(best))
        }
    }

    private static func pickBestMapItem(_ items: [MKMapItem], query: String, regionCenter: CLLocationCoordinate2D) -> MKMapItem? {
        guard !items.isEmpty else { return nil }
        if items.count == 1 { return items.first }

        let q = query.lowercased()
        let centerLoc = CLLocation(latitude: regionCenter.latitude, longitude: regionCenter.longitude)

        return items.min { a, b in
            let scoreA = relevanceScore(item: a, query: q, center: regionCenter)
            let scoreB = relevanceScore(item: b, query: q, center: regionCenter)
            if scoreA != scoreB { return scoreA < scoreB }
            let da = distanceFromCenter(item: a, center: centerLoc)
            let db = distanceFromCenter(item: b, center: centerLoc)
            return da < db
        }
    }

    private static func relevanceScore(item: MKMapItem, query: String, center: CLLocationCoordinate2D) -> Double {
        var score = distanceFromCenter(item: item, center: CLLocation(latitude: center.latitude, longitude: center.longitude))
        if let name = item.name?.lowercased(), name.contains(query) { score *= 0.65 }
        if let title = item.placemark.title?.lowercased(), title.contains(query) { score *= 0.75 }
        return score
    }

    private static func distanceFromCenter(item: MKMapItem, center: CLLocation) -> Double {
        let c = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(c) else { return .greatestFiniteMagnitude }
        return CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: center)
    }

    static func displayTitle(for item: MKMapItem) -> String {
        if let name = item.name, !name.isEmpty {
            let sub = shortPlacemarkSubtitle(item.placemark)
            if let sub, !sub.isEmpty, !name.localizedCaseInsensitiveContains(sub) {
                return "\(name) — \(sub)"
            }
            return name
        }
        if let t = item.placemark.title, !t.isEmpty { return t }
        return formattedPostalLine(item.placemark)
    }

    private static func shortPlacemarkSubtitle(_ p: MKPlacemark) -> String? {
        let parts = [p.locality, p.administrativeArea, p.country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func formattedPostalLine(_ p: MKPlacemark) -> String {
        let parts = [
            p.subThoroughfare, p.thoroughfare,
            p.locality, p.administrativeArea, p.postalCode, p.country
        ].compactMap { $0 }
        return parts.isEmpty ? "Selected place" : parts.joined(separator: ", ")
    }
}

extension SearchCompleterModel: MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        DispatchQueue.main.async {
            self.completions = completer.results
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.completions = []
        }
    }
}
