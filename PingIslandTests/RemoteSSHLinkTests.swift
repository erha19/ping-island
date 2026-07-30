import XCTest
@testable import NotchCode

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
        XCTAssertEqual(endpoint.sshKnownHostsLookupTarget, "example.com")
    }

    func testRemoteSSHLinkKeepsExplicitPort() throws {
        let endpoint = RemoteEndpoint(
            displayName: "Server",
            sshTarget: "dev@example.com:2201"
        )

        let link = try XCTUnwrap(endpoint.sshLink)
        XCTAssertEqual(endpoint.sshTarget, "dev@example.com")
        XCTAssertEqual(link.port, 2201)
        XCTAssertEqual(link.urlString, "ssh://dev@example.com:2201")
        XCTAssertEqual(endpoint.sshKnownHostsLookupTarget, "[example.com]:2201")
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
        XCTAssertEqual(endpoint.sshKnownHostsLookupTarget, "[2001:db8::10]:2202")
    }

    func testRemoteSSHLinkUsesExplicitEndpointPort() throws {
        let endpoint = RemoteEndpoint(
            displayName: "Server",
            sshTarget: "dev@example.com",
            sshPort: 2201
        )

        let link = try XCTUnwrap(endpoint.sshLink)
        XCTAssertEqual(link.port, 2201)
        XCTAssertEqual(endpoint.sshURL?.absoluteString, "ssh://dev@example.com:2201")
    }

    func testRemoteEndpointDecodesLegacyEmbeddedPortIntoDedicatedField() throws {
        let data = Data(
            """
            {
              "id": "6F4DFE8B-655D-4C62-88BB-9E3E0CB0C181",
              "displayName": "Legacy",
              "sshTarget": "dev@example.com:2201",
              "authMode": "publicKey",
              "remoteInstallRoot": "~/.ping-island",
              "remoteHookSocketPath": "~/.ping-island/run/agent-hook.sock",
              "remoteControlSocketPath": "~/.ping-island/run/agent-control.sock"
            }
            """.utf8
        )

        let endpoint = try JSONDecoder().decode(RemoteEndpoint.self, from: data)
        XCTAssertEqual(endpoint.sshTarget, "dev@example.com")
        XCTAssertEqual(endpoint.sshPort, 2201)
        XCTAssertEqual(endpoint.sshURL?.absoluteString, "ssh://dev@example.com:2201")
    }
}
