import Foundation
import RunloopCore
import Testing

@Test func gpxExportsOnlySelectedCoordinatesAndTimestamps() throws {
    let date = Date(timeIntervalSince1970: 1_792_429_600)
    let points = [
        GPXPoint(coordinate: RouteCoordinate(latitude: 43.73, longitude: 7.42), recordedAt: date),
        GPXPoint(coordinate: RouteCoordinate(latitude: 43.74, longitude: 180))
    ]
    let export = try GPX.data(name: "Monaco & <arrivo>", points: points, creditsOpenStreetMap: true)
    let xml = String(decoding: export, as: UTF8.self)
    #expect(XMLParser(data: export).parse())
    #expect(xml.contains("Monaco &amp; &lt;arrivo&gt;"))
    #expect(xml.contains("lat=\"43.73000000\" lon=\"7.42000000\""))
    #expect(xml.contains("lon=\"-180.00000000\""))
    #expect(xml.components(separatedBy: "<time>").count - 1 == 1)
    #expect(xml.contains("openstreetmap.org/copyright"))
    #expect(!xml.contains("<extensions>"))
}

@Test func gpxRefusesAnEmptyOrInvalidTrack() {
    #expect(throws: CocoaError.self) { try GPX.data(name: "Corsa", points: []) }
    #expect(throws: CocoaError.self) {
        try GPX.data(name: "Corsa", points: [GPXPoint(coordinate: RouteCoordinate(latitude: 91, longitude: 0))])
    }
}
