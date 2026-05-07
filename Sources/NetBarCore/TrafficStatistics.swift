import Foundation

public struct AppTrafficSummary: Equatable, Sendable {
    public let appName: String
    public private(set) var routeTotals: [TrafficRoute: TrafficCounter]

    public init(appName: String, routeTotals: [TrafficRoute: TrafficCounter] = [:]) {
        self.appName = appName
        self.routeTotals = routeTotals
    }

    public var totalBytes: UInt64 {
        routeTotals.values.reduce(UInt64(0)) { $0 + $1.total }
    }

    public mutating func add(_ delta: TrafficDelta) {
        var counter = routeTotals[delta.route] ?? TrafficCounter()
        counter.add(delta.counter)
        routeTotals[delta.route] = counter
    }
}

public enum TrafficStatistics {
    public static func aggregate(
        _ deltas: [TrafficDelta],
        period: StatisticsPeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AppTrafficSummary] {
        let startDate = period.startDate(now: now, calendar: calendar)
        var grouped: [String: AppTrafficSummary] = [:]

        for delta in deltas where delta.timestamp >= startDate && delta.timestamp <= now {
            var summary = grouped[delta.appName] ?? AppTrafficSummary(appName: delta.appName)
            summary.add(delta)
            grouped[delta.appName] = summary
        }

        return grouped.values.sorted {
            if $0.totalBytes == $1.totalBytes {
                return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
            return $0.totalBytes > $1.totalBytes
        }
    }
}
