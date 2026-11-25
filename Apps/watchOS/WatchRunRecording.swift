import CoreLocation
import Foundation
import Observation
import RunloopCore

@MainActor
@Observable
final class WatchRunRecording: NSObject, CLLocationManagerDelegate {
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Runloop/Workouts", directoryHint: .isDirectory)
    }

    private let manager = CLLocationManager()
    private var journal: URL?
    private var isRecording = false
    private var activeInterval: (start: Date, elapsed: Double)?
    private var lastLocation: CLLocation?
    private(set) var distance = 0.0
    private(set) var pointCount = 0
    private(set) var warning: String?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 4
    }

    func prepare(id: UUID) throws {
        let directory = Self.directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "points.jsonl")
        try Data().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        journal = file
        distance = 0
        pointCount = 0
        warning = nil
    }

    func resume(at start: Date, elapsed: Double) {
        guard journal != nil else { return }
        activeInterval = (start, elapsed)
        isRecording = true
        updateAuthorization()
    }

    func pause() {
        isRecording = false
        activeInterval = nil
        lastLocation = nil
        manager.stopUpdatingLocation()
    }

    func clear() {
        pause()
        journal = nil
        warning = nil
        distance = 0
        pointCount = 0
    }

    func points() throws -> [WorkoutPoint] {
        guard let journal else { return [] }
        let data = try Data(contentsOf: journal)
        let complete = data.lastIndex(of: 10).map { data[..<$0] } ?? Data()
        return try complete.split(separator: 10).map { try JSONDecoder().decode(WorkoutPoint.self, from: Data($0)) }
    }

    func save(_ workout: RecordedWorkout) throws {
        let directory = Self.directory.appending(path: workout.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(workout).write(to: directory.appending(path: "workout.json"),
                                                  options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if let journal { try? FileManager.default.removeItem(at: journal) }
    }

    func discardEmptyJournal() {
        if pointCount == 0, let journal { try? FileManager.default.removeItem(at: journal.deletingLastPathComponent()) }
        clear()
    }

    private func updateAuthorization() {
        guard isRecording else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            warning = manager.accuracyAuthorization == .reducedAccuracy ? "Attiva la posizione precisa per registrare la traccia." : nil
            manager.startUpdatingLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            warning = "Posizione non autorizzata. La corsa continua senza traccia GPS."
            manager.stopUpdatingLocation()
        @unknown default:
            manager.stopUpdatingLocation()
        }
    }

    private func append(_ locations: [CLLocation]) {
        guard isRecording, let interval = activeInterval, let journal else { return }
        var data = Data()
        var nextCount = pointCount
        var nextDistance = distance
        var previous = lastLocation
        let encoder = JSONEncoder()

        do {
            for location in locations {
                let coordinate = RouteCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                guard coordinate.isValid, (0...50).contains(location.horizontalAccuracy),
                      location.timestamp >= interval.start, location.timestamp.timeIntervalSinceNow <= 2 else { continue }
                if let previous {
                    let delta = location.distance(from: previous)
                    let time = location.timestamp.timeIntervalSince(previous.timestamp)
                    guard time > 0 else { continue }
                    if time <= 20 {
                        guard delta >= 3, delta / time <= 14 else { continue }
                        nextDistance += delta
                    }
                }
                let speed = location.speed.isFinite && location.speed >= 0 ? location.speed : nil
                let point = WorkoutPoint(sequence: nextCount, recordedAt: location.timestamp, coordinate: coordinate,
                                         activeElapsedSeconds: interval.elapsed + location.timestamp.timeIntervalSince(interval.start),
                                         horizontalAccuracy: location.horizontalAccuracy, speedMetersPerSecond: speed)
                data.append(try encoder.encode(point))
                data.append(10)
                nextCount += 1
                previous = location
            }
            guard !data.isEmpty else { return }
            let handle = try FileHandle(forWritingTo: journal)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            pointCount = nextCount
            distance = nextDistance
            lastLocation = previous
        } catch {
            pause()
            warning = "Non è stato possibile salvare nuovi punti GPS."
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in updateAuthorization() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in append(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard (error as? CLError)?.code == .denied else { return }
        Task { @MainActor in updateAuthorization() }
    }
}
