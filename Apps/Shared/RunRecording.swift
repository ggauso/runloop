import CoreLocation
import Foundation
import Observation
import RunloopCore

@MainActor
@Observable
final class RunRecording: NSObject, CLLocationManagerDelegate {
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Runloop/Workouts", directoryHint: .isDirectory)
    }

    private let manager = CLLocationManager()
    private var journal: URL?
    private var recordsGPS = true
    private var permissionRequest: CheckedContinuation<CLAuthorizationStatus, Never>?

    func authorizationForStart() async -> CLAuthorizationStatus {
        guard manager.authorizationStatus == .notDetermined else { return manager.authorizationStatus }
        return await withCheckedContinuation { continuation in
            permissionRequest = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    private var isRecording = false
    private var activeInterval: (start: Date, elapsed: Double)?
    private var lastLocation: CLLocation?
    // The live map shows the latest continuous stretch. The journal keeps the entire run.
    private(set) var trail: [RouteCoordinate] = []
    private(set) var distance = 0.0
    private(set) var pointCount = 0
    private(set) var warning: String?

    override init() {
        super.init()
        manager.delegate = self
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.pausesLocationUpdatesAutomatically = false
        #endif
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 4
    }

    private static var journalRoot: URL {
        #if os(iOS)
        URL.applicationSupportDirectory.appending(path: "Runloop/ActiveRuns", directoryHint: .isDirectory)
        #else
        directory
        #endif
    }

    static var hasUnfinishedJournal: Bool {
        let files = FileManager.default
        let directories = (try? files.contentsOfDirectory(at: journalRoot, includingPropertiesForKeys: nil)) ?? []
        return directories.contains { directory in
            UUID(uuidString: directory.lastPathComponent) != nil &&
                files.fileExists(atPath: directory.appending(path: "points.jsonl").path)
        }
    }

    private static func journalDirectory(for id: UUID) -> URL {
        journalRoot.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func prepare(id: UUID, recordsGPS: Bool) throws {
        let directory = Self.journalDirectory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "points.jsonl")
        try Data().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        self.recordsGPS = recordsGPS
        journal = file
        trail = []
        distance = 0
        pointCount = 0
        warning = recordsGPS ? nil : "Corsa senza traccia GPS."
    }

    /// Reopen the existing GPS journal without replacing points captured before process recovery.
    func restore(id: UUID, recordsGPS: Bool) {
        let file = Self.journalDirectory(for: id).appending(path: "points.jsonl")
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                try prepare(id: id, recordsGPS: recordsGPS)
                return
            }
            self.recordsGPS = recordsGPS
            journal = file
            let bytes = try Data(contentsOf: file)
            let completeSize = bytes.lastIndex(of: 10).map { $0 + 1 } ?? 0
            if completeSize < bytes.count {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(completeSize))
            }
            let points = try Self.decodePoints(bytes.prefix(completeSize))
            pointCount = points.count
            var stretchStart = points.startIndex
            distance = 0
            for index in points.indices.dropFirst() {
                let a = points[index - 1], b = points[index]
                let gap = b.recordedAt.timeIntervalSince(a.recordedAt)
                if let from = a.activeElapsedSeconds, let to = b.activeElapsedSeconds,
                   gap > 0, gap <= 20, abs((to - from) - gap) < 0.001 {
                    distance += CLLocation(latitude: a.coordinate.latitude, longitude: a.coordinate.longitude)
                        .distance(from: CLLocation(latitude: b.coordinate.latitude, longitude: b.coordinate.longitude))
                } else {
                    stretchStart = index
                }
            }
            trail = points[stretchStart...].suffix(200).map(\.coordinate)
            warning = recordsGPS ? nil : "Corsa senza traccia GPS."
        } catch {
            self.recordsGPS = false
            warning = "La traccia GPS precedente non è disponibile."
        }
    }

    func resume(at start: Date, elapsed: Double) {
        guard recordsGPS, journal != nil else { return }
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
        trail = []
        distance = 0
        pointCount = 0
    }

    func points() throws -> [WorkoutPoint] {
        guard let journal else { return [] }
        let data = try Data(contentsOf: journal)
        let complete = data.lastIndex(of: 10).map { data[..<$0] } ?? Data()
        return try Self.decodePoints(complete)
    }

    private static func decodePoints(_ data: Data) throws -> [WorkoutPoint] {
        try data.split(separator: 10).map { try JSONDecoder().decode(WorkoutPoint.self, from: Data($0)) }
    }

    func save(_ workout: RecordedWorkout) throws {
        #if os(iOS)
        try PhoneWorkoutArchive(root: Self.directory).store(workout)
        if let journal { try? FileManager.default.removeItem(at: journal.deletingLastPathComponent()) }
        #else
        let directory = Self.directory.appending(path: workout.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(workout).write(to: directory.appending(path: "workout.json"),
                                                  options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if let journal { try? FileManager.default.removeItem(at: journal) }
        #endif
    }

    func discard(id: UUID) throws {
        pause()
        let directory = Self.journalDirectory(for: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        clear()
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
        case .denied:
            warning = "GPS disattivato. Abilita la posizione per Runloop in Impostazioni."
            manager.stopUpdatingLocation()
        case .restricted:
            warning = "GPS bloccato dalle restrizioni del dispositivo."
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
        var additions: [RouteCoordinate] = []
        var startsStretch = previous == nil
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
                    if time > 20 { startsStretch = true; additions.removeAll() }
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
                additions.append(coordinate)
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
            if startsStretch { trail = [] }
            trail.append(contentsOf: additions)
            if trail.count > 200 { trail.removeFirst(trail.count - 200) }
        } catch {
            pause()
            warning = "Non è stato possibile salvare nuovi punti GPS."
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = self.manager.authorizationStatus
            if status != .notDetermined, let request = permissionRequest {
                permissionRequest = nil
                request.resume(returning: status)
            }
            updateAuthorization()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in append(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        guard (error as? CLError)?.code == .denied else { return }
        Task { @MainActor in updateAuthorization() }
    }
}
