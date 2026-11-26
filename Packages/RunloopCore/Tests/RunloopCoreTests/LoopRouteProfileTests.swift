import RunloopCore
import Testing

private let origin = RouteCoordinate(latitude: 45, longitude: 7)

private func point(_ east: Double, _ north: Double) -> RouteCoordinate {
    RouteCoordinate(latitude: origin.latitude + north / 111_195, longitude: origin.longitude + east / 78_627)
}

private func profile(_ points: [RouteCoordinate], distance: Double, anchor: RouteCoordinate? = nil) -> LoopRouteProfile {
    LoopRouteProfile(coordinates: points, distanceMeters: distance, reference: anchor ?? origin, compareReturn: anchor != nil)
}

@Test func regenerationFavorsADifferentDepartureWithinDistanceSlack() {
    let north = profile([origin, point(0, 900), point(600, 900), origin], distance: 5_000)
    let east = profile([origin, point(900, 0), point(900, -600), origin], distance: 5_250)
    let west = profile([origin, point(-1_800, 0), point(-1_800, -1_000), origin], distance: 6_500)

    #expect(LoopRouteProfile.rankedIndices([north, east, west], targetDistanceMeters: 5_000, recent: []) == [0, 1, 2])
    #expect(LoopRouteProfile.rankedIndices([north, east, west], targetDistanceMeters: 5_000, recent: [north]) == [1, 0, 2])
}

@Test func waypointLoopComparesTheReturnAfterTheLastStop() {
    let stop = point(0, 1_000)
    let sharedOutbound = [origin, point(0, 500), stop]
    let left = profile(sharedOutbound + [point(-600, 1_000), point(-600, 0), origin], distance: 3_100, anchor: stop)
    let right = profile(sharedOutbound + [point(700, 1_000), point(700, 0), origin], distance: 3_200, anchor: stop)

    #expect(LoopRouteProfile.rankedIndices([left, right], targetDistanceMeters: nil, recent: [left]) == [1, 0])
}

@Test func latestDepartureMattersMoreThanAnOlderOne() {
    let north = profile([origin, point(0, 900), point(600, 900), origin], distance: 5_000)
    let slightlyShorterSouth = profile([origin, point(0, -900), point(600, -900), origin], distance: 4_380)

    #expect(LoopRouteProfile.rankedIndices([north, slightlyShorterSouth], targetDistanceMeters: 5_000,
                                         recent: [slightlyShorterSouth, north]) == [1, 0])
}
