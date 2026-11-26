import Foundation

public struct LoopRouteProfile: Sendable {
    private struct Cell: Hashable, Sendable {
        let east: Int
        let north: Int
    }

    private struct Point {
        let east: Double
        let north: Double

        var magnitude: Double { hypot(east, north) }

        func offset(from start: Point) -> Point {
            Point(east: east - start.east, north: north - start.north)
        }

        func interpolated(to end: Point, fraction: Double) -> Point {
            Point(east: east + (end.east - east) * fraction, north: north + (end.north - north) * fraction)
        }

        var cell: Cell {
            Cell(east: Int((east / 80).rounded()), north: Int((north / 80).rounded()))
        }
    }

    public let distanceMeters: Double
    private let bearing: Double?
    private let cells: Set<Cell>

    public init(coordinates: [RouteCoordinate], distanceMeters: Double, reference: RouteCoordinate, compareReturn: Bool) {
        self.distanceMeters = distanceMeters
        let metresPerDegree = 111_195.0
        let longitudeScale = metresPerDegree * cos(reference.latitude * .pi / 180)
        let points = coordinates.map { coordinate in
            let longitude = (coordinate.longitude - reference.longitude).remainder(dividingBy: 360)
            return Point(east: longitude * longitudeScale, north: (coordinate.latitude - reference.latitude) * metresPerDegree)
        }
        let startIndex = compareReturn
            ? points.indices.min { points[$0].magnitude < points[$1].magnitude } ?? 0
            : 0
        let path = points.dropFirst(startIndex)
        guard let start = path.first else {
            bearing = nil
            cells = []
            return
        }

        let segments = zip(path, path.dropFirst()).map { from, to in (from, to, to.offset(from: from).magnitude) }
        let length = segments.reduce(0) { $0 + $1.2 }
        let spacing = max(40, length / 1_000)
        let probeDistance = min(420, length * 0.18)
        var nextSample = spacing
        var travelled = 0.0
        var observedBearing: Double?
        var visited: Set<Cell> = [start.cell]
        for (from, to, segmentLength) in segments where segmentLength > 0 {
            let end = travelled + segmentLength
            while nextSample <= end {
                visited.insert(from.interpolated(to: to, fraction: (nextSample - travelled) / segmentLength).cell)
                nextSample += spacing
            }
            if travelled <= probeDistance, probeDistance <= end {
                let direction = from.interpolated(to: to, fraction: (probeDistance - travelled) / segmentLength).offset(from: start)
                if direction.magnitude >= 15 {
                    observedBearing = atan2(direction.east, direction.north) * 180 / .pi
                }
            }
            travelled = end
        }
        if let last = path.last { visited.insert(last.cell) }
        cells = visited
        bearing = observedBearing
    }

    private func similarity(to other: Self) -> Double {
        let overlap = Double(cells.intersection(other.cells).count) / Double(max(1, min(cells.count, other.cells.count)))
        guard let bearing, let otherBearing = other.bearing else { return overlap }
        let separation = abs((bearing - otherBearing).remainder(dividingBy: 360))
        let directionSimilarity = 1 - min(1, separation / 90)
        return 0.6 * directionSimilarity + 0.4 * overlap
    }

    public static func rankedIndices(_ candidates: [Self], targetDistanceMeters: Double?, recent: [Self]) -> [Int] {
        guard let shortest = candidates.map(\.distanceMeters).min() else { return [] }
        let referenceDistance = targetDistanceMeters ?? shortest
        let distanceSlack = min(1_000, max(100, referenceDistance * (targetDistanceMeters == nil ? 0.22 : 0.15)))
        let errors = candidates.map { abs($0.distanceMeters - referenceDistance) }
        var remaining = Array(candidates.indices)
        var ranking: [Int] = []
        var references = recent

        while let closestError = remaining.map({ errors[$0] }).min() {
            let best = remaining.enumerated().compactMap { offset, index -> (Int, Double)? in
                let deviation = errors[index] - closestError
                guard deviation <= distanceSlack else { return nil }
                let repeatScore = references.reversed().enumerated().map { age, reference in
                    candidates[index].similarity(to: reference) * pow(0.65, Double(age))
                }.max() ?? 0
                return (offset, repeatScore + 0.38 * deviation / distanceSlack)
            }.min { $0.1 < $1.1 }
            guard let best else { break }
            let index = remaining.remove(at: best.0)
            ranking.append(index)
            references.append(candidates[index])
        }
        return ranking
    }
}

public struct LoopSearch {
    private var seenLoops: Set<Int> = []
    private var recentLoops: [LoopRouteProfile] = []
    private var usedSeeds: Set<Int> = []

    public init(existing: RoutePreview? = nil) {
        if let existing { seenLoops.insert(existing.directionIndependentHash) }
    }

    public mutating func reserveSeeds() -> [Int] {
        var seeds: [Int] = []
        while seeds.count < RouteDraft.loopBatchSize {
            let seed = Int.random(in: 0...Int(Int32.max))
            if usedSeeds.insert(seed).inserted { seeds.append(seed) }
        }
        return seeds
    }

    public mutating func rank(_ candidates: [RoutePreview], previous: RoutePreview?, reference: RouteCoordinate,
                              targetDistance: Double?) -> [RoutePreview] {
        let fresh = candidates.filter { seenLoops.insert($0.directionIndependentHash).inserted }
        guard !fresh.isEmpty else { return [] }
        func profile(_ preview: RoutePreview) -> LoopRouteProfile {
            LoopRouteProfile(coordinates: preview.coordinates, distanceMeters: preview.distanceMeters,
                             reference: reference, compareReturn: targetDistance == nil)
        }
        if let previous {
            recentLoops.append(profile(previous))
            if recentLoops.count > 4 { recentLoops.removeFirst() }
        }
        return LoopRouteProfile.rankedIndices(fresh.map(profile), targetDistanceMeters: targetDistance, recent: recentLoops)
            .map { fresh[$0] }
    }
}
