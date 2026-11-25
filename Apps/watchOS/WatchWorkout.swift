import CoreLocation
import HealthKit
import Observation
import RunloopCore
import SwiftUI

@MainActor
@Observable
final class WatchWorkout: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    enum Phase: Equatable {
        case idle, starting, running, paused, saving, saved, startFailed, saveFailed
    }

    private let store = HKHealthStore()
    let recording = WatchRunRecording()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var savedHealthWorkout: HKWorkout?
    private var runID: UUID?
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
    private(set) var heartRate: Double?
    private(set) var message: String?

    var isPresented: Bool { phase != .idle }
    var distance: Double { max(healthDistance, recording.distance) }

    func start(route: SyncEnvelope<RouteTransfer>?, ownerID: UUID?) {
        guard phase == .idle else { return }
        self.route = route
        self.ownerID = route?.payload.ownerID ?? ownerID
        phase = .starting
        Task { await startSession() }
    }

    private func startSession() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            failStarting("Salute non è disponibile su questo Watch.")
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

            let id = UUID()
            try recording.prepare(id: id)
            runID = id
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

    func retrySave() {
        guard phase == .saveFailed, let stoppedAt else { return }
        phase = .saving
        Task { await finish(at: stoppedAt) }
    }

    func close() {
        guard phase == .saved || phase == .startFailed else { return }
        route = nil
        ownerID = nil
        healthDistance = 0
        heartRate = nil
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
                                         distanceMeters: distance, averageHeartRateBPM: averageHeartRate, points: points)
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
            if phase == .starting { failStarting("Salute non riesce ad avviare la corsa. Riprova.") }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        let distanceType = HKQuantityType(.distanceWalkingRunning)
        let heartType = HKQuantityType(.heartRate)
        let meters = types.contains(distanceType)
            ? workoutBuilder.statistics(for: distanceType)?.sumQuantity()?.doubleValue(for: .meter()) : nil
        let beats = types.contains(heartType)
            ? workoutBuilder.statistics(for: heartType)?.mostRecentQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())) : nil
        Task { @MainActor in
            guard builder === workoutBuilder else { return }
            if let meters { healthDistance = meters }
            if let beats { heartRate = beats }
        }
    }
}

struct WatchWorkoutView: View {
    var workout: WatchWorkout
    @State private var confirmsEnd = false
    @ScaledMetric(relativeTo: .title) private var clockSize = 35.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(workout.route?.payload.name ?? "Corsa libera")
                    .font(.footnote.weight(.heavy))
                    .accessibilityAddTraits(.isHeader)
                switch workout.phase {
                case .starting:
                    ProgressView("Avvio corsa…")
                case .running, .paused:
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        metrics(at: context.date)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { workoutActions }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(spacing: 6) { workoutActions }
                    }
                    if let warning = workout.recording.warning {
                        Text(warning).font(.caption2).foregroundStyle(RunloopStyle.muted)
                    }
                case .saving:
                    ProgressView("Salvataggio…")
                case .saved:
                    Label("Salvata in Salute", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(RunloopStyle.accent)
                    metrics(at: .now)
                    if let message = workout.message { Text(message).font(.caption2) }
                    Button("Fine") { workout.close() }.buttonStyle(RunloopButtonStyle())
                case .startFailed:
                    Text(workout.message ?? "Impossibile avviare la corsa.")
                    Button("Chiudi") { workout.close() }.buttonStyle(RunloopButtonStyle(kind: .secondary))
                case .saveFailed:
                    Text(workout.message ?? "Impossibile salvare la corsa.")
                    Button("Riprova") { workout.retrySave() }.buttonStyle(RunloopButtonStyle())
                case .idle:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .runloopCanvas()
        .sensoryFeedback(trigger: workout.phase) { previous, current in
            if current == .saved { return .success }
            if current == .paused || (previous == .paused && current == .running) { return .selection }
            return nil
        }
        .confirmationDialog("Terminare la corsa?", isPresented: $confirmsEnd, titleVisibility: .visible) {
            Button("Termina corsa", role: .destructive) { workout.stop() }
            Button("Continua", role: .cancel) {}
        }
    }

    @ViewBuilder private var workoutActions: some View {
        Button(workout.phase == .paused ? "Riprendi" : "Pausa",
               systemImage: workout.phase == .paused ? "play.fill" : "pause.fill") {
            workout.togglePause()
        }
        .buttonStyle(RunloopButtonStyle(kind: workout.phase == .paused ? .primary : .secondary))
        Button("Termina", role: .destructive) { confirmsEnd = true }
            .buttonStyle(RunloopButtonStyle(kind: .destructive))
    }

    private func metrics(at date: Date) -> some View {
        let elapsed = workout.elapsed(at: date)
        let paused = workout.phase == .paused
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Label(paused ? "In pausa" : "Tempo attivo",
                      systemImage: paused ? "pause.circle.fill" : "timer")
                    .font(.caption2.weight(.semibold)).foregroundStyle(RunloopStyle.muted)
                Text(Duration.seconds(elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                    .font(.system(size: clockSize, weight: .black))
                    .monospacedDigit().tracking(-1.6)
                    .foregroundStyle(workout.phase == .running ? RunloopStyle.accent : RunloopStyle.text)
            }
            .accessibilityElement(children: .combine)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { secondaryMetrics(elapsed: elapsed) }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) { secondaryMetrics(elapsed: elapsed) }
            }
            if let heartRate = workout.heartRate {
                Label("\(heartRate.formatted(.number.precision(.fractionLength(0)))) bpm", systemImage: "heart")
                    .font(.footnote.weight(.bold)).monospacedDigit()
            }
        }
    }

    @ViewBuilder private func secondaryMetrics(elapsed: TimeInterval) -> some View {
        metric("Distanza", watchDistance(workout.distance))
        if workout.distance > 0, elapsed > 0,
           let seconds = Int(exactly: (elapsed / workout.distance * 1000).rounded(.down)) {
            metric("Passo medio", "\(seconds / 60):\(String(format: "%02d", seconds % 60)) /km")
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption2).foregroundStyle(RunloopStyle.muted)
            Text(value).font(.footnote.weight(.heavy)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
