import CoreLocation
import HealthKit
import MapKit
import Observation
import RunloopCore
import SwiftUI

@MainActor
@Observable
final class RunWorkout: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    enum Phase: String, Codable {
        case idle, starting, running, paused, saving, saved, discarded, discardFailed, startFailed, saveFailed
    }

    private let store = HKHealthStore()
    let recording = RunRecording()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var savedHealthWorkout: HKWorkout?
    private(set) var needsLocationChoice = false
    private(set) var runID: UUID?
    private var startedAt: Date?
    private var activeStart: Date?
    private var accumulatedTime: TimeInterval = 0
    private var stoppedAt: Date?
    private var collectionEnded = false
    private var didBeginCollection = false
    private var finishInProgress = false

    private(set) var phase: Phase = .idle
    private(set) var route: SyncEnvelope<RouteTransfer>?
    private(set) var ownerID: UUID?
    private var healthDistance: Double = 0
    private(set) var pulse: PulseReading?
    private(set) var message: String?

    var isPresented: Bool { phase != .idle }
    var distance: Double { max(healthDistance, recording.distance) }

    func start(id: UUID, route: SyncEnvelope<RouteTransfer>?, ownerID: UUID?) {
        guard phase == .idle else { return }
        runID = id
        self.route = route
        self.ownerID = route?.payload.ownerID ?? ownerID
        phase = .starting
        Task {
            #if os(watchOS)
            let status = await recording.authorizationForStart()
            guard runID == id, phase == .starting else { return }
            guard status == .authorizedWhenInUse || status == .authorizedAlways else {
                needsLocationChoice = true
                return
            }
            #endif
            await startSession(recordsGPS: true)
        }
    }

    func resolveLocationChoice(recordWithoutGPS: Bool) {
        guard phase == .starting, needsLocationChoice else { return }
        needsLocationChoice = false
        if recordWithoutGPS {
            Task { await startSession(recordsGPS: false) }
        } else {
            reset()
        }
    }

    private func startSession(recordsGPS: Bool) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            failStarting("Salute non è disponibile su questo dispositivo.")
            return
        }

        do {
            let workout = HKObjectType.workoutType()
            let workoutRoute = HKSeriesType.workoutRoute()
            try await store.requestAuthorization(toShare: [workout, workoutRoute], read: [
                HKQuantityType(.distanceWalkingRunning), HKQuantityType(.heartRate), workout, workoutRoute
            ])
            // The authorization UI can close before the Watch store receives the new permission.
            for _ in 0..<10 where store.authorizationStatus(for: workout) != .sharingAuthorized {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard store.authorizationStatus(for: workout) == .sharingAuthorized else {
                failStarting("Consenti a Runloop di salvare gli allenamenti in Salute.")
                return
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .running
            configuration.locationType = .outdoor
            let newSession = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let newBuilder = newSession.associatedWorkoutBuilder()
            newBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            newSession.delegate = self
            newBuilder.delegate = self
            session = newSession
            builder = newBuilder

            guard let runID else { return }
            try recording.prepare(id: runID, recordsGPS: recordsGPS)
            let date = Date.now
            startedAt = date
            newSession.startActivity(with: date)
            try await newBuilder.beginCollection(at: date)
            guard phase == .starting else { return }
            didBeginCollection = true
            activeStart = date
            recording.resume(at: date, elapsed: 0)
            phase = .running
        } catch {
            failStarting("Impossibile avviare la corsa. Riprova tra poco.")
        }
    }

    func elapsed(at date: Date) -> TimeInterval {
        accumulatedTime + (activeStart.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    func togglePause() {
        switch phase {
        case .running: session?.pause()
        case .paused: session?.resume()
        default: break
        }
    }

    func stop() {
        guard phase == .running || phase == .paused else { return }
        phase = .saving
        session?.stopActivity(with: .now)
    }

    func discard() {
        guard phase == .running || phase == .paused || phase == .discardFailed else { return }
        freezeTime(at: .now)
        // Detach before ending: late HealthKit callbacks must never enter the save path.
        let abandoned = session
        session = nil
        builder?.discardWorkout()
        builder = nil
        abandoned?.end()
        do {
            try recording.discard()
            pulse = nil
            healthDistance = 0
            phase = .discarded
        } catch {
            message = "Impossibile rimuovere la traccia temporanea."
            phase = .discardFailed
        }
    }

    func retrySave() {
        guard phase == .saveFailed, let stoppedAt else { return }
        phase = .saving
        Task { await finish(at: stoppedAt) }
    }

    func close() {
        guard phase == .saved || phase == .discarded || phase == .startFailed else { return }
        reset()
    }

    private func reset() {
        route = nil
        ownerID = nil
        healthDistance = 0
        pulse = nil
        message = nil
        recording.clear()
        savedHealthWorkout = nil
        runID = nil
        startedAt = nil
        accumulatedTime = 0
        stoppedAt = nil
        collectionEnded = false
        didBeginCollection = false
        phase = .idle
    }

    private func freezeTime(at date: Date) {
        accumulatedTime = elapsed(at: date)
        activeStart = nil
    }

    private func failStarting(_ message: String) {
        let currentSession = session
        session = nil
        builder = nil
        currentSession?.end()
        recording.discardEmptyJournal()
        self.message = message
        phase = .startFailed
    }

    private func finish(at date: Date) async {
        guard !finishInProgress, let builder, let runID, let startedAt else { return }
        finishInProgress = true
        defer { finishInProgress = false }
        do {
            recording.pause()
            let points = try recording.points()
            let workout: HKWorkout
            if let savedHealthWorkout {
                workout = savedHealthWorkout
            } else {
                if !collectionEnded {
                    try await builder.endCollection(at: date)
                    collectionEnded = true
                }
                guard let result = try await builder.finishWorkout() else { throw CocoaError(.fileWriteUnknown) }
                savedHealthWorkout = result
                workout = result
            }
            healthDistance = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .meter()) ?? healthDistance
            let averageHeartRate = workout.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?
                .doubleValue(for: .count().unitDivided(by: .minute()))
            let record = RecordedWorkout(id: runID, ownerID: ownerID, routeID: route?.entityID,
                                         plannedRoute: route?.payload.geometry, healthKitID: workout.uuid,
                                         startedAt: startedAt, endedAt: date, activeDurationSeconds: elapsed(at: date),
                                         distanceMeters: distance, averageHeartRateBPM: averageHeartRate, points: points, source: .localDevice)
            try recording.save(record)
            let currentSession = session
            session = nil
            self.builder = nil
            currentSession?.end()
            message = await linkRoute(points, to: workout)
            phase = .saved
        } catch {
            message = savedHealthWorkout == nil ? "Salvataggio incompleto. Riprova."
                : "Corsa salvata in Salute. Riprova a salvare la copia Runloop."
            phase = .saveFailed
        }
    }

    private func linkRoute(_ points: [WorkoutPoint], to workout: HKWorkout) async -> String? {
        guard !points.isEmpty else { return recording.warning }
        let series = HKSeriesType.workoutRoute()
        guard store.authorizationStatus(for: series) == .sharingAuthorized else { return nil }
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        do {
            for start in stride(from: 0, to: points.count, by: 500) {
                let locations = points[start..<min(start + 500, points.count)].map { point in
                    CLLocation(coordinate: CLLocationCoordinate2D(latitude: point.coordinate.latitude, longitude: point.coordinate.longitude),
                               altitude: 0, horizontalAccuracy: point.horizontalAccuracy ?? -1, verticalAccuracy: -1,
                               course: -1, speed: point.speedMetersPerSecond ?? -1, timestamp: point.recordedAt)
                }
                try await routeBuilder.insertRouteData(locations)
            }
            _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
            return recording.warning
        } catch {
            return "Traccia salvata in Runloop. Salute non ha confermato la copia."
        }
    }

    private func handleState(_ state: HKWorkoutSessionState, at date: Date) {
        switch state {
        case .running where phase == .paused:
            activeStart = date
            recording.resume(at: date, elapsed: accumulatedTime)
            phase = .running
        case .paused where phase == .running:
            freezeTime(at: date)
            recording.pause()
            phase = .paused
        case .stopped, .ended:
            if phase == .starting {
                failStarting("La sessione è terminata prima dell’avvio. Riprova.")
            } else if didBeginCollection, stoppedAt == nil {
                freezeTime(at: date)
                stoppedAt = date
                phase = .saving
                Task { await finish(at: date) }
            }
        default: break
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            handleState(toState, at: date)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        Task { @MainActor in
            guard session === workoutSession else { return }
            if phase == .starting {
                failStarting("Salute non riesce ad avviare la corsa. Riprova.")
            } else if phase == .running || phase == .paused {
                handleState(.ended, at: .now)
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        let distanceType = HKQuantityType(.distanceWalkingRunning)
        let heartType = HKQuantityType(.heartRate)
        let meters = types.contains(distanceType)
            ? workoutBuilder.statistics(for: distanceType)?.sumQuantity()?.doubleValue(for: .meter()) : nil
        let stats = types.contains(heartType) ? workoutBuilder.statistics(for: heartType) : nil
        let reading = stats.flatMap { stat -> PulseReading? in
            guard let sample = stat.mostRecentQuantity(), let interval = stat.mostRecentQuantityDateInterval() else { return nil }
            return PulseReading(bpm: sample.doubleValue(for: .count().unitDivided(by: .minute())), measured: interval.end)
        }
        Task { @MainActor in
            guard builder === workoutBuilder else { return }
            if let meters { healthDistance = meters }
            if let reading, reading.measured >= (pulse?.measured ?? .distantPast) { pulse = reading }
        }
    }
}

struct RunLiveMap: View {
    let planned: [RouteCoordinate]
    let trail: [RouteCoordinate]
    @Environment(\.runloopAccent) private var accent

    var body: some View {
        if !planned.isEmpty || !trail.isEmpty {
            Map {
                if planned.count > 1 {
                    MapPolyline(coordinates: planned.map(\.location))
                        .stroke(RunloopStyle.text, style: StrokeStyle(lineWidth: 3, dash: [5, 4]))
                }
                if trail.count > 1 {
                    MapPolyline(coordinates: trail.map(\.location)).stroke(accent, lineWidth: 4)
                }
                if let point = trail.last {
                    Annotation("Posizione", coordinate: point.location) {
                        Circle().fill(accent).frame(width: 10, height: 10)
                            .overlay { Circle().stroke(.black, lineWidth: 1.5) }
                    }.annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(emphasis: .muted))
            #if os(iOS)
            .frame(height: 235)
            #else
            .frame(height: 120)
            #endif
            .clipShape(.rect(cornerRadius: RunloopStyle.radius))
            .accessibilityLabel(planned.isEmpty ? "Traccia della corsa" : "Percorso pianificato e traccia della corsa")
        }
    }
}
