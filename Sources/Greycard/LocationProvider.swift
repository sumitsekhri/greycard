import CoreLocation
import Foundation

/// One-shot "use my current location" for sunrise/sunset. Optional: the schedule
/// works from the saved coordinates without ever asking for location access.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    typealias Completion = (Result<(lat: Double, lon: Double, name: String), Error>) -> Void

    private let manager = CLLocationManager()
    private var completion: Completion?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestOnce(_ completion: @escaping Completion) {
        self.completion = completion
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()   // continues in locationManagerDidChangeAuthorization
        case .denied, .restricted:
            finish(.failure(LocationError.denied))
        default:
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard completion != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: finish(.failure(LocationError.denied))
        default: manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            let name = marks?.first?.locality ?? String(format: "%.2f, %.2f", lat, lon)
            self?.finish(.success((lat, lon, name)))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<(lat: Double, lon: Double, name: String), Error>) {
        let c = completion
        completion = nil
        DispatchQueue.main.async { c?(result) }
    }

    enum LocationError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Location access is off for Greycard. Allow it in System Settings › Privacy & Security › Location Services, or keep the saved location."
        }
    }
}
