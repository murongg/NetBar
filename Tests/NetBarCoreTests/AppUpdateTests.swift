import XCTest
@testable import NetBarCore

final class AppUpdateTests: XCTestCase {
    func testCurrentVersionHasDisplayAndTagStrings() throws {
        let version = AppVersion.current

        XCTAssertEqual(version.displayString, "0.1.8")
        XCTAssertEqual(version.tagString, "v0.1.8")
    }

    func testComparesSemanticVersionsFromTags() throws {
        let older = try XCTUnwrap(AppVersion("v0.1.9"))
        let newer = try XCTUnwrap(AppVersion("v0.2.0"))
        let release = try XCTUnwrap(AppVersion("v1.0.0"))
        let prerelease = try XCTUnwrap(AppVersion("v1.0.0-beta.1"))

        XCTAssertLessThan(older, newer)
        XCTAssertLessThan(prerelease, release)
    }

    func testDecodesGitHubReleaseAndDetectsUpdate() throws {
        let data = Data("""
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/murongg/NetBar/releases/tag/v0.2.0"
        }
        """.utf8)

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let status = AppUpdateEvaluator.evaluate(release: release, currentVersion: try XCTUnwrap(AppVersion("0.1.0")))

        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(status, .updateAvailable(
            currentVersion: try XCTUnwrap(AppVersion("0.1.0")),
            latestVersion: try XCTUnwrap(AppVersion("v0.2.0")),
            releaseURL: try XCTUnwrap(URL(string: "https://github.com/murongg/NetBar/releases/tag/v0.2.0"))
        ))
    }

    func testDetectsUpToDateRelease() throws {
        let release = GitHubRelease(
            tagName: "v0.1.0",
            releaseURL: try XCTUnwrap(URL(string: "https://github.com/murongg/NetBar/releases/tag/v0.1.0"))
        )

        let status = AppUpdateEvaluator.evaluate(release: release, currentVersion: try XCTUnwrap(AppVersion("0.1.0")))

        XCTAssertEqual(status, .upToDate(currentVersion: try XCTUnwrap(AppVersion("0.1.0"))))
    }

    func testCheckerTreatsMissingLatestReleaseAsNoPublishedRelease() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            ))
            return (response, Data())
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let checker = GitHubUpdateChecker(
            owner: "murongg",
            repository: "NetBar",
            currentVersion: try XCTUnwrap(AppVersion("0.1.0")),
            session: URLSession(configuration: configuration)
        )

        let status = try await checker.check()

        XCTAssertEqual(status, .noPublishedRelease(currentVersion: try XCTUnwrap(AppVersion("0.1.0"))))
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            XCTFail("Missing request handler")
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
