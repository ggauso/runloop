import Foundation
import RunloopCore
import Testing

@Test func repeatedWorkoutTransfersProduceOneOwnerScopedWorkout() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = UUID()
    let id = UUID()
    let current = PhoneWorkoutArchive(root: root)
    let workout = sampleWorkout(id: id, owner: owner)
    let data = try WorkoutTransfer.encode(workout)
    let expected = WorkoutReceipt(workoutID: id, ownerID: owner)

    #expect(try current.receive(data) == expected)
    #expect(try current.receive(data) == expected)
    let reopened = PhoneWorkoutArchive(root: root)
    #expect(try reopened.workouts(for: owner).map(\.id) == [id])
    #expect(try reopened.workouts(for: UUID()).isEmpty)
    #expect(try reopened.workouts(for: nil).isEmpty)

    let unassignedID = UUID()
    _ = try current.receive(WorkoutTransfer.encode(sampleWorkout(id: unassignedID, owner: nil)))
    #expect(try reopened.workouts(for: nil).map(\.id) == [unassignedID])
}

@Test func invalidWorkoutDoesNotGetAReceipt() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = PhoneWorkoutArchive(root: root)
    let id = UUID()
    let data = try WorkoutTransfer.encode(sampleWorkout(id: id, owner: nil, pointSequence: 1))

    #expect(throws: CocoaError.self) { try archive.receive(data) }
    #expect(try archive.workouts(for: nil).isEmpty)
}

private func sampleWorkout(id: UUID, owner: UUID?, pointSequence: Int = 0) -> RecordedWorkout {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    let point = WorkoutPoint(sequence: pointSequence, recordedAt: start.addingTimeInterval(2),
                             coordinate: RouteCoordinate(latitude: 43.73, longitude: 7.42),
                             activeElapsedSeconds: 2, horizontalAccuracy: 5, speedMetersPerSecond: 3)
    return RecordedWorkout(id: id, ownerID: owner, routeID: nil, plannedRoute: nil, healthKitID: nil, startedAt: start,
                           endedAt: start.addingTimeInterval(4), activeDurationSeconds: 4, distanceMeters: 10,
                           averageHeartRateBPM: nil, points: [point])
}

@Test func aDeletedWorkoutDoesNotReappearAfterReplay() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = PhoneWorkoutArchive(root: root)
    let workout = sampleWorkout(id: UUID(), owner: nil)
    let data = try WorkoutTransfer.encode(workout)
    let receipt = try archive.receive(data)
    try archive.remove(id: workout.id, originalOwner: nil)
    let reopened = PhoneWorkoutArchive(root: root)
    #expect(try reopened.receive(data) == receipt)
    #expect(try reopened.workouts(for: nil).isEmpty)
}

@Test func localPhoneRunAndRetriedDeliveryShareOneHistoryEntry() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = PhoneWorkoutArchive(root: root)
    let sample = sampleWorkout(id: UUID(), owner: nil)
    let run = RecordedWorkout(id: sample.id, ownerID: nil, routeID: nil, plannedRoute: nil, healthKitID: nil,
                              startedAt: sample.startedAt, endedAt: sample.endedAt, activeDurationSeconds: 4,
                              distanceMeters: 10, averageHeartRateBPM: nil, points: sample.points, source: .phone)
    try archive.store(run)
    _ = try archive.receive(WorkoutTransfer.encode(run))
    let stored = try PhoneWorkoutArchive(root: root).workouts(for: nil)
    #expect(stored.map(\.id) == [run.id])
    #expect(stored.first?.source == .phone)
    #expect(stored.first?.points == sample.points)
}
