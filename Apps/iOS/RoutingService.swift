import CoreLocation
import Foundation
import RunloopCore
import Supabase

extension RouteCoordinate {
    init(_ value: CLLocationCoordinate2D) {
        self.init(latitude: value.latitude, longitude: value.longitude)
    }

    var location: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct RoutePreview: Sendable {
    let coordinates: [RouteCoordinate]
    let distanceMeters: Double
    let provider: String

    var directionIndependentHash: Int {
        min(coordinates.hashValue, Array(coordinates.reversed()).hashValue)
    }
}

struct RoutingService {
    static let maxWaypoints = 25

    let client: SupabaseClient

    func manual(waypoints: [RouteCoordinate]) async throws -> RoutePreview {
        let session = try await client.auth.session
        return try await route(ManualRequest(waypoints: waypoints), accessToken: session.accessToken)
    }

    func loopAlternatives(start: RouteCoordinate, waypoints: [RouteCoordinate]?, targetDistanceMeters: Int,
                          seeds: [Int]) async throws -> [RoutePreview] {
        let session = try await client.auth.session
        return try await withThrowingTaskGroup(of: Result<RoutePreview, any Error>.self) { group in
            for seed in seeds {
                group.addTask {
                    do {
                        let preview: RoutePreview
                        if let waypoints {
                            preview = try await route(WaypointLoopRequest(waypoints: waypoints, seed: seed), accessToken: session.accessToken)
                        } else {
                            preview = try await route(RoundTripRequest(start: start, targetDistanceMeters: targetDistanceMeters, seed: seed),
                                                      accessToken: session.accessToken)
                        }
                        return .success(preview)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var alternatives: [RoutePreview] = []
            var geometries = Set<Int>()
            var firstError: (any Error)?
            for try await result in group {
                switch result {
                case .success(let preview):
                    if geometries.insert(preview.directionIndependentHash).inserted { alternatives.append(preview) }
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
            }
            try Task.checkCancellation()
            guard !alternatives.isEmpty else { throw firstError ?? RoutingError.invalidResponse }
            if waypoints != nil { return alternatives.sorted { $0.distanceMeters < $1.distanceMeters } }
            return alternatives.sorted {
                abs($0.distanceMeters - Double(targetDistanceMeters)) < abs($1.distanceMeters - Double(targetDistanceMeters))
            }
        }
    }

    private func route<Body: Encodable & Sendable>(_ body: Body, accessToken: String) async throws -> RoutePreview {
        let response: Response = try await client.functions.invoke(
            "routing",
            options: .init(headers: ["Authorization": "Bearer \(accessToken)"], body: body)
        )
        guard response.distanceMeters.isFinite && response.distanceMeters > 0, response.provider == "graphhopper"
        else { throw RoutingError.invalidResponse }
        return RoutePreview(coordinates: response.geometry.coordinates, distanceMeters: response.distanceMeters, provider: response.provider)
    }

    static func message(for error: any Error) -> String {
        if let functionError = error as? FunctionsError, case .httpError(let status, let payload) = functionError {
            switch status {
            case 401, 403: return "Accedi di nuovo per calcolare il percorso."
            case 422:
                if (try? JSONDecoder().decode(ProviderError.self, from: payload))?.code == "loop_unavailable" {
                    return "Non trovo un ritorno diverso dall’andata. Riprova o sposta una tappa."
                }
                return "Non trovo un percorso pedonale tra questi punti. Sposta le tappe o scegli un’altra zona."
            case 429: return "Hai fatto troppe richieste. Riprova tra un minuto."
            case 504: return "Il calcolo ha impiegato troppo tempo. Riprova."
            default: break
            }
        }
        if error is AuthError { return "Accedi di nuovo per calcolare il percorso." }
        if (error as NSError).domain == NSURLErrorDomain {
            return "Controlla la connessione e riprova a calcolare il percorso."
        }
        return "Non è stato possibile calcolare il percorso. Riprova tra poco."
    }

    private struct ManualRequest: Encodable, Sendable {
        let mode = RouteMode.manual
        let waypoints: [RouteCoordinate]
    }

    private struct RoundTripRequest: Encodable, Sendable {
        let mode = RouteMode.roundTrip
        let start: RouteCoordinate
        let targetDistanceMeters: Int
        let seed: Int
    }

    private struct WaypointLoopRequest: Encodable, Sendable {
        let mode = RouteMode.waypointLoop
        let waypoints: [RouteCoordinate]
        let seed: Int
    }

    private struct ProviderError: Decodable { let code: String }

    private struct Response: Decodable {
        let provider: String
        let distanceMeters: Double
        let geometry: RouteGeometry
    }

    private enum RoutingError: Error { case invalidResponse }
}
