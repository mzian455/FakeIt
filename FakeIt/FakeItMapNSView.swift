import AppKit
import CoreLocation
import MapKit
import QuartzCore
import SwiftUI

private let userReuse = "fakeit.user.pulse"
private let dropReuse = "fakeit.drop.pin"

final class UserPulseAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

final class DropPinAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

struct FakeItMapNSView: NSViewRepresentable {
    @ObservedObject var state: MapViewState
    var allowsMapSelection: Bool

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .hybridFlyover
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        map.showsScale = true
        map.showsUserLocation = false

        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapClick(_:)))
        map.addGestureRecognizer(click)

        context.coordinator.mapView = map
        context.coordinator.locationManager.delegate = context.coordinator
        context.coordinator.locationManager.desiredAccuracy = kCLLocationAccuracyBest
        context.coordinator.locationManager.requestWhenInUseAuthorization()
        context.coordinator.locationManager.startUpdatingLocation()

        let start = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
        let region = MKCoordinateRegion(center: start, latitudinalMeters: 2_000_000, longitudinalMeters: 2_000_000)
        map.setRegion(region, animated: false)

        return map
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncAnnotationsAndOverlays(in: mapView)
        context.coordinator.applyFlyIfNeeded(in: mapView)
        context.coordinator.applyDropAnimationIfNeeded()
        context.coordinator.applySuccessGlowIfNeeded()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate {
        var parent: FakeItMapNSView
        weak var mapView: MKMapView?
        let locationManager = CLLocationManager()

        private var userAnnotation: UserPulseAnnotation?
        private var dropAnnotation: DropPinAnnotation?
        private var accuracyCircle: MKCircle?
        private var lastAccuracySelection: CLLocationCoordinate2D?
        private var lastFlyID: UUID?
        private var lastDropAnimID: UUID?
        private weak var dropAnnotationView: MKAnnotationView?
        /// Avoid publishing pin overlay position every frame (prevents SwiftUI ↔ MapKit feedback loops).
        private var lastPublishedPinScreenPoint: CGPoint?
        private var lastUserLocationPublish: CLLocation?
        private var lastPublishedSearchRegion: MKCoordinateRegion?

        init(_ parent: FakeItMapNSView) {
            self.parent = parent
        }

        @objc func handleMapClick(_ gesture: NSClickGestureRecognizer) {
            guard parent.allowsMapSelection, let mapView else { return }
            guard gesture.state == .ended else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            parent.state.setSelectedCoordinate(coord, fly: true, dropAnimation: true, unlockSimulation: true)
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
            default:
                break
            }
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let loc = locations.last else { return }
            DispatchQueue.main.async {
                if self.userAnnotation == nil {
                    self.parent.state.userCoordinate = loc.coordinate
                    let ann = UserPulseAnnotation(coordinate: loc.coordinate)
                    self.userAnnotation = ann
                    self.mapView?.addAnnotation(ann)
                    self.mapView?.setCenter(loc.coordinate, animated: true)
                    self.lastUserLocationPublish = loc
                } else {
                    self.userAnnotation?.coordinate = loc.coordinate
                    let shouldPublish: Bool
                    if let prev = self.lastUserLocationPublish {
                        shouldPublish = loc.timestamp.timeIntervalSince(prev.timestamp) >= 1.5
                            || loc.distance(from: prev) >= 5
                    } else {
                        shouldPublish = true
                    }
                    if shouldPublish {
                        self.lastUserLocationPublish = loc
                        self.parent.state.userCoordinate = loc.coordinate
                    }
                }
            }
        }

        func syncAnnotationsAndOverlays(in mapView: MKMapView) {
            if let u = parent.state.userCoordinate {
                if userAnnotation == nil {
                    let ann = UserPulseAnnotation(coordinate: u)
                    userAnnotation = ann
                    mapView.addAnnotation(ann)
                } else {
                    userAnnotation?.coordinate = u
                }
            }

            if let sel = parent.state.selectedCoordinate {
                if dropAnnotation == nil {
                    let ann = DropPinAnnotation(coordinate: sel)
                    dropAnnotation = ann
                    mapView.addAnnotation(ann)
                } else {
                    if dropAnnotation?.coordinate.latitude != sel.latitude || dropAnnotation?.coordinate.longitude != sel.longitude {
                        dropAnnotation?.coordinate = sel
                    }
                }

                let needsNewCircle: Bool
                if let last = lastAccuracySelection {
                    needsNewCircle = abs(last.latitude - sel.latitude) > 1e-9
                        || abs(last.longitude - sel.longitude) > 1e-9
                } else {
                    needsNewCircle = accuracyCircle == nil
                }

                if needsNewCircle {
                    if let existing = accuracyCircle {
                        mapView.removeOverlay(existing)
                        accuracyCircle = nil
                    }
                    let circle = MKCircle(center: sel, radius: 1)
                    accuracyCircle = circle
                    lastAccuracySelection = sel
                    mapView.addOverlay(circle, level: .aboveRoads)
                }
            } else {
                lastAccuracySelection = nil
                lastPublishedPinScreenPoint = nil
                if let existing = accuracyCircle {
                    mapView.removeOverlay(existing)
                    accuracyCircle = nil
                }
                if let d = dropAnnotation {
                    mapView.removeAnnotation(d)
                    dropAnnotation = nil
                }
                if parent.state.pinOverlayScreenPoint != nil {
                    parent.state.pinOverlayScreenPoint = nil
                }
            }

            refreshPinOverlayPosition(mapView: mapView)
        }

        func refreshPinOverlayPosition(mapView: MKMapView) {
            guard let c = parent.state.selectedCoordinate else {
                if parent.state.pinOverlayScreenPoint != nil {
                    parent.state.pinOverlayScreenPoint = nil
                }
                lastPublishedPinScreenPoint = nil
                return
            }
            let pt = mapView.convert(c, toPointTo: mapView)
            if let prev = lastPublishedPinScreenPoint {
                let dx = pt.x - prev.x
                let dy = pt.y - prev.y
                if (dx * dx + dy * dy) < 0.25 {
                    return
                }
            }
            lastPublishedPinScreenPoint = pt
            if parent.state.pinOverlayScreenPoint != pt {
                parent.state.pinOverlayScreenPoint = pt
            }
        }

        func applyFlyIfNeeded(in mapView: MKMapView) {
            guard let id = parent.state.flyRequestID, id != lastFlyID, let target = parent.state.flyTarget else { return }
            lastFlyID = id

            let cam = mapView.camera.copy() as! MKMapCamera
            cam.centerCoordinate = target
            cam.centerCoordinateDistance = min(max(cam.centerCoordinateDistance, 800), 8000)
            cam.pitch = min(60, max(45, cam.pitch))
            mapView.setCamera(cam, animated: true)
        }

        func applyDropAnimationIfNeeded() {
            guard let id = parent.state.pinDropAnimationID, id != lastDropAnimID else { return }
            lastDropAnimID = id
            guard let v = dropAnnotationView else { return }
            v.setPinVisualScale(0.01)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
                ctx.allowsImplicitAnimation = true
                v.setPinVisualScale(1.15)
            } completionHandler: {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    ctx.allowsImplicitAnimation = true
                    v.setPinVisualScale(1.0)
                } completionHandler: {}
            }
        }

        func applySuccessGlowIfNeeded() {
            guard let v = dropAnnotationView else { return }
            if parent.state.pinSuccessGlow {
                v.layer?.shadowColor = NSColor.systemGreen.cgColor
                v.layer?.shadowRadius = 18
                v.layer?.shadowOpacity = 0.95
            } else {
                v.layer?.shadowOpacity = 0
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            if annotation is UserPulseAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: userReuse)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: userReuse)
                v.annotation = annotation
                v.canShowCallout = false
                v.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
                v.image = UserPulseAnnotationViewRenderer.image(size: 28)
                return v
            }
            if annotation is DropPinAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: dropReuse)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: dropReuse)
                v.annotation = annotation
                v.canShowCallout = false
                v.isDraggable = true
                v.image = DropPinAnnotationRenderer.image(size: 44)
                v.centerOffset = CGPoint(x: 0, y: -18)
                dropAnnotationView = v
                return v
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let r = MKCircleRenderer(circle: circle)
                r.strokeColor = NSColor(red: 0, green: 0.831, blue: 1, alpha: 0.55)
                r.fillColor = NSColor(red: 0, green: 0.831, blue: 1, alpha: 0.12)
                r.lineWidth = 1.5
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            guard let ann = view.annotation as? DropPinAnnotation else { return }
            if newState == .dragging {
                parent.state.updateSelectedCoordinateFromDrag(ann.coordinate)
                refreshPinOverlayPosition(mapView: mapView)
            }
            switch newState {
            case .ending, .canceling:
                view.setDragState(.none, animated: true)
                parent.state.updateSelectedCoordinateFromDrag(ann.coordinate)
                refreshPinOverlayPosition(mapView: mapView)
            default:
                break
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            refreshPinOverlayPosition(mapView: mapView)
            publishSearchRegionIfNeeded(mapView.region)
        }

        /// Avoid flooding SwiftUI with identical regions (pan/zoom fires often).
        private func publishSearchRegionIfNeeded(_ region: MKCoordinateRegion) {
            if let prev = lastPublishedSearchRegion,
               abs(prev.center.latitude - region.center.latitude) < 0.00025,
               abs(prev.center.longitude - region.center.longitude) < 0.00025,
               abs(prev.span.latitudeDelta - region.span.latitudeDelta) < prev.span.latitudeDelta * 0.02,
               abs(prev.span.longitudeDelta - region.span.longitudeDelta) < prev.span.longitudeDelta * 0.02 {
                return
            }
            lastPublishedSearchRegion = region
            parent.state.visibleMapRegion = region
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            for v in views {
                if v.annotation is DropPinAnnotation {
                    dropAnnotationView = v
                    applyDropAnimationIfNeeded()
                    applySuccessGlowIfNeeded()
                } else if v.annotation is UserPulseAnnotation {
                    UserPulseLayerAnimator.attach(to: v)
                }
            }
        }
    }
}

// MARK: - Pin images

private enum DropPinAnnotationRenderer {
    static func image(size: CGFloat) -> NSImage? {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let path = NSBezierPath()
        let w = size
        let tip = CGPoint(x: w / 2, y: 4)
        let top = CGPoint(x: w / 2, y: w - 6)
        path.move(to: tip)
        path.line(to: CGPoint(x: w * 0.22, y: w * 0.42))
        path.curve(to: CGPoint(x: w * 0.78, y: w * 0.42), controlPoint1: CGPoint(x: w * 0.18, y: w * 0.55), controlPoint2: CGPoint(x: w * 0.82, y: w * 0.55))
        path.line(to: tip)
        NSColor(red: 0, green: 0.831, blue: 1, alpha: 1).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
        let dot = NSBezierPath(ovalIn: NSRect(x: w / 2 - 4, y: w * 0.52, width: 8, height: 8))
        NSColor.white.setFill()
        dot.fill()
        img.unlockFocus()
        return img
    }
}

private enum UserPulseAnnotationViewRenderer {
    static func image(size: CGFloat) -> NSImage? {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let outer = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: size - 4, height: size - 4))
        NSColor.systemBlue.withAlphaComponent(0.35).setFill()
        outer.fill()
        let inner = NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: size - 14, height: size - 14))
        NSColor.systemBlue.setFill()
        inner.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        inner.lineWidth = 1.5
        inner.stroke()
        img.unlockFocus()
        return img
    }
}

private extension MKAnnotationView {
    func setPinVisualScale(_ s: CGFloat) {
        layer?.transform = CATransform3DMakeScale(s, s, 1)
    }
}

private enum UserPulseLayerAnimator {
    static func attach(to view: MKAnnotationView) {
        guard let layer = view.layer else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.22
        scale.duration = 1.15
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(scale, forKey: "fakeit.userPulse.scale")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.72
        fade.duration = 1.15
        fade.autoreverses = true
        fade.repeatCount = .infinity
        layer.add(fade, forKey: "fakeit.userPulse.opacity")
    }
}
