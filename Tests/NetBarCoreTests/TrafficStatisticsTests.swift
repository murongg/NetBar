import XCTest
@testable import NetBarCore

final class TrafficStatisticsTests: XCTestCase {
    func testAggregatesBySelectedPeriodAndApp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 5, day: 7, hour: 12, minute: 45).date!
        let deltas = [
            TrafficDelta(timestamp: now.addingTimeInterval(-10 * 60), appName: "Safari", pid: 42, route: .proxy, bytesIn: 100, bytesOut: 200),
            TrafficDelta(timestamp: now.addingTimeInterval(-50 * 60), appName: "Safari", pid: 43, route: .direct, bytesIn: 10, bytesOut: 20),
            TrafficDelta(timestamp: now.addingTimeInterval(-2 * 60 * 60), appName: "Code", pid: 9, route: .direct, bytesIn: 1_000, bytesOut: 2_000),
            TrafficDelta(timestamp: now.addingTimeInterval(-9 * 24 * 60 * 60), appName: "Old", pid: 1, route: .direct, bytesIn: 9_000, bytesOut: 9_000)
        ]

        let hour = TrafficStatistics.aggregate(deltas, period: .hour, now: now, calendar: calendar)
        XCTAssertEqual(hour.map(\.appName), ["Safari"])
        XCTAssertEqual(hour[0].totalBytes, 300)

        let day = TrafficStatistics.aggregate(deltas, period: .day, now: now, calendar: calendar)
        XCTAssertEqual(day.map(\.appName), ["Code", "Safari"])
        XCTAssertEqual(day.first(where: { $0.appName == "Safari" })?.routeTotals[.proxy]?.total, 300)
        XCTAssertEqual(day.first(where: { $0.appName == "Safari" })?.routeTotals[.direct]?.total, 30)
    }
}
