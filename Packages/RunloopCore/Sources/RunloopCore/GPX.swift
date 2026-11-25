import Foundation

public struct GPXPoint: Sendable {
    public let coordinate: RouteCoordinate
    public let recordedAt: Date?

    public init(coordinate: RouteCoordinate, recordedAt: Date? = nil) {
        self.coordinate = coordinate
        self.recordedAt = recordedAt
    }
}

public enum GPX {
    public static func data(name: String, points: [GPXPoint], creditsOpenStreetMap: Bool = false) throws -> Data {
        guard !points.isEmpty, points.allSatisfy({ $0.coordinate.isValid }) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Runloop" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>\(escape(name))</name>
        """
        if creditsOpenStreetMap {
            xml += """
            <link href="https://www.openstreetmap.org/copyright"><text>© OpenStreetMap contributors</text></link>
            """
        }
        xml += "<trkseg>\n"
        let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let locale = Locale(identifier: "en_US_POSIX")
        for point in points {
            let lat = String(format: "%.8f", locale: locale, point.coordinate.latitude)
            let roundedLongitude = (point.coordinate.longitude * 100_000_000).rounded() / 100_000_000
            let longitude: Double = roundedLongitude == 180 ? -180 : roundedLongitude
            let lon = String(format: "%.8f", locale: locale, longitude)
            xml += "<trkpt lat=\"\(lat)\" lon=\"\(lon)\">"
            if let date = point.recordedAt { xml += "<time>\(date.formatted(dateFormat))</time>" }
            xml += "</trkpt>\n"
        }
        xml += "</trkseg></trk>\n</gpx>\n"
        return Data(xml.utf8)
    }

    private static func escape(_ value: String) -> String {
        var text = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 38: text += "&amp;"
            case 60: text += "&lt;"
            case 62: text += "&gt;"
            case 9, 10, 13, 32...0xd7ff, 0xe000...0xfffd, 0x10000...0x10ffff:
                text.unicodeScalars.append(scalar)
            default: continue
            }
        }
        return text
    }
}
