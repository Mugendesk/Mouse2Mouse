import Foundation
import CoreGraphics

/// Mouse2Mouse プロトコル定義
/// DESIGN.md に基づくWebSocketメッセージフォーマット

// MARK: - Message Types

enum MessageType: String, Codable {
    case cursorMove = "cursor_move"
    case mouseButton = "mouse_button"
    case scroll = "scroll"
    case key = "key"
    case controlTransfer = "control_transfer"
    case clipboard = "clipboard"
    case shortcut = "shortcut"
    case ping = "ping"
    case pong = "pong"
    case deviceInfo = "device_info"
    case pairingRequest = "pairing_request"
    case pairingResponse = "pairing_response"
    case screenLayout = "screen_layout"
    case filePrepare = "file_prepare"
    case fileRequest = "file_request"
    case fileData = "file_data"
    case fileComplete = "file_complete"
}

// MARK: - Base Message

struct M2MMessage: Codable {
    let type: MessageType
    let timestamp: Double

    init(type: MessageType) {
        self.type = type
        self.timestamp = Date().timeIntervalSince1970
    }
}

// MARK: - Cursor Messages

struct CursorMoveMessage: Codable {
    let type: String = "cursor_move"
    let x: Double
    let y: Double
    let timestamp: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
        self.timestamp = Date().timeIntervalSince1970
    }
}

// MARK: - Mouse Button Messages

enum ButtonState: String, Codable {
    case down
    case up
}

struct MouseButtonMessage: Codable {
    let type: String = "mouse_button"
    let button: Int  // 0=left, 1=right, 2=middle
    let state: ButtonState
    let timestamp: Double

    init(button: Int, state: ButtonState) {
        self.button = button
        self.state = state
        self.timestamp = Date().timeIntervalSince1970
    }
}

// MARK: - Scroll Messages

struct ScrollMessage: Codable {
    let type: String = "scroll"
    let dx: Double
    let dy: Double
    let timestamp: Double

    init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
        self.timestamp = Date().timeIntervalSince1970
    }
}

// MARK: - Key Messages

struct KeyMessage: Codable {
    let type: String = "key"
    let keycode: Int
    let state: ButtonState
    let modifiers: [String]
    let timestamp: Double

    init(keycode: Int, state: ButtonState, modifiers: [String] = []) {
        self.keycode = keycode
        self.state = state
        self.modifiers = modifiers
        self.timestamp = Date().timeIntervalSince1970
    }
}

// MARK: - Control Transfer

struct ControlTransferMessage: Codable {
    let type: String = "control_transfer"
    let to: String  // device_id
    let entryX: Double  // 0.0-1.0 normalized
    let entryY: Double  // 0.0-1.0 normalized
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case type
        case to
        case entryX = "entry_x"
        case entryY = "entry_y"
        case timestamp
    }

    init(to: String, entryX: Double, entryY: Double) {
        self.to = to
        self.entryX = entryX
        self.entryY = entryY
        self.timestamp = Date().timeIntervalSince1970
    }
}

// MARK: - Clipboard

enum ClipboardFormat: String, Codable {
    case text
    case image
    case fileReference = "file_reference"
}

struct ClipboardMessage: Codable {
    let type: String = "clipboard"
    let format: ClipboardFormat
    let data: String  // text or base64 encoded
    let timestamp: Double

    init(format: ClipboardFormat, data: String) {
        self.format = format
        self.data = data
        self.timestamp = Date().timeIntervalSince1970
    }
}

// MARK: - Device Info

enum DeviceType: String, Codable {
    case mac
    case ios
}

struct DeviceInfoMessage: Codable {
    let type: String = "device_info"
    let deviceId: String
    let hostname: String
    let deviceType: DeviceType
    let screenWidth: Int
    let screenHeight: Int
    let version: String
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case type
        case deviceId = "device_id"
        case hostname
        case deviceType = "device_type"
        case screenWidth = "screen_width"
        case screenHeight = "screen_height"
        case version
        case timestamp
    }

    init(deviceId: String, hostname: String, deviceType: DeviceType, screenWidth: Int, screenHeight: Int) {
        self.deviceId = deviceId
        self.hostname = hostname
        self.deviceType = deviceType
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.version = "1"
        self.timestamp = Date().timeIntervalSince1970
    }
}

// MARK: - Pairing

struct PairingRequestMessage: Codable {
    let type: String = "pairing_request"
    let deviceId: String
    let hostname: String
    let publicKey: String  // Base64 encoded X25519 public key
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case type
        case deviceId = "device_id"
        case hostname
        case publicKey = "public_key"
        case timestamp
    }

    init(deviceId: String, hostname: String, publicKey: String) {
        self.deviceId = deviceId
        self.hostname = hostname
        self.publicKey = publicKey
        self.timestamp = Date().timeIntervalSince1970
    }
}

struct PairingResponseMessage: Codable {
    let type: String = "pairing_response"
    let accepted: Bool
    let pairingCode: String?  // 6-digit code
    let publicKey: String?  // Base64 encoded X25519 public key
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case type
        case accepted
        case pairingCode = "pairing_code"
        case publicKey = "public_key"
        case timestamp
    }

    init(accepted: Bool, pairingCode: String? = nil, publicKey: String? = nil) {
        self.accepted = accepted
        self.pairingCode = pairingCode
        self.publicKey = publicKey
        self.timestamp = Date().timeIntervalSince1970
    }
}

// MARK: - Screen Layout

struct ScreenLayoutMessage: Codable {
    let type: String = "screen_layout"
    let localDeviceId: String
    let edge: String  // "left", "right", "top", "bottom" - 相手から見た自分の位置
    let offsetX: Double
    let offsetY: Double
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case type
        case localDeviceId = "local_device_id"
        case edge
        case offsetX = "offset_x"
        case offsetY = "offset_y"
        case timestamp
    }

    init(localDeviceId: String, edge: String, offsetX: Double, offsetY: Double) {
        self.localDeviceId = localDeviceId
        self.edge = edge
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.timestamp = Date().timeIntervalSince1970
    }
}

// MARK: - File Transfer Messages

struct FilePrepareMessage: Codable {
    let type: String = "file_prepare"
    let transferId: String
    let fileName: String
    let fileSize: Int64
    let fileType: String
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case type
        case transferId = "transfer_id"
        case fileName = "file_name"
        case fileSize = "file_size"
        case fileType = "file_type"
        case timestamp
    }

    init(transferId: String, fileName: String, fileSize: Int64, fileType: String) {
        self.transferId = transferId
        self.fileName = fileName
        self.fileSize = fileSize
        self.fileType = fileType
        self.timestamp = Date().timeIntervalSince1970
    }
}

struct FileRequestMessage: Codable {
    let type: String = "file_request"
    let path: String
    let requestId: String
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case type
        case path
        case requestId = "request_id"
        case timestamp
    }

    init(path: String, requestId: String) {
        self.path = path
        self.requestId = requestId
        self.timestamp = Date().timeIntervalSince1970
    }
}

struct FileDataMessage: Codable {
    let type: String = "file_data"
    let transferId: String
    let chunkIndex: Int
    let totalChunks: Int
    let data: String  // Base64 encoded
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case type
        case transferId = "transfer_id"
        case chunkIndex = "chunk_index"
        case totalChunks = "total_chunks"
        case data
        case timestamp
    }

    init(transferId: String, chunkIndex: Int, totalChunks: Int, data: String) {
        self.transferId = transferId
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
        self.data = data
        self.timestamp = Date().timeIntervalSince1970
    }
}

struct FileCompleteMessage: Codable {
    let type: String = "file_complete"
    let transferId: String
    let success: Bool
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case type
        case transferId = "transfer_id"
        case success
        case timestamp
    }

    init(transferId: String, success: Bool) {
        self.transferId = transferId
        self.success = success
        self.timestamp = Date().timeIntervalSince1970
    }
}

// MARK: - Message Encoding/Decoding

class MessageEncoder {
    static let shared = MessageEncoder()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func encode<T: Encodable>(_ message: T) -> String? {
        guard let data = try? encoder.encode(message),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    func decodeType(from string: String) -> MessageType? {
        guard let data = string.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeString = json["type"] as? String,
              let type = MessageType(rawValue: typeString) else {
            return nil
        }
        return type
    }

    func decode<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard let data = string.data(using: .utf8),
              let message = try? decoder.decode(type, from: data) else {
            return nil
        }
        return message
    }
}
