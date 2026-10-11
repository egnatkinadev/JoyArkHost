import XCTest
@testable import RoomPlayKit

final class AddressTests: XCTestCase {
    func testLocalAddressesAndPublicAddressRejection() throws {
        for allowed in ["10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.1.4", "169.254.1.3",
                        "fe80::1", "fe80::1%en0", "[fd12::1234]", "My-Mac.local", "mac.local."] {
            XCTAssertTrue(RPAddress.isAllowed(allowed), allowed)
        }
        for denied in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "127.0.0.1", "0.0.0.0", "255.255.255.255",
                       "2001:4860:4860::8888", "::1", "example.com", "https://mac.local", "mac.local:1234",
                       "mac..local", "-mac.local", "mac.local@evil.com", "fd12::1%en0", "fe80::1%"] {
            XCTAssertFalse(RPAddress.isAllowed(denied), denied)
        }
    }

    func testPairingQRRoundTripAndTamperingRejection() throws {
        let token = try RPToken.generate()
        let pairing = try RPPairingAddress(host: "192.168.1.23", token: token, name: "John's Mac & Игры")
        XCTAssertEqual(try RPPairingAddress.decode(pairing.encoded()), pairing)
        XCTAssertThrowsError(try RPPairingAddress.decode(pairing.encoded() + "&token=" + RPToken.hexString(token)))
        XCTAssertThrowsError(try RPPairingAddress.decode(pairing.encoded().replacingOccurrences(of: "roomplay://", with: "https://")))
        XCTAssertThrowsError(try RPPairingAddress.decode(pairing.encoded().replacingOccurrences(of: "192.168.1.23", with: "8.8.8.8")))
        XCTAssertThrowsError(try RPPairingAddress(host: "mac.local", port: 0, token: token, name: "Mac"))
        XCTAssertThrowsError(try RPPairingAddress(host: "mac.local", token: Data(), name: "Mac"))
    }
}
