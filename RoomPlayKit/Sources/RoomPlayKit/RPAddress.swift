import Foundation
import Darwin

public enum RPAddressError: LocalizedError {
    case invalidAddress
    case invalidPairingAddress

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter your Mac's private local IP address or a name ending in .local."
        case .invalidPairingAddress: return "This is not a valid RoomPlay pairing code."
        }
    }
}

public enum RPAddress {
    public static func isAllowed(_ address: String) -> Bool {
        (try? normalize(address)) != nil
    }

    public static func normalize(_ address: String) throws -> String {
        var host = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host.removeFirst(); host.removeLast() }
        guard !host.isEmpty, host.count <= 253,
              !host.contains("/"), !host.contains("@"), !host.contains("?"),
              !host.contains("#"), !host.contains(where: { $0.isWhitespace }) else {
            throw RPAddressError.invalidAddress
        }
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            let allowed = bytes[0] == 10
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254)
            guard allowed else { throw RPAddressError.invalidAddress }
            return host
        }
        let scoped = host.split(separator: "%", omittingEmptySubsequences: false)
        guard scoped.count <= 2 else { throw RPAddressError.invalidAddress }
        if scoped.count == 2 {
            guard !scoped[1].isEmpty, scoped[1].utf8.allSatisfy({
                (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }) else { throw RPAddressError.invalidAddress }
        }
        var ipv6 = in6_addr()
        if String(scoped[0]).withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            let uniqueLocal = (bytes[0] & 0xfe) == 0xfc
            guard (linkLocal || uniqueLocal), scoped.count == 1 || linkLocal else {
                throw RPAddressError.invalidAddress
            }
            return host
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard host.hasSuffix(".local"), !host.contains(":") else { throw RPAddressError.invalidAddress }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
        }) else { throw RPAddressError.invalidAddress }
        return host
    }
}

public struct RPPairingAddress: Equatable {
    public let host: String
    public let port: UInt16
    public let token: Data
    public let name: String

    public init(host: String, port: UInt16 = RPProtocol.port, token: Data, name: String) throws {
        self.host = try RPAddress.normalize(host)
        guard port > 0, token.count == 32, !name.isEmpty, name.count <= 128 else {
            throw RPAddressError.invalidPairingAddress
        }
        self.port = port
        self.token = token
        self.name = name
    }

    public func encoded() -> String {
        var components = URLComponents()
        components.scheme = "roomplay"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "token", value: RPToken.hexString(token)),
            URLQueryItem(name: "name", value: name)
        ]
        // All components are constructed from validated values and URLComponents
        // applies the query escaping; this cannot include an invalid host or port.
        return components.string!
    }

    public static func decode(_ string: String) throws -> RPPairingAddress {
        guard string.count <= 2048,
              let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "roomplay", components.host?.lowercased() == "pair",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, components.path.isEmpty,
              let items = components.queryItems, items.count == 4,
              Set(items.map(\.name)) == Set(["host", "port", "token", "name"]) else {
            throw RPAddressError.invalidPairingAddress
        }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard let port = UInt16(values["port"] ?? ""),
              let tokenString = values["token"], let host = values["host"], let name = values["name"] else {
            throw RPAddressError.invalidPairingAddress
        }
        return try RPPairingAddress(host: host, port: port, token: RPToken.data(from: tokenString), name: name)
    }
}
