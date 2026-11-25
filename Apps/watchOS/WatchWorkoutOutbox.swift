import Foundation
import Observation
import RunloopCore
import WatchConnectivity

@MainActor
@Observable
final class WatchWorkoutOutbox {
    private var inFlight = Set<UUID>()
    private var received = Set<WorkoutReceipt>()
    private(set) var pendingCount = 0
    private(set) var needsRetry = false

    private var pending: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: WatchRunRecording.directory, includingPropertiesForKeys: nil)) ?? []
        return files.map { $0.appending(path: "workout.json") }.filter { workout in
            FileManager.default.fileExists(atPath: workout.path)
                && !FileManager.default.fileExists(atPath: workout.deletingLastPathComponent().appending(path: "received.json").path)
        }
    }

    func refresh() { pendingCount = pending.count }

    func flush(using session: WCSession) {
        let workouts = pending
        pendingCount = workouts.count
        guard !workouts.isEmpty, session.activationState == .activated else { return }
        #if targetEnvironment(simulator)
        guard session.isReachable else { return }
        #else
        guard session.isCompanionAppInstalled else { return }
        let queued = session.outstandingFileTransfers.compactMap { $0.file.metadata?[WorkoutTransfer.metadataKey] as? String }
        #endif
        needsRetry = false
        for file in workouts {
            do {
                let workout = try JSONDecoder().decode(RecordedWorkout.self, from: Data(contentsOf: file))
                #if targetEnvironment(simulator)
                guard !inFlight.contains(workout.id) else { continue }
                #else
                guard !queued.contains(workout.id.uuidString) else { continue }
                #endif
                let data = try WorkoutTransfer.encode(workout)
                guard data.count <= WorkoutTransfer.byteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
                let receipt = WorkoutReceipt(workoutID: workout.id, ownerID: workout.ownerID)
                #if targetEnvironment(simulator)
                guard data.count <= 60_000 else { throw CocoaError(.fileWriteOutOfSpace) }
                inFlight.insert(workout.id)
                session.sendMessageData(data) { [weak self] reply in
                    let result = try? JSONDecoder().decode(WorkoutReceipt.self, from: reply)
                    Task { @MainActor in
                        self?.inFlight.remove(workout.id)
                        if result == receipt { self?.confirm(receipt) }
                        else { self?.needsRetry = true }
                    }
                } errorHandler: { [weak self] _ in
                    Task { @MainActor in
                        self?.inFlight.remove(workout.id)
                        self?.needsRetry = true
                    }
                }
                #else
                let transfer = file.deletingLastPathComponent().appending(path: "transfer.json")
                try data.write(to: transfer, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                session.transferFile(transfer, metadata: [WorkoutTransfer.metadataKey: workout.id.uuidString])
                #endif
            } catch {
                needsRetry = true
            }
        }
    }

    func confirm(_ receipt: WorkoutReceipt) {
        guard !received.contains(receipt) else { return }
        let directory = WatchRunRecording.directory.appending(path: receipt.workoutID.uuidString)
        let file = directory.appending(path: "workout.json")
        do {
            let workout = try JSONDecoder().decode(RecordedWorkout.self, from: Data(contentsOf: file))
            guard workout.id == receipt.workoutID, workout.ownerID == receipt.ownerID else { return }
            try JSONEncoder().encode(receipt).write(to: directory.appending(path: "received.json"), options: .atomic)
            received.insert(receipt)
            try? FileManager.default.removeItem(at: directory.appending(path: "transfer.json"))
            refresh()
        } catch {
            needsRetry = true
        }
    }

    func noteFailedDelivery(for id: UUID) {
        if pending.contains(where: { $0.deletingLastPathComponent().lastPathComponent == id.uuidString }) {
            needsRetry = true
        }
    }

    func delete(_ receipt: WorkoutReceipt, currentOwner: UUID?) throws {
        let directory = WatchRunRecording.directory.appending(path: receipt.workoutID.uuidString)
        let file = directory.appending(path: "workout.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let workout = try JSONDecoder().decode(RecordedWorkout.self, from: Data(contentsOf: file))
        guard workout.id == receipt.workoutID,
              workout.ownerID == receipt.ownerID || (workout.ownerID == nil && receipt.ownerID == currentOwner) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: directory)
        received.remove(receipt)
        refresh()
    }
}
