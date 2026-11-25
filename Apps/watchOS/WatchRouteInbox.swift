import Foundation
import Observation
import RunloopCore
@preconcurrency import WatchConnectivity

@MainActor
@Observable
final class WatchRouteInbox: NSObject, WCSessionDelegate {
    private static let ownerKey = "runloop.watchOwner"
    private let archive = WatchRouteArchive(
        directory: URL.applicationSupportDirectory.appending(path: "Runloop/Routes", directoryHint: .isDirectory)
    )
    private var ownerID: UUID?
    var currentOwner: UUID? { ownerID }
    private var session: WCSession?
    let workouts = WatchWorkoutOutbox()
    private(set) var routes: [SyncEnvelope<RouteTransfer>] = []
    private(set) var readFailed = false

    override init() {
        super.init()
        ownerID = UserDefaults.standard.string(forKey: Self.ownerKey).flatMap(UUID.init(uuidString:))
        refresh()
        workouts.refresh()
        guard WCSession.isSupported() else { return }
        session = WCSession.default
        session?.delegate = self
        session?.activate()
    }

    private func refresh() {
        routes = []
        readFailed = false
        guard let ownerID else { return }
        do { routes = try archive.routes(for: ownerID) }
        catch { readFailed = true }
    }

    private func applyOwner(_ value: String) {
        ownerID = UUID(uuidString: value)
        UserDefaults.standard.set(ownerID?.uuidString, forKey: Self.ownerKey)
        refresh()
    }

    private func receive(_ data: Data) throws -> Data {
        let receipt = try archive.receive(data)
        if ownerID == receipt.ownerID { refresh() }
        return try JSONEncoder().encode(receipt)
    }

    func syncWorkouts() {
        if let session { workouts.flush(using: session) }
        else { workouts.refresh() }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: (any Error)?) {
        guard activationState == .activated else { return }
        let owner = session.receivedApplicationContext[RouteTransferKeys.owner] as? String
        Task { @MainActor in
            if let owner { applyOwner(owner) }
            syncWorkouts()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let owner = applicationContext[RouteTransferKeys.owner] as? String else { return }
        Task { @MainActor in applyOwner(owner) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { Task { @MainActor in syncWorkouts() } }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        guard error != nil, let identifier = fileTransfer.file.metadata?[WorkoutTransfer.metadataKey] as? String,
              let id = UUID(uuidString: identifier) else { return }
        Task { @MainActor in workouts.noteFailedDelivery(for: id) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let data = userInfo[WorkoutTransfer.deletionKey] as? Data,
           let receipt = try? JSONDecoder().decode(WorkoutReceipt.self, from: data) {
            Task { @MainActor in
                do {
                    try workouts.delete(receipt, currentOwner: ownerID)
                    if let session = self.session, session.activationState == .activated {
                        session.transferUserInfo([WorkoutTransfer.deletionReceiptKey: data])
                    }
                } catch {}
            }
            return
        }
        guard let data = userInfo[WorkoutTransfer.receiptKey] as? Data,
              let receipt = try? JSONDecoder().decode(WorkoutReceipt.self, from: data) else { return }
        Task { @MainActor in workouts.confirm(receipt) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        #if !targetEnvironment(simulator)
        guard let values = try? file.fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= RouteTransferKeys.byteLimit,
              let data = try? Data(contentsOf: file.fileURL) else { return }
        Task { @MainActor in
            guard let reply = try? receive(data), let session = self.session,
                  session.activationState == .activated else { return }
            session.transferUserInfo([RouteTransferKeys.receipt: reply])
        }
        #endif
    }

    #if targetEnvironment(simulator)
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping @Sendable ([String: Any]) -> Void) {
        guard let data = message[WorkoutTransfer.deletionKey] as? Data,
              let receipt = try? JSONDecoder().decode(WorkoutReceipt.self, from: data) else {
            replyHandler([:])
            return
        }
        Task { @MainActor in
            do {
                try workouts.delete(receipt, currentOwner: ownerID)
                replyHandler([WorkoutTransfer.deletionReceiptKey: true])
            } catch {
                replyHandler([WorkoutTransfer.deletionReceiptKey: false])
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                             replyHandler: @escaping @Sendable (Data) -> Void) {
        Task { @MainActor in replyHandler((try? receive(messageData)) ?? Data()) }
    }
    #endif
}
