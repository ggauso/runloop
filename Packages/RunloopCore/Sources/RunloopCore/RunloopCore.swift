public enum RouteMode: String, Codable, Hashable, Sendable {
    case manual
    case roundTrip = "round_trip"
    case waypointLoop = "waypoint_loop"
}

public struct RouteCoordinate: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public struct RouteGeometry: Codable, Hashable, Sendable {
    public let coordinates: [RouteCoordinate]

    public init(coordinates: [RouteCoordinate]) { self.coordinates = coordinates }

    private enum CodingKeys: String, CodingKey { case type, coordinates }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let points = try container.decode([[Double]].self, forKey: .coordinates)
        guard type == "LineString", points.count >= 2 else {
            throw DecodingError.dataCorruptedError(forKey: .coordinates, in: container, debugDescription: "Expected a GeoJSON LineString")
        }
        coordinates = try points.map { point in
            guard point.count == 2 else {
                throw DecodingError.dataCorruptedError(forKey: .coordinates, in: container, debugDescription: "Expected [longitude, latitude]")
            }
            let coordinate = RouteCoordinate(latitude: point[1], longitude: point[0])
            guard coordinate.isValid else {
                throw DecodingError.dataCorruptedError(forKey: .coordinates, in: container, debugDescription: "Invalid WGS84 coordinates")
            }
            return coordinate
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("LineString", forKey: .type)
        try container.encode(coordinates.map { [$0.longitude, $0.latitude] }, forKey: .coordinates)
    }
}
