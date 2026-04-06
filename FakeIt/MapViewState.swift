import AppKit
import Combine
import CoreGraphics
import CoreLocation
import Foundation
import MapKit

final class MapViewState: ObservableObject {
    @Published var selectedCoordinate: CLLocationCoordinate2D?
    @Published var userCoordinate: CLLocationCoordinate2D?
    /// Visible map region — drives search relevance (Apple Maps–style local bias).
    @Published var visibleMapRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
        span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
    )
    /// Point in the map view’s bounds (top-left origin) for floating pin info UI.
    @Published var pinOverlayScreenPoint: CGPoint?
    @Published var addressLine: String = "—"
    @Published var elevationText: String = "—"
    @Published var spoofHUDTitle: String = "Real Location"
    @Published var isSpoofActive: Bool = false
    @Published var pinSuccessGlow: Bool = false
    @Published var flyRequestID: UUID?
    @Published var flyTarget: CLLocationCoordinate2D?
    @Published var pinDropAnimationID: UUID?
    @Published var mapRefreshToken: UUID = UUID()
    /// After "Go to location", placing the pin on the map, or applying coordinates — enables device simulation.
    @Published var allowSimulateAtPin: Bool = false

    private let geocoder = CLGeocoder()
    private var geocodeWorkItem: DispatchWorkItem?

    func setSelectedCoordinate(_ coord: CLLocationCoordinate2D, fly: Bool, dropAnimation: Bool, unlockSimulation: Bool = false) {
        selectedCoordinate = coord
        if unlockSimulation {
            allowSimulateAtPin = true
        }
        if fly {
            flyTarget = coord
            flyRequestID = UUID()
        }
        if dropAnimation {
            pinDropAnimationID = UUID()
        }
        scheduleReverseGeocode(for: coord)
    }

    func updateSelectedCoordinateFromDrag(_ coord: CLLocationCoordinate2D) {
        selectedCoordinate = coord
        allowSimulateAtPin = true
        scheduleReverseGeocode(for: coord)
    }

    func invalidateSimulationUnlock() {
        allowSimulateAtPin = false
    }

    func clearSelection() {
        selectedCoordinate = nil
        pinOverlayScreenPoint = nil
        addressLine = "—"
        elevationText = "—"
        allowSimulateAtPin = false
    }

    private func scheduleReverseGeocode(for coord: CLLocationCoordinate2D) {
        geocodeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.reverseGeocode(coord)
        }
        geocodeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func reverseGeocode(_ coord: CLLocationCoordinate2D) {
        geocoder.cancelGeocode()
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        geocoder.reverseGeocodeLocation(loc) { [weak self] marks, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let p = marks?.first {
                    let parts = [p.name, p.locality, p.administrativeArea, p.country]
                        .compactMap { $0 }
                    self.addressLine = parts.isEmpty ? "Unknown place" : parts.joined(separator: ", ")
                } else {
                    self.addressLine = "Unknown place"
                }
            }
        }
    }

    func coordinatePairString() -> String {
        guard let c = selectedCoordinate else { return "—" }
        return String(format: "%.6f, %.6f", c.latitude, c.longitude)
    }

    func copyCoordinatesToPasteboard() {
        guard let c = selectedCoordinate else { return }
        let s = String(format: "%.6f, %.6f", c.latitude, c.longitude)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

extension MKCoordinateRegion: @retroactive Equatable {
    public static func == (lhs: MKCoordinateRegion, rhs: MKCoordinateRegion) -> Bool {
        lhs.center.latitude == rhs.center.latitude
            && lhs.center.longitude == rhs.center.longitude
            && lhs.span.latitudeDelta == rhs.span.latitudeDelta
            && lhs.span.longitudeDelta == rhs.span.longitudeDelta
    }
}
