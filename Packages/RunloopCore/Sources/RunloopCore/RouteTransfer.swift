import Foundation

public struct SyncEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let schemaVersion: Int
    public let entityType: String
    public let entityID: UUID
    public let revision: Int
    public let createdAt: Date
    public let payload: Payload

    public init(entityType: String, entityID: UUID, revision: Int, payload: Payload, createdAt: Date = .now) {
        schemaVersion = 1
        self.entityType = entityType
        self.entityID = entityID
        self.revision = revision
        self.createdAt = createdAt
        self.payload = payload
    }
}

public struct RouteTransfer: Codable, Sendable {
    public let ownerID: UUID
    public let name: String
    public let distanceMeters: Double
    public let geometry: RouteGeometry
    public let provider: String
    public let mode: RouteMode?
    public let waypoints: [RouteCoordinate]?
    public let targetDistanceMeters: Int?

    public init(ownerID: UUID, name: String, distanceMeters: Double, geometry: RouteGeometry, provider: String,
                mode: RouteMode? = nil, waypoints: [RouteCoordinate]? = nil, targetDistanceMeters: Int? = nil) {
        self.ownerID = ownerID
        self.name = name
        self.distanceMeters = distanceMeters
        self.geometry = geometry
        self.provider = provider
        self.mode = mode
        self.waypoints = waypoints
        self.targetDistanceMeters = targetDistanceMeters
    }
}

public struct RoutePreview: Codable, Identifiable, Sendable {
    public let id = UUID()
    public let geometry: RouteGeometry
    public let distanceMeters: Double
    public let provider: String

    public init(coordinates: [RouteCoordinate], distanceMeters: Double, provider: String) {
        geometry = RouteGeometry(coordinates: coordinates)
        self.distanceMeters = distanceMeters
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey { case geometry, distanceMeters, provider }

    public var coordinates: [RouteCoordinate] { geometry.coordinates }

    public var directionIndependentHash: Int {
        min(coordinates.hashValue, Array(coordinates.reversed()).hashValue)
    }
}

public struct RouteDraft: Codable, Sendable {
    public static let maximumWaypoints = 25
    public static let loopBatchSize = 6

    public let mode: RouteMode
    public let waypoints: [RouteCoordinate]
    public let targetDistanceMeters: Int

    public init(mode: RouteMode, waypoints: [RouteCoordinate], targetDistanceMeters: Int) {
        self.mode = mode
        self.waypoints = waypoints
        self.targetDistanceMeters = targetDistanceMeters
    }

    public var isValid: Bool {
        let validCount = mode == .roundTrip ? waypoints.count == 1 : (2...Self.maximumWaypoints).contains(waypoints.count)
        return validCount && waypoints.allSatisfy(\.isValid) &&
            (mode != .roundTrip || (500...50000).contains(targetDistanceMeters))
    }
}

public struct WatchRouteRequest: Codable, Sendable {
    public enum Action: Codable, Sendable {
        case calculate(seeds: [Int])
        case save(id: UUID, name: String, preview: RoutePreview)
    }

    public let ownerID: UUID
    public let draft: RouteDraft
    public let action: Action

    public init(ownerID: UUID, draft: RouteDraft, action: Action) {
        self.ownerID = ownerID
        self.draft = draft
        self.action = action
    }
}

public enum WatchRouteReply: Codable, Sendable {
    case previews([RoutePreview])
    case saved(SyncEnvelope<RouteTransfer>)
    case failure(String)
}

public enum WatchRouteMessage {
    public static let requestKey = "runloop.routePlanner.v1"
    public static let replyKey = "runloop.routePlanner.reply.v1"
    private static let sizeLimit = 48 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        let compressed = try (data as NSData).compressed(using: .zlib) as Data
        guard data.count <= RouteTransferKeys.byteLimit, compressed.count <= sizeLimit else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        return compressed
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= sizeLimit else { throw CocoaError(.fileReadTooLarge) }
        let decompressed = try (data as NSData).decompressed(using: .zlib) as Data
        guard decompressed.count <= RouteTransferKeys.byteLimit else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(type, from: decompressed)
    }
}

public struct RouteReceipt: Codable, Hashable, Sendable {
    public let ownerID: UUID
    public let routeID: UUID
    public let revision: Int
    public let createdAt: Date

    public init(ownerID: UUID, routeID: UUID, revision: Int, createdAt: Date) {
        self.ownerID = ownerID
        self.routeID = routeID
        self.revision = revision
        self.createdAt = createdAt
    }
}

public enum RouteTransferKeys {
    public static let owner = "runloop.owner"
    public static let version = "runloop.routeVersion"
    public static let receipt = "runloop.routeReceipt"
    public static let byteLimit = 2 * 1024 * 1024
}

public struct WatchRouteArchive {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func receive(_ data: Data) throws -> RouteReceipt {
        let route = try decode(data)
        let ownerDirectory = directory.appending(path: route.payload.ownerID.uuidString, directoryHint: .isDirectory)
        let destination = ownerDirectory.appending(path: route.entityID.uuidString + ".json")
        if let oldData = try? Data(contentsOf: destination), let oldRoute = try? decode(oldData),
           oldRoute.revision > route.revision || (oldRoute.revision == route.revision && oldRoute.createdAt >= route.createdAt) {
            return receipt(for: route)
        }

        try FileManager.default.createDirectory(at: ownerDirectory, withIntermediateDirectories: true)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return receipt(for: route)
    }

    public func routes(for ownerID: UUID) throws -> [SyncEnvelope<RouteTransfer>] {
        let ownerDirectory = directory.appending(path: ownerID.uuidString, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: ownerDirectory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: ownerDirectory, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let route = try? decode(data), route.payload.ownerID == ownerID else { return nil }
            return route
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func decode(_ data: Data) throws -> SyncEnvelope<RouteTransfer> {
        guard data.count <= RouteTransferKeys.byteLimit else { throw CocoaError(.fileReadTooLarge) }
        let route = try JSONDecoder().decode(SyncEnvelope<RouteTransfer>.self, from: data)
        guard route.schemaVersion == 1, route.entityType == "route", route.revision > 0,
              route.payload.distanceMeters.isFinite, route.payload.distanceMeters > 0,
              !route.payload.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return route
    }

    private func receipt(for route: SyncEnvelope<RouteTransfer>) -> RouteReceipt {
        RouteReceipt(ownerID: route.payload.ownerID, routeID: route.entityID, revision: route.revision, createdAt: route.createdAt)
    }
}
