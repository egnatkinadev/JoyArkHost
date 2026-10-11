import Foundation
import Network
import Security

public enum RPSecurityError: LocalizedError {
    case invalidSecret
    case randomGenerationFailed(OSStatus)
    case invalidToken

    public var errorDescription: String? {
        switch self {
        case .invalidSecret: return "The pairing token must contain exactly 32 bytes."
        case .randomGenerationFailed: return "A secure pairing token could not be created."
        case .invalidToken: return "Enter the 64-character pairing token shown on your Mac."
        }
    }
}

public enum RPToken {
    public static func generate() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw RPSecurityError.randomGenerationFailed(result) }
        return Data(bytes)
    }

    public static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func data(from hex: String) throws -> Data {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count == 64, cleaned.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw RPSecurityError.invalidToken }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let end = cleaned.index(index, offsetBy: 2)
            guard let value = UInt8(cleaned[index..<end], radix: 16) else {
                throw RPSecurityError.invalidToken
            }
            bytes.append(value)
            index = end
        }
        return Data(bytes)
    }
}

public enum RPSecurity {
    /// TLS 1.2 authenticates both ends using a random 256-bit secret. No certificate
    /// trust bypass or plaintext pairing exchange is used. Share the token locally.
    public static func parameters(secret: Data) throws -> NWParameters {
        guard secret.count == 32 else { throw RPSecurityError.invalidSecret }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0x00A9)!)
        let key = secret.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("roomplay-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_set_tls_pre_shared_key_identity_hint(options, identity as __DispatchData)
        sec_protocol_options_add_tls_application_protocol(options, "roomplay/1")
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        return parameters
    }
}
