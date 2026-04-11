import XCTest
@testable import Ping_Island

final class RemoteSSHLinkTests: XCTestCase {
    func testRemoteSSHLinkDefaultsToPort22() throws {
        let endpoint = RemoteEndpoint(
            displayName: "Server",
            sshTarget: "dev@example.com"
        )

        let link = try XCTUnwrap(endpoint.sshLink)
        XCTAssertEqual(link.username, "dev")
        XCTAssertEqual(link.host, "example.com")
        XCTAssertEqual(link.port, 22)
        XCTAssertEqual(link.urlString, "ssh://dev@example.com:22")
        XCTAssertEqual(endpoint.sshURL?.absoluteString, "ssh://dev@example.com:22")
    }

    func testRemoteSSHLinkKeepsExplicitPort() throws {
        let endpoint = RemoteEndpoint(
            displayName: "Server",
            sshTarget: "dev@example.com:2201"
        )

        let link = try XCTUnwrap(endpoint.sshLink)
        XCTAssertEqual(link.port, 2201)
        XCTAssertEqual(link.urlString, "ssh://dev@example.com:2201")
    }

    func testRemoteSSHLinkParsesBracketedIPv6Host() throws {
        let endpoint = RemoteEndpoint(
            displayName: "IPv6",
            sshTarget: "root@[2001:db8::10]:2202"
        )

        let link = try XCTUnwrap(endpoint.sshLink)
        XCTAssertEqual(link.username, "root")
        XCTAssertEqual(link.host, "2001:db8::10")
        XCTAssertEqual(link.port, 2202)
        XCTAssertEqual(link.urlString, "ssh://root@[2001:db8::10]:2202")
    }
}
