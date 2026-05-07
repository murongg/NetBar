import Foundation

public struct RouteClassifier: Sendable {
    public let proxySettings: ProxySettings

    public init(proxySettings: ProxySettings) {
        self.proxySettings = proxySettings
    }

    public func classify(_ connection: ConnectionMetric) -> TrafficRoute {
        if proxySettings.matches(connection.local) || proxySettings.matches(connection.remote) {
            return .proxy
        }

        if connection.local.isLoopback || connection.remote.isLoopback || connection.interfaceName == "lo0" {
            return .loopback
        }

        guard connection.isMeasurable else {
            return .unknown
        }

        return .direct
    }
}

public struct TrafficAccumulator: Sendable {
    private var previousCounters: [ConnectionKey: TrafficCounter]

    public init() {
        self.previousCounters = [:]
    }

    public mutating func ingest(_ snapshot: NetworkSnapshot, proxySettings: ProxySettings) -> [TrafficDelta] {
        let classifier = RouteClassifier(proxySettings: proxySettings)
        var nextCounters: [ConnectionKey: TrafficCounter] = [:]
        var deltas: [TrafficDelta] = []

        for connection in snapshot.connections where connection.isMeasurable {
            let key = ConnectionKey(connection)
            let current = connection.counter
            nextCounters[key] = current

            guard let previous = previousCounters[key],
                  let counterDelta = current.delta(from: previous),
                  counterDelta.total > 0 else {
                continue
            }

            deltas.append(
                TrafficDelta(
                    timestamp: snapshot.timestamp,
                    appName: connection.process.appName,
                    pid: connection.process.pid,
                    route: classifier.classify(connection),
                    bytesIn: counterDelta.bytesIn,
                    bytesOut: counterDelta.bytesOut
                )
            )
        }

        previousCounters = nextCounters
        return deltas
    }
}

private struct ConnectionKey: Hashable, Sendable {
    let process: ProcessIdentity
    let protocolName: String
    let local: String
    let remote: String

    init(_ connection: ConnectionMetric) {
        self.process = connection.process
        self.protocolName = connection.protocolName
        self.local = connection.local.rawValue
        self.remote = connection.remote.rawValue
    }
}
