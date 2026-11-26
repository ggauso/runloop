import Foundation
import RunloopCore
import Testing

@Test func routesSurviveReopeningAndIgnoreStaleTransfers() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = UUID()
    let id = UUID()
    let archive = WatchRouteArchive(directory: root)

    let first = try encodedRoute(id: id, owner: owner, revision: 1, name: "Monaco", time: 1)
    let updated = try encodedRoute(id: id, owner: owner, revision: 2, name: "Monaco aggiornato", time: 2)
    let renamed = try encodedRoute(id: id, owner: owner, revision: 2, name: "Anello", time: 3)

    let receipt = try archive.receive(first)
    #expect(receipt.ownerID == owner)
    #expect(receipt.routeID == id)
    #expect(receipt.revision == 1)
    #expect(try archive.receive(first) == receipt)
    _ = try archive.receive(updated)
    _ = try archive.receive(renamed)
    _ = try archive.receive(updated)
    _ = try archive.receive(first)

    let reopened = WatchRouteArchive(directory: root)
    let routes = try reopened.routes(for: owner)
    #expect(routes.count == 1)
    #expect(routes.first?.revision == 2)
    #expect(routes.first?.payload.name == "Anello")
    #expect(routes.first?.payload.mode == nil)
    #expect(routes.first?.payload.waypoints == nil)
    #expect(try reopened.routes(for: UUID()).isEmpty)
}

@Test func watchRoutePlanningPreservesTheDraftAndSelectedGeometry() throws {
    let owner = UUID()
    let id = UUID()
    let start = RouteCoordinate(latitude: 45.0609793, longitude: 7.6585835)
    let stop = RouteCoordinate(latitude: 45.0654, longitude: 7.6613)
    let preview = RoutePreview(coordinates: [start, stop, start], distanceMeters: 1200, provider: "graphhopper")
    let draft = RouteDraft(mode: .waypointLoop, waypoints: [start, stop], targetDistanceMeters: 5000)
    let request = WatchRouteRequest(ownerID: owner, draft: draft, action: .save(id: id, name: "Einaudi", preview: preview))

    let decoded = try WatchRouteMessage.decode(WatchRouteRequest.self, from: WatchRouteMessage.encode(request))
    #expect(decoded.ownerID == owner)
    #expect(decoded.draft.isValid)
    #expect(decoded.draft.waypoints == [start, stop])
    guard case .save(let savedID, let name, let result) = decoded.action else {
        Issue.record("Expected the selected route to be saved")
        return
    }
    #expect(savedID == id)
    #expect(name == "Einaudi")
    #expect(result.geometry == preview.geometry)
    #expect(result.distanceMeters == preview.distanceMeters)
}

@Test func malformedTransfersLeaveTheArchiveUnchanged() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = UUID()
    let archive = WatchRouteArchive(directory: root)
    let invalid = try encodedRoute(id: UUID(), owner: owner, revision: 0, name: "Monaco", time: 1)
    #expect(throws: CocoaError.self) { try archive.receive(invalid) }
    #expect(throws: DecodingError.self) { try archive.receive(Data("invalid".utf8)) }
    #expect(try archive.routes(for: owner).isEmpty)
}

private func encodedRoute(id: UUID, owner: UUID, revision: Int, name: String, time: TimeInterval) throws -> Data {
    let geometry = RouteGeometry(coordinates: [
        RouteCoordinate(latitude: 43.7358, longitude: 7.4227),
        RouteCoordinate(latitude: 43.7368, longitude: 7.4250)
    ])
    let payload = RouteTransfer(ownerID: owner, name: name, distanceMeters: 250, geometry: geometry, provider: "graphhopper")
    return try JSONEncoder().encode(SyncEnvelope(entityType: "route", entityID: id, revision: revision, payload: payload,
                                                 createdAt: Date(timeIntervalSinceReferenceDate: time)))
}
