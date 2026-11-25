import Foundation
import Network
import Observation
import RunloopCore
import Supabase

@MainActor
@Observable
final class WorkoutCloudSync {
    enum Stage: String, Codable { case queued, synced, failed }

    private struct Entry: Codable {
        let owner: UUID
        var stage: Stage
    }

    private static let ledgerKey = "runloop.workoutCloudLedger"
    private var ledger: [UUID: Entry] = [:]
    private var ownerID: UUID?
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var deleting = Set<UUID>()
    private var consentByOwner: [String: Bool]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.ledgerKey),
           let saved = try? JSONDecoder().decode([UUID: Entry].self, from: data) {
            ledger = saved
        }
        consentByOwner = UserDefaults.standard.dictionary(forKey: "runloop.workoutHealthConsent") as? [String: Bool] ?? [:]
    }

    func configure(owner: UUID?) {
        guard ownerID != owner else { return }
        jobs.values.forEach { $0.cancel() }
        jobs = [:]
        ownerID = owner
    }

    func visible(_ workouts: [RecordedWorkout]) -> [RecordedWorkout] {
        workouts.filter { workout in
            let assigned = ledger[workout.id]?.owner ?? workout.ownerID
            return assigned == nil || assigned == ownerID
        }
    }

    func canAdopt(_ workout: RecordedWorkout) -> Bool {
        ownerID != nil && workout.ownerID == nil && ledger[workout.id] == nil
    }

    func adopt(_ workout: RecordedWorkout, client: SupabaseClient?) {
        guard let ownerID, canAdopt(workout) else { return }
        update(workout.id, owner: ownerID, stage: .queued)
        synchronize([workout], client: client)
    }

    func stage(for workout: RecordedWorkout) -> Stage? {
        guard let ownerID, let entry = ledger[workout.id], ownerID == entry.owner else { return nil }
        return entry.stage
    }

    var sharesHeartRate: Bool { ownerID.flatMap { consentByOwner[$0.uuidString] } ?? false }

    func setSharesHeartRate(_ allowed: Bool) {
        guard let ownerID else { return }
        consentByOwner[ownerID.uuidString] = allowed
        UserDefaults.standard.set(consentByOwner, forKey: "runloop.workoutHealthConsent")
    }

    func synchronize(_ workouts: [RecordedWorkout], client: SupabaseClient?) {
        guard let client, let ownerID else { return }
        for workout in workouts where (ledger[workout.id]?.owner ?? workout.ownerID) == ownerID {
            guard !deleting.contains(workout.id), jobs[workout.id] == nil, ledger[workout.id]?.stage != .synced else { continue }
            update(workout.id, owner: ownerID, stage: .queued)
            jobs[workout.id] = Task {
                do {
                    try await WorkoutCloudService(client: client).upload(workout, owner: ownerID, sharesHeartRate: sharesHeartRate)
                    guard !Task.isCancelled, self.ownerID == ownerID else { return }
                    update(workout.id, owner: ownerID, stage: .synced)
                } catch {
                    guard !Task.isCancelled, self.ownerID == ownerID else { return }
                    update(workout.id, owner: ownerID, stage: .failed)
                }
                jobs.removeValue(forKey: workout.id)
            }
        }
    }

    func remove(id: UUID, local: RecordedWorkout?, remoteOwner: UUID?, watch: PhoneWatchTransfer, client: SupabaseClient?) async throws {
        guard deleting.insert(id).inserted else { return }
        defer { deleting.remove(id) }
        if let job = jobs[id] {
            job.cancel()
            await job.value
            jobs.removeValue(forKey: id)
        }
        if let cloudOwner = ledger[id]?.owner ?? remoteOwner {
            guard let client, cloudOwner == ownerID else { throw CocoaError(.userCancelled) }
            struct Deletion: Encodable { let p_owner: UUID; let p_id: UUID }
            try await client.rpc("delete_recorded_workout", params: Deletion(p_owner: cloudOwner, p_id: id)).execute()
        }
        try watch.removeWorkout(id: id, originalOwner: local == nil ? remoteOwner : local?.ownerID)
        ledger.removeValue(forKey: id)
        persistLedger()
    }

    func monitorConnectivity(onReconnect: @MainActor @escaping () -> Void) async {
        let monitor = NWPathMonitor()
        let events = AsyncStream<Bool> { continuation in
            monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "runloop.workoutConnectivity"))
        }
        for await connected in events where connected { onReconnect() }
    }

    private func update(_ id: UUID, owner: UUID, stage: Stage) {
        ledger[id] = Entry(owner: owner, stage: stage)
        persistLedger()
    }

    private func persistLedger() {
        if let data = try? JSONEncoder().encode(ledger) {
            UserDefaults.standard.set(data, forKey: Self.ledgerKey)
        }
    }
}

private struct WorkoutCloudService {
    let client: SupabaseClient

    func upload(_ workout: RecordedWorkout, owner: UUID, sharesHeartRate: Bool) async throws {
        let summary = Summary(id: workout.id, route_id: workout.routeID, started_at: timestamp(workout.startedAt),
                              ended_at: timestamp(workout.endedAt), active_duration_s: Int(workout.activeDurationSeconds.rounded()),
                              distance_m: workout.distanceMeters, avg_pace_s_per_km: workout.averagePaceSecondsPerKilometer,
                              avg_heart_rate_bpm: sharesHeartRate ? workout.averageHeartRateBPM : nil, point_count: workout.points.count)
        let batchSize = 250
        for start in stride(from: 0, to: max(1, workout.points.count), by: batchSize) {
            try Task.checkCancellation()
            let end = min(start + batchSize, workout.points.count)
            let points = workout.points[start..<end].map { point in
                Point(sequence: point.sequence, recorded_at: timestamp(point.recordedAt), longitude: point.coordinate.longitude,
                      latitude: point.coordinate.latitude, active_elapsed_s: point.activeElapsedSeconds.map { Int($0.rounded()) },
                      speed_mps: point.speedMetersPerSecond)
            }
            let batch = Batch(p_owner: owner, p_workout: summary, p_points: points, p_final: end == workout.points.count)
            try await client.rpc("upload_workout_batch", params: batch).execute()
        }
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private struct Batch: Encodable {
        let p_owner: UUID
        let p_workout: Summary
        let p_points: [Point]
        let p_final: Bool
    }

    private struct Summary: Encodable {
        let id: UUID
        let route_id: UUID?
        let started_at: String
        let ended_at: String
        let active_duration_s: Int
        let distance_m: Double
        let avg_pace_s_per_km: Double?
        let avg_heart_rate_bpm: Double?
        let point_count: Int
    }

    private struct Point: Encodable {
        let sequence: Int
        let recorded_at: String
        let longitude: Double
        let latitude: Double
        let active_elapsed_s: Int?
        let speed_mps: Double?
    }
}
