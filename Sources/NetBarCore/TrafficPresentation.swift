import Foundation

public struct TrafficDashboardPresentation: Equatable, Sendable {
    public let periodTitle: String
    public let totalLabel: String
    public let proxyLabel: String
    public let directLabel: String
    public let loopbackLabel: String
    public let unknownLabel: String
    public let items: [TrafficAppPresentation]

    public init(
        periodTitle: String,
        totalLabel: String,
        proxyLabel: String,
        directLabel: String,
        loopbackLabel: String,
        unknownLabel: String,
        items: [TrafficAppPresentation]
    ) {
        self.periodTitle = periodTitle
        self.totalLabel = totalLabel
        self.proxyLabel = proxyLabel
        self.directLabel = directLabel
        self.loopbackLabel = loopbackLabel
        self.unknownLabel = unknownLabel
        self.items = items
    }
}

public struct TrafficAppPresentation: Equatable, Sendable {
    public let appName: String
    public let totalLabel: String
    public let detailLabel: String
    public let share: Double
    public let routes: [TrafficRoutePresentation]

    public init(appName: String, totalLabel: String, detailLabel: String, share: Double, routes: [TrafficRoutePresentation]) {
        self.appName = appName
        self.totalLabel = totalLabel
        self.detailLabel = detailLabel
        self.share = share
        self.routes = routes
    }
}

public struct TrafficRoutePresentation: Equatable, Sendable {
    public let route: TrafficRoute
    public let title: String
    public let totalLabel: String
    public let detailLabel: String
    public let fraction: Double

    public init(route: TrafficRoute, title: String, totalLabel: String, detailLabel: String, fraction: Double) {
        self.route = route
        self.title = title
        self.totalLabel = totalLabel
        self.detailLabel = detailLabel
        self.fraction = fraction
    }
}

public struct StatusBarRateLayout: Equatable, Sendable {
    public let iconSize: Double
    public let lineHeight: Double
    public let spacing: Double
    public let horizontalPadding: Double
    public let textColumnWidth: Double
    public let minimumItemHeight: Double

    public init(iconSize: Double, lineHeight: Double, spacing: Double, horizontalPadding: Double, textColumnWidth: Double, minimumItemHeight: Double) {
        self.iconSize = iconSize
        self.lineHeight = lineHeight
        self.spacing = spacing
        self.horizontalPadding = horizontalPadding
        self.textColumnWidth = textColumnWidth
        self.minimumItemHeight = minimumItemHeight
    }

    public var textBlockHeight: Double {
        lineHeight * 2
    }

    public var contentHeight: Double {
        max(iconSize, textBlockHeight)
    }

    public var statusItemWidth: Double {
        horizontalPadding * 2 + iconSize + spacing + textColumnWidth + 8
    }
}

public enum TrafficPresentation {
    public static let statusBarRateLayout = StatusBarRateLayout(
        iconSize: 14,
        lineHeight: 10,
        spacing: 3,
        horizontalPadding: 2.5,
        textColumnWidth: 48,
        minimumItemHeight: 22
    )

    public static func rateLabel(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) -> String {
        "↓ \(ByteFormatting.rate(downloadBytesPerSecond))  ↑ \(ByteFormatting.rate(uploadBytesPerSecond))"
    }

    public static func stackedRateLabel(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) -> String {
        "↓ \(ByteFormatting.rate(downloadBytesPerSecond))\n↑ \(ByteFormatting.rate(uploadBytesPerSecond))"
    }

    public static func statusBarRateLabel(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) -> String {
        "↓\(ByteFormatting.compactRate(downloadBytesPerSecond))\n↑\(ByteFormatting.compactRate(uploadBytesPerSecond))"
    }

    public static func inlineStatusBarRateLabel(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) -> String {
        statusBarRateLabel(
            downloadBytesPerSecond: downloadBytesPerSecond,
            uploadBytesPerSecond: uploadBytesPerSecond
        )
        .replacingOccurrences(of: "\n", with: "  ")
    }

    public static func appIconSearchNames(for appName: String) -> [String] {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        var names: [String] = []
        append(trimmed, to: &names)

        if let parenRange = trimmed.range(of: " (", options: [.backwards]) {
            append(String(trimmed[..<parenRange.lowerBound]), to: &names)
        }

        let helperSuffixes = [
            " Helper",
            " Helper (Renderer)",
            " Helper (Plugin)",
            " Helper (GPU)",
            " Helper (Alerts)"
        ]

        for name in Array(names) {
            for suffix in helperSuffixes where name.hasSuffix(suffix) {
                append(String(name.dropLast(suffix.count)), to: &names)
            }
        }

        return names
    }

    public static func dashboard(
        summaries: [AppTrafficSummary],
        period: StatisticsPeriod,
        limit: Int = 12
    ) -> TrafficDashboardPresentation {
        let routeTotals = routeTotals(in: summaries)
        let totalBytes = routeTotals.values.reduce(UInt64(0)) { $0 + $1.total }
        let maxAppBytes = summaries.map(\.totalBytes).max() ?? 0

        let items = summaries.prefix(limit).map { summary in
            appPresentation(summary, maxAppBytes: maxAppBytes)
        }

        return TrafficDashboardPresentation(
            periodTitle: period.title,
            totalLabel: ByteFormatting.bytes(totalBytes),
            proxyLabel: ByteFormatting.bytes(routeTotals[.proxy]?.total ?? 0),
            directLabel: ByteFormatting.bytes(routeTotals[.direct]?.total ?? 0),
            loopbackLabel: ByteFormatting.bytes(routeTotals[.loopback]?.total ?? 0),
            unknownLabel: ByteFormatting.bytes(routeTotals[.unknown]?.total ?? 0),
            items: items
        )
    }

    private static func routeTotals(in summaries: [AppTrafficSummary]) -> [TrafficRoute: TrafficCounter] {
        var totals: [TrafficRoute: TrafficCounter] = [:]
        for summary in summaries {
            for (route, counter) in summary.routeTotals {
                var total = totals[route] ?? TrafficCounter()
                total.add(counter)
                totals[route] = total
            }
        }
        return totals
    }

    private static func appPresentation(_ summary: AppTrafficSummary, maxAppBytes: UInt64) -> TrafficAppPresentation {
        let routes = TrafficRoute.allCases.compactMap { route -> TrafficRoutePresentation? in
            guard let counter = summary.routeTotals[route], counter.total > 0 else {
                return nil
            }

            return TrafficRoutePresentation(
                route: route,
                title: route.title,
                totalLabel: ByteFormatting.bytes(counter.total),
                detailLabel: "Down \(ByteFormatting.bytes(counter.bytesIn))  Up \(ByteFormatting.bytes(counter.bytesOut))",
                fraction: summary.totalBytes > 0 ? Double(counter.total) / Double(summary.totalBytes) : 0
            )
        }

        let share = maxAppBytes > 0 ? Double(summary.totalBytes) / Double(maxAppBytes) : 0
        let totalCounter = summary.routeTotals.values.reduce(TrafficCounter()) { partial, counter in
            var next = partial
            next.add(counter)
            return next
        }

        return TrafficAppPresentation(
            appName: summary.appName,
            totalLabel: ByteFormatting.bytes(summary.totalBytes),
            detailLabel: "Down \(ByteFormatting.bytes(totalCounter.bytesIn))  Up \(ByteFormatting.bytes(totalCounter.bytesOut))",
            share: share,
            routes: routes
        )
    }

    private static func append(_ value: String, to names: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !names.contains(trimmed) else {
            return
        }
        names.append(trimmed)
    }
}
