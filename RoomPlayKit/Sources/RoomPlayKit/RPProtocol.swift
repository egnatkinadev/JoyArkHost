import Foundation

public enum RPProtocol {
    public static let serviceType = "_roomplay._tcp"
    public static let port: UInt16 = 47991
    public static let protocolVersion = 1
    public static let maxPayload = 4 * 1024 * 1024
    public static let audioSampleRate = 48_000
    public static let audioChannels = 2
}

public enum RPMessageType: UInt8, Codable, CaseIterable {
    case hello = 1, welcome, start, stop, videoConfig, video, audio, input, failure, ping, pong, requestKeyframe
    case pairRequest = 32, pairOffer, pairReveal, pairCredential, pairReject, pairCancel
}

public struct RPMessage: Equatable {
    public let type: RPMessageType
    public let payload: Data

    public init(type: RPMessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }

    public static func json<T: Encodable>(type: RPMessageType, value: T) throws -> RPMessage {
        RPMessage(type: type, payload: try JSONEncoder().encode(value))
    }
}

public struct RPHello: Codable, Equatable {
    public var clientName: String
    public var protocolVersion: Int
    public init(clientName: String, protocolVersion: Int = RPProtocol.protocolVersion) {
        self.clientName = clientName
        self.protocolVersion = protocolVersion
    }
}

public struct RPWelcome: Codable, Equatable {
    public var hostName: String
    public var protocolVersion: Int
    public var controlAvailable: Bool
    public init(hostName: String, protocolVersion: Int = RPProtocol.protocolVersion, controlAvailable: Bool) {
        self.hostName = hostName
        self.protocolVersion = protocolVersion
        self.controlAvailable = controlAvailable
    }
}

public struct RPStreamOptions: Codable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrateMbps: Int
    public var audioEnabled: Bool
    public init(width: Int, height: Int, fps: Int, bitrateMbps: Int, audioEnabled: Bool) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateMbps = bitrateMbps
        self.audioEnabled = audioEnabled
    }

    public var isValid: Bool {
        (320...3840).contains(width) && (180...2160).contains(height)
            && width.isMultiple(of: 2) && height.isMultiple(of: 2)
            && [30, 60].contains(fps) && (2...50).contains(bitrateMbps)
    }
}

public struct RPVideoConfiguration: Codable, Equatable {
    public var parameterSets: [Data]
    public var width: Int
    public var height: Int
    public init(parameterSets: [Data], width: Int, height: Int) {
        self.parameterSets = parameterSets
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        (320...3840).contains(width) && (180...2160).contains(height)
            && parameterSets.count == 2
            && parameterSets.allSatisfy { !$0.isEmpty && $0.count <= 65_536 }
    }
}

public struct RPErrorMessage: Codable, Equatable {
    public var message: String
    public init(message: String) { self.message = message }
}

public enum RPInputKind: String, Codable, CaseIterable {
    case key, mouseMove, mouseButton, releaseAll
}

public struct RPInputEvent: Codable, Equatable {
    public var kind: RPInputKind
    public var keyCode: UInt16?
    public var pressed: Bool?
    public var x: Double?
    public var y: Double?
    public var button: Int?
    public init(kind: RPInputKind, keyCode: UInt16? = nil, pressed: Bool? = nil,
                x: Double? = nil, y: Double? = nil, button: Int? = nil) {
        self.kind = kind
        self.keyCode = keyCode
        self.pressed = pressed
        self.x = x
        self.y = y
        self.button = button
    }

    public var isValid: Bool {
        switch kind {
        case .key: return keyCode.map { $0 <= 127 } == true && pressed != nil
        case .mouseMove:
            guard let x, let y else { return false }
            return x.isFinite && y.isFinite && abs(x) <= 4096 && abs(y) <= 4096
        case .mouseButton: return button.map { (0...2).contains($0) } == true && pressed != nil
        case .releaseAll: return true
        }
    }
}
