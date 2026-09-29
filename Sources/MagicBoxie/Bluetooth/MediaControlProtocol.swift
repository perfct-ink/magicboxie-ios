import CoreBluetooth
import Foundation

/// Wire format shared with the MagicBoxie device's BLE GATT peripheral.
enum MediaControlProtocol {
    static let serviceUUID = CBUUID(string: "3E2C1A00-3B42-4B7E-9C3E-000000000001")
    static let commandCharacteristicUUID = CBUUID(string: "3E2C1A00-3B42-4B7E-9C3E-000000000002")
    static let statusCharacteristicUUID = CBUUID(string: "3E2C1A00-3B42-4B7E-9C3E-000000000003")
    static let libraryCharacteristicUUID = CBUUID(string: "3E2C1A00-3B42-4B7E-9C3E-000000000004")
    /// Read-only: the device's own "http://ip:port", so a BLE-connected app can
    /// discover it and offer to switch to WiFi for bulk data (thumbnails, library).
    static let networkInfoCharacteristicUUID = CBUUID(string: "3E2C1A00-3B42-4B7E-9C3E-000000000005")
    /// Read-only + notify: which movie (if any) the device is currently
    /// re-encoding in its background transcode worker.
    static let transcodeStatusCharacteristicUUID = CBUUID(string: "3E2C1A00-3B42-4B7E-9C3E-000000000006")
    /// Read-only: the device's wire-protocol version - see supportedAPIVersion.
    static let apiVersionCharacteristicUUID = CBUUID(string: "3E2C1A00-3B42-4B7E-9C3E-000000000007")
    /// Write-only: joins the device to a new WiFi network (e.g. an iPhone's
    /// Personal Hotspot in a car, with no home network in range) - see
    /// encodeWifiCredentials and the device's wifi_provisioning.py.
    static let wifiProvisionCharacteristicUUID = CBUUID(string: "3E2C1A00-3B42-4B7E-9C3E-000000000008")

    /// The wire protocol version this app build was written against - see
    /// the device's protocol.py API_VERSION for what bumps this and why.
    /// Compared against the device's own reported version (decodeAPIVersion)
    /// to detect skew and prompt for an update instead of failing in some
    /// more confusing way further down.
    static let updateStatusCharacteristicUUID = CBUUID(string: "3E2C1A00-3B42-4B7E-9C3E-000000000009")

    static let supportedAPIVersion = 1

    enum Opcode: UInt8 {
        case play = 0x01
        case pause = 0x02
        case stop = 0x03
        case selectMovie = 0x04
        case seek = 0x05
        case shutdown = 0x06
    }

    /// 1-byte opcode, optionally followed by a little-endian UInt32 argument.
    static func encodeCommand(_ opcode: Opcode, argument: UInt32? = nil) -> Data {
        var data = Data([opcode.rawValue])
        if let argument {
            data.append(UInt8(argument & 0xFF))
            data.append(UInt8((argument >> 8) & 0xFF))
            data.append(UInt8((argument >> 16) & 0xFF))
            data.append(UInt8((argument >> 24) & 0xFF))
        }
        return data
    }

    /// 1 byte status + 2 bytes movie ID (0xFFFF = none) + 4 bytes position seconds, all little-endian.
    static func decodeStatus(_ data: Data) -> PlaybackState? {
        guard data.count >= 7, let status = PlaybackStatus(rawValue: data[data.startIndex]) else { return nil }
        let bytes = [UInt8](data)
        let movieIDRaw = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        let positionRaw = UInt32(bytes[3])
            | (UInt32(bytes[4]) << 8)
            | (UInt32(bytes[5]) << 16)
            | (UInt32(bytes[6]) << 24)
        let movieID = movieIDRaw == UInt16.max ? nil : Int(movieIDRaw)
        return PlaybackState(status: status, movieID: movieID, positionSeconds: Int(positionRaw))
    }

    /// UTF-8 text, one movie per line: "id|title|durationSeconds".
    static func decodeLibrary(_ data: Data) -> [Movie] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .compactMap { line -> Movie? in
                let parts = line.split(separator: "|")
                guard parts.count == 3,
                      let id = Int(parts[0]),
                      let duration = Int(parts[2]) else { return nil }
                return Movie(id: id, title: String(parts[1]), durationSeconds: duration)
            }
    }

    /// UTF-8 "http://ip:port" string.
    static func decodeNetworkURL(_ data: Data) -> URL? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: text)
    }

    /// 2 bytes little-endian movie ID (0xFFFF = nothing currently transcoding).
    static func decodeTranscodeStatus(_ data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        let raw = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        return raw == UInt16.max ? nil : Int(raw)
    }

    /// 1 byte - see supportedAPIVersion.
    static func decodeAPIVersion(_ data: Data) -> Int? {
        guard let byte = data.first else { return nil }
        return Int(byte)
    }

    /// 1 byte SSID length, followed by that many UTF-8 SSID bytes, followed
    /// by the UTF-8 password (the rest of the payload) - length-prefixed
    /// rather than a delimiter (e.g. the library characteristic's "|")
    /// deliberately, since a WiFi password can contain any printable
    /// character. Matches the device's own protocol.decode_wifi_credentials
    /// exactly - see its own comment. nil if the SSID is empty or longer
    /// than 255 UTF-8 bytes (the real-world WiFi SSID limit is 32 bytes,
    /// so this is generous headroom, not a meaningful constraint).
    static func encodeWifiCredentials(ssid: String, password: String) -> Data? {
        let ssidBytes = Data(ssid.utf8)
        guard !ssidBytes.isEmpty, ssidBytes.count <= 255 else { return nil }
        var data = Data([UInt8(ssidBytes.count)])
        data.append(ssidBytes)
        data.append(Data(password.utf8))
        return data
    }
}
