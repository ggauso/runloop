import Foundation

public struct WorkoutPoint: Codable, Equatable, Sendable {
    public let sequence: Int
    public let recordedAt: Date
    public let coordinate: RouteCoordinate
    public let activeElapsedSeconds: Double?
    public let horizontalAccuracy: Double?
    public let speedMetersPerSecond: Double?

    public init(sequence: Int, recordedAt: Date, coordinate: RouteCoordinate, activeElapsedSeconds: Double?,
                horizontalAccuracy: Double?, speedMetersPerSecond: Double?) {
        self.sequence = sequence
        self.recordedAt = recordedAt
        self.coordinate = coordinate
        self.activeElapsedSeconds = activeElapsedSeconds
        self.horizontalAccuracy = horizontalAccuracy
        self.speedMetersPerSecond = speedMetersPerSecond
    }
}

public enum WorkoutSource: String, Codable, Sendable { case phone, watch }

public struct RecordedWorkout: Codable, Identifiable, Sendable {
    public let id: UUID
    public let ownerID: UUID?
    public let routeID: UUID?
    public let plannedRoute: RouteGeometry?
    public let source: WorkoutSource?
    public let healthKitID: UUID?
    public let startedAt: Date
    public let endedAt: Date
    public let activeDurationSeconds: Double
    public let distanceMeters: Double
    public let averageHeartRateBPM: Double?
    public let points: [WorkoutPoint]

    public var averagePaceSecondsPerKilometer: Double? {
        guard distanceMeters > 0, activeDurationSeconds > 0 else { return nil }
        return activeDurationSeconds / distanceMeters * 1000
    }

    public init(id: UUID, ownerID: UUID?, routeID: UUID?, plannedRoute: RouteGeometry?, healthKitID: UUID?,
                startedAt: Date, endedAt: Date, activeDurationSeconds: Double, distanceMeters: Double,
                averageHeartRateBPM: Double?, points: [WorkoutPoint], source: WorkoutSource? = nil) {
        self.source = source
        self.id = id
        self.ownerID = ownerID
        self.routeID = routeID
        self.plannedRoute = plannedRoute
        self.healthKitID = healthKitID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeDurationSeconds = activeDurationSeconds
        self.distanceMeters = distanceMeters
        self.averageHeartRateBPM = averageHeartRateBPM
        self.points = points
    }
}

public struct WorkoutReceipt: Codable, Hashable, Sendable {
    public let workoutID: UUID
    public let ownerID: UUID?

    public init(workoutID: UUID, ownerID: UUID?) {
        self.workoutID = workoutID
        self.ownerID = ownerID
    }
}

public enum WorkoutTransfer {
    public static let metadataKey = "runloop.workout"
    public static let receiptKey = "runloop.workoutReceipt"
    public static let deletionKey = "runloop.workoutDeletion"
    public static let deletionReceiptKey = "runloop.workoutDeletionReceipt"
    public static let byteLimit = 16 * 1024 * 1024

    // Simulator WatchConnectivity uses interactive messages instead of background file transfers.
    private static let messageLimit = 60_000
    private static let compressedHeader = Data([0x52, 0x4c, 0x01])

    public static func interactiveMessage(_ json: Data) throws -> Data {
        guard json.count <= byteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        if json.count <= messageLimit { return json }
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        let message = compressedHeader + compressed
        guard message.count <= messageLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        return message
    }

    public static func interactiveContents(_ message: Data) throws -> Data {
        guard message.count <= messageLimit else { throw CocoaError(.fileReadTooLarge) }
        guard message.starts(with: compressedHeader) else { return message }
        let compressed = Data(message.dropFirst(compressedHeader.count))
        let json = try (compressed as NSData).decompressed(using: .zlib) as Data
        guard json.count <= byteLimit else { throw CocoaError(.fileReadTooLarge) }
        return json
    }

    public static func encode(_ workout: RecordedWorkout) throws -> Data {
        try JSONEncoder().encode(SyncEnvelope(entityType: "workout", entityID: workout.id, revision: 1, payload: workout))
    }
}

public struct PhoneWorkoutArchive {
    private let root: URL

    public init(root: URL) { self.root = root }

    public func receive(_ data: Data) throws -> WorkoutReceipt {
        guard data.count <= WorkoutTransfer.byteLimit else { throw CocoaError(.fileReadTooLarge) }
        let envelope = try JSONDecoder().decode(SyncEnvelope<RecordedWorkout>.self, from: data)
        let workout = envelope.payload
        guard envelope.schemaVersion == 1, envelope.entityType == "workout", envelope.entityID == workout.id,
              envelope.revision == 1 else { throw CocoaError(.fileReadCorruptFile) }
        try store(workout)
        return WorkoutReceipt(workoutID: workout.id, ownerID: workout.ownerID)
    }

    public func store(_ workout: RecordedWorkout) throws {
        guard isValid(workout) else { throw CocoaError(.fileReadCorruptFile) }
        let scope = directory(for: workout.ownerID)
        let file = scope.appending(path: workout.id.uuidString + ".json")
        if !isDeleted(workout.id), !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
            try JSONEncoder().encode(workout).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    public func workouts(for ownerID: UUID?) throws -> [RecordedWorkout] {
        let requested = ownerID.map { [directory(for: $0), directory(for: nil)] } ?? [directory(for: nil)]
        return try requested.flatMap { scope -> [RecordedWorkout] in
            guard FileManager.default.fileExists(atPath: scope.path) else { return [] }
            let urls = try FileManager.default.contentsOfDirectory(at: scope, includingPropertiesForKeys: nil)
            return urls.filter { $0.pathExtension == "json" }.compactMap { file in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(RecordedWorkout.self, from: data)
            }
        }.filter { ($0.ownerID == nil || $0.ownerID == ownerID) && !isDeleted($0.id) }.sorted { $0.startedAt > $1.startedAt }
    }

    public func remove(id: UUID, originalOwner: UUID?) throws {
        let marker = deletionMarker(for: id)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker, options: .atomic)
        let file = directory(for: originalOwner).appending(path: id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private func isDeleted(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: deletionMarker(for: id).path) }

    private func deletionMarker(for id: UUID) -> URL {
        root.appending(path: "Deleted/\(id.uuidString)")
    }

    private func directory(for ownerID: UUID?) -> URL {
        root.appending(path: ownerID?.uuidString ?? "Unassigned", directoryHint: .isDirectory)
    }

    private func isValid(_ workout: RecordedWorkout) -> Bool {
        guard workout.endedAt > workout.startedAt, workout.activeDurationSeconds.isFinite,
              (0...workout.endedAt.timeIntervalSince(workout.startedAt) + 2).contains(workout.activeDurationSeconds),
              workout.distanceMeters.isFinite, workout.distanceMeters >= 0,
              workout.averageHeartRateBPM.map({ $0.isFinite && $0 > 0 }) ?? true else { return false }

        var previousDate = workout.startedAt
        var activeTime: Double = 0
        for (index, point) in workout.points.enumerated() {
            guard point.coordinate.isValid, point.sequence == index,
                  point.recordedAt >= previousDate, point.recordedAt <= workout.endedAt.addingTimeInterval(2),
                  point.activeElapsedSeconds.map({ (activeTime...workout.activeDurationSeconds + 2).contains($0) }) ?? true
            else { return false }
            previousDate = point.recordedAt
            activeTime = point.activeElapsedSeconds ?? activeTime
        }
        return true
    }
}
