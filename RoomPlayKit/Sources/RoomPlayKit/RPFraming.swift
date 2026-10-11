import Foundation

public enum RPTransportError: LocalizedError, Equatable {
    case oversizedPayload
    case unknownMessageType
    case notConnected
    case backpressure
    case incompleteFrame

    public var errorDescription: String? {
        switch self {
        case .oversizedPayload: return "The stream sent a packet larger than the supported limit."
        case .unknownMessageType: return "The Mac and iPhone use incompatible stream protocols."
        case .notConnected: return "The connection is not ready."
        case .backpressure: return "The network cannot accept another frame yet."
        case .incompleteFrame: return "The stream ended during a packet."
        }
    }
}

public enum RPFraming {
    /// One-byte message type followed by a four-byte big-endian payload length.
    public static func encode(_ message: RPMessage) throws -> Data {
        guard message.payload.count <= RPProtocol.maxPayload else { throw RPTransportError.oversizedPayload }
        let count = UInt32(message.payload.count)
        var data = Data([message.type.rawValue,
                         UInt8((count >> 24) & 0xff), UInt8((count >> 16) & 0xff),
                         UInt8((count >> 8) & 0xff), UInt8(count & 0xff)])
        data.append(message.payload)
        return data
    }
}

/// Incremental parser. The incomplete frame never retains more than maxPayload + 5
/// bytes, even when a peer fragments the header or advertises a malicious length.
public struct RPFrameParser {
    private let maxPayload: Int
    private var header = Data()
    private var payload = Data()
    private var type: RPMessageType?
    private var expectedLength = 0
    public var hasIncompleteFrame: Bool { !header.isEmpty || type != nil }
    public var bufferedBytes: Int { header.count + payload.count }

    public init(maxPayload: Int = RPProtocol.maxPayload) {
        self.maxPayload = max(0, min(maxPayload, RPProtocol.maxPayload))
    }

    public mutating func append(_ bytes: Data) throws -> [RPMessage] {
        var messages = [RPMessage]()
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            if type == nil {
                let count = min(5 - header.count, bytes.distance(from: cursor, to: bytes.endIndex))
                let end = bytes.index(cursor, offsetBy: count)
                header.append(bytes[cursor..<end])
                cursor = end
                guard header.count == 5 else { continue }
                let headerBytes = [UInt8](header)
                guard let nextType = RPMessageType(rawValue: headerBytes[0]) else {
                    throw RPTransportError.unknownMessageType
                }
                let length = (UInt32(headerBytes[1]) << 24) | (UInt32(headerBytes[2]) << 16)
                    | (UInt32(headerBytes[3]) << 8) | UInt32(headerBytes[4])
                guard length <= maxPayload else { throw RPTransportError.oversizedPayload }
                type = nextType
                expectedLength = Int(length)
                header.removeAll(keepingCapacity: true)
                if expectedLength == 0 {
                    messages.append(RPMessage(type: nextType))
                    type = nil
                }
            } else if let currentType = type {
                let count = min(expectedLength - payload.count, bytes.distance(from: cursor, to: bytes.endIndex))
                let end = bytes.index(cursor, offsetBy: count)
                payload.append(bytes[cursor..<end])
                cursor = end
                if payload.count == expectedLength {
                    messages.append(RPMessage(type: currentType, payload: payload))
                    payload = Data()
                    type = nil
                    expectedLength = 0
                }
            }
        }
        return messages
    }

    public func finish() throws {
        guard !hasIncompleteFrame else { throw RPTransportError.incompleteFrame }
    }
}
