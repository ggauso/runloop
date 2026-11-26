import Foundation
import Observation
import RunloopCore
import SwiftUI
@preconcurrency import WatchConnectivity

extension WorkoutSource {
    static var localDevice: Self {
        #if os(watchOS)
        .watch
        #else
        .phone
        #endif
    }

    var displayName: String { self == .watch ? "Apple Watch" : "iPhone" }
}

struct RunBrief: Codable, Identifiable, Equatable {
    let id: UUID
    static let contextKey = "runloop.recentRuns.v1"
    let startedAt: Date
    let distance: Double
    let duration: Double
    let source: WorkoutSource

    init(_ workout: RecordedWorkout) {
        id = workout.id
        startedAt = workout.startedAt
        distance = workout.distanceMeters
        duration = workout.activeDurationSeconds
        source = workout.source ?? .watch
    }
}

struct LiveRun: Codable {
    let id: UUID
    let phase: RunWorkout.Phase
    let title: String
    let planned: [RouteCoordinate]
    let trail: [RouteCoordinate]
    let elapsed: Double
    let distance: Double
    let heartRate: Double?
    let pulse: PulseReading?
    let canDiscard: Bool?
    let needsLocationChoice: Bool?
    let date: Date
    let source: WorkoutSource
}

@MainActor
@Observable
final class RunCompanion {
    nonisolated static let key = "runloop.liveRun.v1"
    enum Action: String, Codable { case status, pause, resume, finish, discard, startWatch, continueWithoutGPS, cancelStart }

    private struct Request: Codable {
        let owner: UUID?
        let id: UUID?
        let action: Action
        let route: SyncEnvelope<RouteTransfer>?
        let zones: HeartZones?
    }
    private struct Reply: Codable {
        var run: LiveRun?
        var reservation: UUID?
        var occupied: Bool?
        var watchCanStart: Bool?
        var zones: HeartZones?
    }

    struct StartOffer {
        let id: UUID
        let route: SyncEnvelope<RouteTransfer>?
        let owner: UUID?
    }

    enum LaunchPhase { case checking, introducing, finished }
    private(set) var launchPhase: LaunchPhase = .checking
    func finishLaunch() { launchPhase = .finished }

    let local = RunWorkout()
    private(set) var offer: StartOffer?
    private(set) var zones = HeartZones()
    private var zoneKey: String { "runloop.heartZones." + (owner?.uuidString ?? "guest") }

    init() { loadZones() }

    private func loadZones() {
        if let data = UserDefaults.standard.data(forKey: zoneKey),
           let stored = try? JSONDecoder().decode(HeartZones.self, from: data), stored.isValid {
            zones = stored
        } else { zones = HeartZones() }
    }

    func setZones(maximum: Int?, target: Int?) {
        mergeZones(HeartZones(maximum: maximum, target: target, updated: .now))
    }

    private func mergeZones(_ incoming: HeartZones?) {
        guard let incoming, incoming.isValid, incoming.updated > zones.updated else { return }
        zones = incoming
        UserDefaults.standard.set(try? JSONEncoder().encode(incoming), forKey: zoneKey)
    }

    // A hint only suppresses branding when the last known recorder is temporarily unreachable.
    // Only a live status reply may present the remote timer or enable its controls.
    private var remoteHintKey: String { "runloop.activePeer." + (owner?.uuidString ?? "guest") }
    private(set) var remote: LiveRun? {
        didSet {
            guard let remote else { return }
            let active = remote.phase == .running || remote.phase == .paused
            if UserDefaults.standard.bool(forKey: remoteHintKey) != active {
                UserDefaults.standard.set(active, forKey: remoteHintKey)
            }
        }
    }
    private(set) var connected = false
    private(set) var lastPeerReply: Date?
    private(set) var sending = false
    private(set) var notice: String?
    private var reservation: UUID?
    private var owner: UUID?
    private var revision = 0
    private var ignored: UUID?
    private var lastCompleted: LiveRun?
    var isPresented: Bool { local.isPresented || remote != nil || offer != nil || reservation != nil || notice != nil }

    private var peer: WCSession? {
        guard WCSession.isSupported() else { return nil }
        let session = WCSession.default
        return session.activationState == .activated && session.isReachable ? session : nil
    }

    func setOwner(_ owner: UUID?) {
        guard self.owner != owner else { return }
        self.owner = owner
        loadZones()
        offer = nil
        lastCompleted = nil
        revision += 1
        remote = nil
        reservation = nil
        ignored = nil
        notice = nil
    }

    func start(route: SyncEnvelope<RouteTransfer>?, ownerID: UUID?, offerWatch: Bool = true) {
        guard !isPresented, route.map({ $0.payload.ownerID == ownerID }) ?? true else { return }
        revision += 1
        let candidate = UUID()
        reservation = candidate
        Task {
            defer { if reservation == candidate { reservation = nil } }
            var peerAnswered = false
            if let peer {
                do {
                    let reply = try await request(.status, id: nil, using: peer)
                    peerAnswered = true
                    guard reservation == candidate else { return }
                    if reply.occupied == true {
                        notice = "Una corsa è già in corso sull’altro dispositivo."
                        return
                    }
                    if let run = reply.run, [.starting, .running, .paused, .saving, .saveFailed].contains(run.phase) {
                        remote = run
                        connected = true
                        return
                    }
                    // Both devices tapped Start before receiving a reply. Elect the same UUID on both.
                    if let other = reply.reservation, other.uuidString < candidate.uuidString { return }
                    #if os(iOS)
                    if offerWatch && reply.watchCanStart == true && reply.reservation == nil {
                        offer = StartOffer(id: candidate, route: route, owner: ownerID)
                        return
                    }
                    #endif
                } catch {
                    guard reservation == candidate else { return }
                    if self.peer != nil && (error as? URLError)?.code != .timedOut && !(error is WCError) {
                        notice = "Verifica della corsa sull’altro dispositivo non riuscita. Riprova."
                        return
                    }
                }
            }
            guard reservation == candidate else { return }
            #if os(iOS)
            // After wake, a paired Watch can be installed before messaging becomes reachable.
            if offerWatch, !peerAnswered, WCSession.isSupported() {
                let session = WCSession.default
                if session.activationState != .activated {
                    for _ in 0..<5 where session.activationState != .activated {
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }
                guard reservation == candidate else { return }
                if session.activationState == .activated && session.isPaired && session.isWatchAppInstalled {
                    offer = StartOffer(id: candidate, route: route, owner: ownerID)
                    return
                }
            }
            #endif
            remote = nil
            local.start(id: candidate, route: route, ownerID: ownerID)
        }
    }

    func cancelOffer() { offer = nil; notice = nil }

    func chooseRecorder(watch: Bool) {
        guard let choice = offer, choice.owner == owner else { return }
        offer = nil
        notice = nil
        if !watch {
            // Recheck current occupancy, including a simultaneous start on the Watch.
            start(route: choice.route, ownerID: choice.owner, offerWatch: false)
            return
        }
        reservation = choice.id
        Task {
            defer { if reservation == choice.id { reservation = nil } }
            for _ in 0..<12 where peer == nil && reservation == choice.id {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard reservation == choice.id else { return }
            guard let peer else {
                offer = choice
                notice = "Apri Runloop sul Watch e riprova, oppure usa iPhone."
                return
            }
            do {
                let reply = try await request(.startWatch, id: choice.id, using: peer, route: choice.route)
                guard reservation == choice.id else { return }
                if let run = reply.run, run.id == choice.id {
                    remote = run
                    connected = true
                } else {
                    notice = "Il Watch non può avviare questa corsa. Controlla Runloop sul polso."
                }
            } catch {
                if reservation == choice.id {
                    notice = "Avvio sul Watch non confermato. Controlla il polso prima di riprovare."
                }
            }
        }
    }

    func rememberCompletion() {
        if [.saved, .discarded].contains(local.phase), local.ownerID == owner { lastCompleted = snapshot() }
    }

    private func snapshot() -> LiveRun? {
        guard let id = local.runID, local.isPresented else { return nil }
        let date = Date.now
        let path = local.route?.payload.geometry.coordinates ?? []
        let strideLength = max(1, (path.count + 95) / 96)
        var overview = stride(from: 0, to: path.count, by: strideLength).map { path[$0] }
        if let last = path.last, overview.last != last { overview.append(last) }
        return LiveRun(id: id, phase: local.phase, title: local.route?.payload.name ?? "Corsa libera",
                       planned: overview, trail: local.recording.trail, elapsed: local.elapsed(at: date),
                       distance: local.distance, heartRate: local.pulse?.bpm, pulse: local.pulse, canDiscard: true,
                       needsLocationChoice: local.needsLocationChoice, date: date, source: .localDevice)
    }

    func respond(_ data: Data) async -> Data {
        guard let query = try? JSONDecoder().decode(Request.self, from: data) else { return Data() }
        if launchPhase == .checking { await local.checkForActiveWorkout() }
        var reply = Reply()
        if query.owner != owner || (local.isPresented && local.ownerID != query.owner) {
            reply.occupied = reservation != nil || [.starting, .running, .paused, .saving, .saveFailed].contains(local.phase)
        } else {
            mergeZones(query.zones)
            reply.zones = zones
            #if os(watchOS)
            reply.watchCanStart = true
            if query.action == .startWatch, let id = query.id, reservation == nil,
               query.route.map({ $0.payload.ownerID == owner }) ?? true {
                if local.runID != id, [.discarded, .saved, .startFailed].contains(local.phase) {
                    rememberCompletion()
                    local.close()
                }
                if !local.isPresented {
                    // The phone requesting a new run has already left its previous session.
                    revision += 1
                    remote = nil
                    notice = nil
                    local.start(id: id, route: query.route, ownerID: owner)
                }
            }
            #endif
            reply.reservation = reservation
            if let id = local.runID, query.id == id {
                switch (query.action, local.phase) {
                case (.continueWithoutGPS, .starting): local.resolveLocationChoice(recordWithoutGPS: true)
                case (.cancelStart, .starting): local.resolveLocationChoice(recordWithoutGPS: false)
                case (.pause, .running), (.resume, .paused): local.togglePause()
                case (.discard, .running), (.discard, .paused): local.discard()
                case (.finish, .running), (.finish, .paused): local.stop()
                default: break
                }
            }
            reply.run = snapshot()
            if reply.run == nil, let result = lastCompleted, query.id == result.id { reply.run = result }
        }
        return (try? JSONEncoder().encode(reply)) ?? Data()
    }

    private func request(_ action: Action, id: UUID?, using session: WCSession, route: SyncEnvelope<RouteTransfer>? = nil, launchCheck: Bool = false) async throws -> Reply {
        let scope = owner
        let payload = try JSONEncoder().encode(Request(owner: scope, id: id, action: action, route: route, zones: zones))
        // A waking Watch can take longer to acknowledge the user's pre-run choice.
        let timeout = action == .continueWithoutGPS || action == .cancelStart ? 30 : 4
        guard let data = try await session.runloopReply(to: payload, key: Self.key, replyKey: Self.key,
                                                        timeout: launchCheck ? .milliseconds(700) : .seconds(timeout)) else {
            if action == .status { return Reply() }
            throw CocoaError(.coderReadCorrupt)
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        if owner == scope { mergeZones(reply.zones) }
        return reply
    }

    #if os(watchOS)
    func checkPhoneConnection(using session: WCSession) async throws {
        // The monitor already asks the phone every four seconds. A fresh reply also
        // confirms the channel when queued messages are draining after a reconnect.
        if connected, let lastPeerReply, Date.now.timeIntervalSince(lastPeerReply) < 4 { return }
        _ = try await request(.status, id: nil, using: session)
    }
    #endif

    func monitor(peerReady: () -> Bool = { true }) async {
        if launchPhase == .checking {
            await local.checkForActiveWorkout()
            guard !Task.isCancelled else { return }
            if !local.isPresented, WCSession.isSupported() {
                // Activation follows process launch. Ask a reachable recorder before showing the brand.
                for _ in 0..<8 where WCSession.default.activationState != .activated || !peerReady() {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
                if peerReady(), peer != nil {
                    await exchange(.status, launchCheck: true)
                }
            }
            guard !Task.isCancelled else { return }
            if launchPhase == .checking {
                let previouslyActivePeer = UserDefaults.standard.bool(forKey: remoteHintKey)
                launchPhase = isPresented || local.hasRecoveryContext || previouslyActivePeer ? .finished : .introducing
            }
        }
        while !Task.isCancelled {
            if peerReady(), !local.isPresented, !sending, offer == nil, reservation == nil { await exchange(.status) }
            do { try await Task.sleep(for: .seconds(remote == nil ? 4 : 1.5)) }
            catch { return }
        }
    }

    func command(_ action: Action) {
        guard remote != nil, !sending, connected, action != .status else { return }
        sending = true
        Task { await exchange(action); sending = false }
    }

    private func exchange(_ action: Action, launchCheck: Bool = false) async {
        guard let peer else { connected = false; return }
        revision += 1
        let sent = revision
        do {
            let reply = try await request(action, id: remote?.id, using: peer, launchCheck: launchCheck)
            guard sent == revision, !Task.isCancelled, reservation == nil, !local.isPresented else { return }
            connected = true
            lastPeerReply = .now
            if let run = reply.run, run.id != ignored, (![.saved, .discarded, .startFailed].contains(run.phase) || remote?.id == run.id) {
                remote = run
            } else if remote?.phase != .saved && remote?.phase != .discarded {
                if reply.run == nil { UserDefaults.standard.removeObject(forKey: remoteHintKey) }
                remote = nil
            }
        } catch {
            if sent == revision { connected = false }
        }
    }

    func closeRemote() {
        revision += 1
        ignored = remote?.id
        remote = nil
        notice = nil
    }
}

extension WCSession {
    @MainActor
    func runloopReply(to payload: Data, key: String, replyKey: String, timeout: Duration) async throws -> Data? {
        try Task.checkCancellation()
        let (replies, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let deadline = Task {
            try await Task.sleep(for: timeout)
            continuation.finish(throwing: URLError(.timedOut))
        }
        defer { deadline.cancel() }
        sendMessage([key: payload]) { reply in
            if let data = reply[replyKey] as? Data { continuation.yield(data) }
            continuation.finish()
        } errorHandler: { continuation.finish(throwing: $0) }
        var iterator = replies.makeAsyncIterator()
        let result = try await iterator.next()
        try Task.checkCancellation()
        return result
    }
}

func runPaceText(duration: Double, distance: Double) -> String {
    guard distance > 0, let seconds = Int(exactly: (duration / distance * 1000).rounded(.down)), seconds >= 0 else { return "—" }
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60)) /km"
}
