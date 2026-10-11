import Foundation
import CryptoKit
import Network

/// A separate LAN discovery/approval channel. It never carries the streaming
/// credential in plaintext. Both users compare the code before Mac approval.
public enum RPPairingProtocol {
    public static let serviceType = "_roomplay-pair._tcp"
    public static let port: UInt16 = 47992
    public static let protocolVersion = 1
    public static let maxNameBytes = 128
    public static let maxMessageBytes = 2048

    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        return parameters
    }

    fileprivate static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.utf8.count <= maxNameBytes
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

public enum RPPairingError: LocalizedError, Equatable {
    case invalidMessage
    case unexpectedMessage
    case commitmentMismatch
    case invalidKey
    case credentialAuthenticationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidMessage: return "The Mac sent an invalid pairing message. Please try again."
        case .unexpectedMessage: return "This pairing request has expired. Please start a new request."
        case .commitmentMismatch: return "Pairing verification failed. Cancel and try again."
        case .invalidKey: return "A secure pairing connection could not be established."
        case .credentialAuthenticationFailed: return "The pairing credential could not be verified. Please try again."
        }
    }
}

public struct RPPairingRequest: Codable, Equatable {
    public let clientName: String
    public let protocolVersion: Int
    public let publicKey: Data
    public let nonceCommitment: Data

    public init(clientName: String, protocolVersion: Int = RPPairingProtocol.protocolVersion,
                publicKey: Data, nonceCommitment: Data) {
        self.clientName = clientName
        self.protocolVersion = protocolVersion
        self.publicKey = publicKey
        self.nonceCommitment = nonceCommitment
    }

    public var isValid: Bool {
        protocolVersion == RPPairingProtocol.protocolVersion
            && RPPairingProtocol.validName(clientName)
            && publicKey.count == 32 && nonceCommitment.count == 32
    }
}

public struct RPPairingOffer: Codable, Equatable {
    public let hostName: String
    public let protocolVersion: Int
    public let publicKey: Data
    public let serverNonce: Data

    public init(hostName: String, protocolVersion: Int = RPPairingProtocol.protocolVersion,
                publicKey: Data, serverNonce: Data) {
        self.hostName = hostName
        self.protocolVersion = protocolVersion
        self.publicKey = publicKey
        self.serverNonce = serverNonce
    }

    public var isValid: Bool {
        protocolVersion == RPPairingProtocol.protocolVersion
            && RPPairingProtocol.validName(hostName)
            && publicKey.count == 32 && serverNonce.count == 32
    }
}

public struct RPPairingReveal: Codable, Equatable {
    public let clientNonce: Data
    public init(clientNonce: Data) { self.clientNonce = clientNonce }
    public var isValid: Bool { clientNonce.count == 32 }
}

public struct RPPairingCredential: Codable, Equatable {
    /// AES-GCM combined format: 12-byte nonce, 32-byte credential, 16-byte tag.
    public let sealedSecret: Data
    public init(sealedSecret: Data) { self.sealedSecret = sealedSecret }
    public var isValid: Bool { sealedSecret.count == 60 }
}

/// One ephemeral client session. Keep it until the Mac approves or the user
/// cancels; create a new object for every retry. Messages must arrive in order.
public final class RPPairingClient {
    public let request: RPPairingRequest
    public private(set) var verificationCode: String?
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let clientNonce: Data
    private var material: RPPairingMaterial?
    private var receivedOffer = false
    private var finished = false

    public init(clientName: String) throws {
        guard RPPairingProtocol.validName(clientName) else { throw RPPairingError.invalidMessage }
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        clientNonce = try RPToken.generate()
        request = RPPairingRequest(clientName: clientName,
                                   publicKey: privateKey.publicKey.rawRepresentation,
                                   nonceCommitment: Data(SHA256.hash(data: clientNonce)))
    }

    public func receive(offer: RPPairingOffer) throws -> RPPairingReveal {
        guard !receivedOffer && !finished else { throw RPPairingError.unexpectedMessage }
        receivedOffer = true
        guard offer.isValid else { finished = true; throw RPPairingError.invalidMessage }
        do {
            let next = try RPPairingMaterial(privateKey: privateKey, peerPublicKey: offer.publicKey,
                                              request: request, offer: offer, clientNonce: clientNonce)
            material = next
            verificationCode = next.verificationCode
            return RPPairingReveal(clientNonce: clientNonce)
        } catch {
            finished = true
            throw error
        }
    }

    public func open(credential: RPPairingCredential) throws -> Data {
        guard receivedOffer && !finished, let material else { throw RPPairingError.unexpectedMessage }
        finished = true
        self.material = nil
        guard credential.isValid else { throw RPPairingError.invalidMessage }
        do {
            let sealed = try AES.GCM.SealedBox(combined: credential.sealedSecret)
            let secret = try AES.GCM.open(sealed, using: material.key, authenticating: material.authenticatedData)
            guard secret.count == 32 else { throw RPPairingError.invalidMessage }
            return secret
        } catch {
            throw RPPairingError.credentialAuthenticationFailed
        }
    }
}

/// One ephemeral host session. approve(secret:) is called only by the local
/// Mac approval action after its user compares the phone's six-digit code.
public final class RPPairingHost {
    public let offer: RPPairingOffer
    public var clientName: String { request.clientName }
    public private(set) var verificationCode: String?
    private let request: RPPairingRequest
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private var material: RPPairingMaterial?
    private var receivedReveal = false
    private var finished = false

    public init(request: RPPairingRequest, hostName: String) throws {
        guard request.isValid && RPPairingProtocol.validName(hostName) else { throw RPPairingError.invalidMessage }
        // Reject invalid/small-order peer keys before advertising an offer.
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        do {
            _ = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.publicKey))
        } catch { throw RPPairingError.invalidKey }
        privateKey = ephemeral
        self.request = request
        offer = RPPairingOffer(hostName: hostName,
                              publicKey: ephemeral.publicKey.rawRepresentation,
                              serverNonce: try RPToken.generate())
    }

    @discardableResult
    public func receive(reveal: RPPairingReveal) throws -> String {
        guard !receivedReveal && !finished else { throw RPPairingError.unexpectedMessage }
        receivedReveal = true
        guard reveal.isValid else { finished = true; throw RPPairingError.invalidMessage }
        guard Data(SHA256.hash(data: reveal.clientNonce)) == request.nonceCommitment else {
            finished = true
            throw RPPairingError.commitmentMismatch
        }
        do {
            let next = try RPPairingMaterial(privateKey: privateKey, peerPublicKey: request.publicKey,
                                              request: request, offer: offer, clientNonce: reveal.clientNonce)
            material = next
            verificationCode = next.verificationCode
            return next.verificationCode
        } catch {
            finished = true
            throw error
        }
    }

    public func approve(secret: Data) throws -> RPPairingCredential {
        guard receivedReveal && !finished, let material else { throw RPPairingError.unexpectedMessage }
        guard secret.count == 32 else { throw RPSecurityError.invalidSecret }
        finished = true
        self.material = nil
        let sealed = try AES.GCM.seal(secret, using: material.key, authenticating: material.authenticatedData)
        guard let combined = sealed.combined else { throw RPPairingError.invalidKey }
        return RPPairingCredential(sealedSecret: combined)
    }
}

private struct RPPairingMaterial {
    let key: SymmetricKey
    let authenticatedData: Data
    let verificationCode: String

    init(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data,
         request: RPPairingRequest, offer: RPPairingOffer, clientNonce: Data) throws {
        let sharedSecret: SharedSecret
        do {
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
            sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        } catch { throw RPPairingError.invalidKey }

        // Length-prefix every field instead of relying on JSON encoder ordering.
        // Bind role, version, names, both public keys, commitment and both nonces.
        var transcript = Data()
        for field in [Data("roomplay-local-pairing-v1".utf8),
                      Data(String(request.protocolVersion).utf8), Data(request.clientName.utf8),
                      request.publicKey, request.nonceCommitment,
                      Data(String(offer.protocolVersion).utf8), Data(offer.hostName.utf8),
                      offer.publicKey, offer.serverNonce, clientNonce] {
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { transcript.append(contentsOf: $0) }
            transcript.append(field)
        }
        let digest = Data(SHA256.hash(data: transcript))
        key = sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: digest,
                                                   sharedInfo: Data("roomplay-pairing-credential-v1".utf8),
                                                   outputByteCount: 32)
        authenticatedData = Data("roomplay-pairing-approved-credential-v1".utf8) + digest
        let sasKey = sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: digest,
                                                          sharedInfo: Data("roomplay-pairing-verification-v1".utf8),
                                                          outputByteCount: 32)
        let sas = Array(HMAC<SHA256>.authenticationCode(for: digest, using: sasKey))
        let value = (UInt32(sas[0]) << 24) | (UInt32(sas[1]) << 16) | (UInt32(sas[2]) << 8) | UInt32(sas[3])
        verificationCode = String(format: "%06u", value % 1_000_000)
    }
}
