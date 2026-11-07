import Foundation

/// A phone or emulator `adb` can see, as `adb devices -l` reports it.
struct AndroidDevice: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case device
        case offline
        case unauthorized
        case other(String)

        var wire: String {
            switch self {
            case .device:       return "device"
            case .offline:      return "offline"
            case .unauthorized: return "unauthorized"
            case .other(let s): return s
            }
        }
    }

    let serial: String
    let state: State
    /// `ro.product.model` with spaces written as underscores, as adb prints it.
    let model: String?

    /// A device the user can recognise: the model with spaces restored,
    /// or the serial when adb didn't say.
    var name: String {
        guard let model, !model.isEmpty else { return serial }
        return model.replacingOccurrences(of: "_", with: " ")
    }

    /// Only an authorised, online device can be streamed.
    var isReady: Bool { state == .device }
}

/// Parser for `adb devices -l` plus the JSON `/android.json` serves.
enum AdbDeviceList {
    static func parse(_ output: String) -> [AndroidDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Daemon start-up chatter ("* daemon ...") and the header.
            guard !line.isEmpty, !line.hasPrefix("*"), !line.hasPrefix("List of devices") else { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { return nil }
            let state: AndroidDevice.State
            switch fields[1] {
            case "device":       state = .device
            case "offline":      state = .offline
            case "unauthorized": state = .unauthorized
            default:             state = .other(fields[1])
            }
            let model = fields.dropFirst(2)
                .first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst("model:".count)) }
            return AndroidDevice(serial: fields[0], state: state, model: model)
        }
    }

    static func json(_ devices: [AndroidDevice], unavailable: String? = nil) -> String {
        var dict: [String: Any] = [
            "connected": devices.map { device -> [String: Any] in
                var entry: [String: Any] = [
                    "serial": device.serial,
                    "name": device.name,
                    "state": device.state.wire,
                    "ready": device.isReady,
                ]
                if let model = device.model { entry["model"] = model }
                return entry
            }
        ]
        if let unavailable { dict["unavailable"] = unavailable }
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
