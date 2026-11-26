import Foundation

public struct HeartZones: Codable, Equatable, Sendable {
    public let maximum: Int?
    public let target: Int?
    public let updated: Date

    public init(maximum: Int? = nil, target: Int? = nil, updated: Date = .distantPast) {
        self.maximum = maximum
        self.target = target
        self.updated = updated
    }

    public var isValid: Bool {
        (maximum.map { (60...250).contains($0) } ?? true)
            && (target.map { (1...5).contains($0) && maximum != nil } ?? true)
    }

    public func lowerLimit(for zone: Int) -> Int? {
        guard let maximum, (2...5).contains(zone) else { return nil }
        return (maximum * (zone + 4) + 9) / 10
    }

    public func zone(for bpm: Double) -> Int? {
        guard isValid, maximum != nil, bpm.isFinite, bpm > 0 else { return nil }
        return (2...5).last { zone in
            lowerLimit(for: zone).map { bpm.rounded() >= Double($0) } ?? false
        } ?? 1
    }
}

public struct PulseReading: Codable, Equatable, Sendable {
    public let bpm: Double
    public let measured: Date

    public init?(bpm: Double, measured: Date) {
        guard bpm.isFinite, bpm > 0 else { return nil }
        self.bpm = bpm
        self.measured = measured
    }

    public func isCurrent(at date: Date) -> Bool {
        let age = date.timeIntervalSince(measured)
        return bpm.isFinite && bpm > 0 && (-2...20).contains(age)
    }
}
