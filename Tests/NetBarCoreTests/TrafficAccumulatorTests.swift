import XCTest
@testable import NetBarCore

final class TrafficAccumulatorTests: XCTestCase {
    func testEmitsRouteDeltasAfterBaseline() throws {
        let base = Date(timeIntervalSince1970: 100)
        let proxySettings = ProxySettings(ports: [7890])
        let parser = NettopCSVParser()
        var accumulator = TrafficAccumulator()

        let first = try parser.parse(Self.sample(proxyIn: 10, proxyOut: 20, directIn: 100, directOut: 200), timestamp: base)
        XCTAssertTrue(accumulator.ingest(first, proxySettings: proxySettings).isEmpty)

        let second = try parser.parse(Self.sample(proxyIn: 35, proxyOut: 90, directIn: 160, directOut: 260), timestamp: base.addingTimeInterval(5))
        let deltas = accumulator.ingest(second, proxySettings: proxySettings)

        XCTAssertEqual(deltas.count, 2)
        XCTAssertEqual(deltas.first(where: { $0.route == .proxy })?.bytesIn, 25)
        XCTAssertEqual(deltas.first(where: { $0.route == .proxy })?.bytesOut, 70)
        XCTAssertEqual(deltas.first(where: { $0.route == .direct })?.bytesIn, 60)
        XCTAssertEqual(deltas.first(where: { $0.route == .direct })?.bytesOut, 60)
    }

    func testCounterResetIsIgnoredAndRebaselined() throws {
        let proxySettings = ProxySettings(ports: [])
        let parser = NettopCSVParser()
        var accumulator = TrafficAccumulator()

        _ = accumulator.ingest(try parser.parse(Self.sample(proxyIn: 0, proxyOut: 0, directIn: 1_000, directOut: 2_000), timestamp: Date(timeIntervalSince1970: 0)), proxySettings: proxySettings)
        let resetDeltas = accumulator.ingest(try parser.parse(Self.sample(proxyIn: 0, proxyOut: 0, directIn: 5, directOut: 10), timestamp: Date(timeIntervalSince1970: 5)), proxySettings: proxySettings)
        XCTAssertTrue(resetDeltas.isEmpty)

        let nextDeltas = accumulator.ingest(try parser.parse(Self.sample(proxyIn: 0, proxyOut: 0, directIn: 15, directOut: 25), timestamp: Date(timeIntervalSince1970: 10)), proxySettings: proxySettings)
        XCTAssertEqual(nextDeltas.single?.bytesIn, 10)
        XCTAssertEqual(nextDeltas.single?.bytesOut, 15)
    }

    private static func sample(proxyIn: UInt64, proxyOut: UInt64, directIn: UInt64, directOut: UInt64) -> String {
        """
        time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
        12:00:00.100000,Safari.42,,,0,0,0,0,0,,,,,,,,,,,,
        12:00:00.100001,tcp4 127.0.0.1:50100<->127.0.0.1:7890,lo0,Established,\(proxyIn),\(proxyOut),0,0,0,1.00 ms,131072,131072,BE,-,cubic,-,-,-,-,so,
        12:00:00.100002,tcp4 192.168.1.2:50101<->93.184.216.34:443,en0,Established,\(directIn),\(directOut),0,0,0,20.00 ms,131072,131072,BE,-,cubic,-,-,-,-,so,
        """
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? self[0] : nil
    }
}
