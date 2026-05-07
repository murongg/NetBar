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
    private var previousConnectionCounters: [ConnectionKey: TrafficCounter]
    private var previousProcessCounters: [ProcessIdentity: TrafficCounter]
    private var previousUnmatchedConnectionCountersByProcess: [ProcessIdentity: TrafficCounter]

    public init() {
        self.previousConnectionCounters = [:]
        self.previousProcessCounters = [:]
        self.previousUnmatchedConnectionCountersByProcess = [:]
    }

    public mutating func ingest(_ snapshot: NetworkSnapshot, proxySettings: ProxySettings) -> [TrafficDelta] {
        let classifier = RouteClassifier(proxySettings: proxySettings)
        var nextCounters: [ConnectionKey: TrafficCounter] = [:]
        var nextProcessCounters: [ProcessIdentity: TrafficCounter] = [:]
        var connectionDeltaTotalsByProcess: [ProcessIdentity: TrafficCounter] = [:]
        var unmatchedConnectionCountersByProcess: [ProcessIdentity: TrafficCounter] = [:]
        var routeHintsByProcess: [ProcessIdentity: [TrafficRoute: TrafficCounter]] = [:]
        var deltas: [TrafficDelta] = []

        for process in snapshot.processes {
            nextProcessCounters[process.process] = process.counter
        }

        for connection in snapshot.connections where connection.isMeasurable {
            let key = ConnectionKey(connection)
            let current = connection.counter
            nextCounters[key] = current
            add(connection.counter, to: classifier.classify(connection), for: connection.process, in: &routeHintsByProcess)

            guard let previous = previousConnectionCounters[key],
                  let counterDelta = current.delta(from: previous) else {
                add(current, for: connection.process, in: &unmatchedConnectionCountersByProcess)
                continue
            }

            guard counterDelta.total > 0 else {
                continue
            }

            var connectionDeltaTotal = connectionDeltaTotalsByProcess[connection.process] ?? TrafficCounter()
            connectionDeltaTotal.add(counterDelta)
            connectionDeltaTotalsByProcess[connection.process] = connectionDeltaTotal

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

        for process in snapshot.processes {
            guard process.counter.total > 0,
                  let previous = previousProcessCounters[process.process],
                  let processDelta = process.counter.delta(from: previous),
                  processDelta.total > 0 else {
                continue
            }

            let covered = connectionDeltaTotalsByProcess[process.process] ?? TrafficCounter()
            let fallback = TrafficCounter(
                bytesIn: processDelta.bytesIn > covered.bytesIn ? processDelta.bytesIn - covered.bytesIn : 0,
                bytesOut: processDelta.bytesOut > covered.bytesOut ? processDelta.bytesOut - covered.bytesOut : 0
            )
            guard fallback.total > 0 else {
                continue
            }

            if shouldSuppressRepeatedFallback(
                fallback,
                covered: covered,
                currentUnmatched: unmatchedConnectionCountersByProcess[process.process],
                previousUnmatched: previousUnmatchedConnectionCountersByProcess[process.process]
            ) {
                continue
            }

            let route = dominantRoute(in: routeHintsByProcess[process.process] ?? [:])
            deltas.append(
                TrafficDelta(
                    timestamp: snapshot.timestamp,
                    appName: process.appName,
                    pid: process.pid,
                    route: route,
                    bytesIn: fallback.bytesIn,
                    bytesOut: fallback.bytesOut
                )
            )
        }

        previousConnectionCounters = nextCounters
        previousProcessCounters = nextProcessCounters
        previousUnmatchedConnectionCountersByProcess = unmatchedConnectionCountersByProcess
        return deltas
    }

    private func add(
        _ counter: TrafficCounter,
        for process: ProcessIdentity,
        in countersByProcess: inout [ProcessIdentity: TrafficCounter]
    ) {
        var processCounter = countersByProcess[process] ?? TrafficCounter()
        processCounter.add(counter)
        countersByProcess[process] = processCounter
    }

    private func add(
        _ counter: TrafficCounter,
        to route: TrafficRoute,
        for process: ProcessIdentity,
        in routeHintsByProcess: inout [ProcessIdentity: [TrafficRoute: TrafficCounter]]
    ) {
        var routes = routeHintsByProcess[process] ?? [:]
        var routeCounter = routes[route] ?? TrafficCounter()
        routeCounter.add(counter)
        routes[route] = routeCounter
        routeHintsByProcess[process] = routes
    }

    private func shouldSuppressRepeatedFallback(
        _ fallback: TrafficCounter,
        covered: TrafficCounter,
        currentUnmatched: TrafficCounter?,
        previousUnmatched: TrafficCounter?
    ) -> Bool {
        guard covered.total == 0,
              let currentUnmatched,
              let previousUnmatched,
              currentUnmatched.total > 0 else {
            return false
        }

        return currentUnmatched == previousUnmatched && fallback == currentUnmatched
    }

    private func dominantRoute(in routeCounters: [TrafficRoute: TrafficCounter]) -> TrafficRoute {
        routeCounters
            .filter { $0.value.total > 0 }
            .max { lhs, rhs in
                if lhs.value.total == rhs.value.total {
                    return routePriority(lhs.key) < routePriority(rhs.key)
                }
                return lhs.value.total < rhs.value.total
            }?
            .key ?? .unknown
    }

    private func routePriority(_ route: TrafficRoute) -> Int {
        switch route {
        case .proxy:
            return 4
        case .direct:
            return 3
        case .loopback:
            return 2
        case .unknown:
            return 1
        }
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
