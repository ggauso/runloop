import Foundation
import Testing
import RunloopCore

@Test func fiveZonesUsePersonalMaximumAndExactBoundaries() {
    let zones = HeartZones(maximum: 181, target: 3)
    #expect([2, 3, 4, 5].compactMap(zones.lowerLimit(for:)) == [109, 127, 145, 163])
    #expect([80.0, 108, 109, 126, 127, 144, 145, 162, 163, 195].compactMap(zones.zone(for:)) == [1,1,2,2,3,3,4,4,5,5])
    #expect(zones.zone(for: 126.8) == 3)
    #expect(HeartZones().zone(for: 120) == nil)
    #expect(HeartZones(maximum: 0).zone(for: 120) == nil)
    #expect(!HeartZones(maximum: 180, target: 6).isValid)
    #expect(zones.zone(for: .nan) == nil)
}

@Test func pulseExpiresFromSampleTimeRatherThanDisplayOrTransferTime() throws {
    let now = Date.now
    let pulse = try #require(PulseReading(bpm: 145, measured: now))
    #expect(pulse.isCurrent(at: now.addingTimeInterval(20)))
    #expect(!pulse.isCurrent(at: now.addingTimeInterval(21)))
    #expect(!pulse.isCurrent(at: now.addingTimeInterval(-5)))
    #expect(PulseReading(bpm: 0, measured: now) == nil)
    #expect(PulseReading(bpm: .infinity, measured: now) == nil)
}
