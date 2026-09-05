import Foundation
import IOKit

/// Minimal read-only client for Apple's System Management Controller.
/// Used for temperatures on Intel Macs and for fan speeds everywhere.
final class SMC {

    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    private struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    /// Layout must match the kernel's SMCParamStruct exactly (80 bytes).
    private struct ParamStruct {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let kernelIndex: UInt32 = 2
    private static let readKey: UInt8 = 5
    private static let getKeyInfo: UInt8 = 9

    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: KeyInfo] = [:]

    init?() {
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - Public reads

    /// Temperature in Celsius, or nil if the key is absent/implausible.
    func temperature(_ key: String) -> Double? {
        guard let value = value(for: key) else { return nil }
        guard value > -40, value < 150 else { return nil }
        return value
    }

    /// Number of fans reported by the controller.
    func fanCount() -> Int {
        guard let value = value(for: "FNum") else { return 0 }
        return max(0, min(8, Int(value)))
    }

    /// Current RPM of the given fan index.
    func fanSpeed(_ index: Int) -> Double? {
        guard let value = value(for: "F\(index)Ac"), value > 0 else { return nil }
        return value
    }

    // MARK: - Decoding

    private func value(for key: String) -> Double? {
        let code = Self.fourCharCode(key)
        guard let info = keyInformation(code), info.dataSize > 0 else { return nil }

        var input = ParamStruct()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.readKey

        guard let output = call(input), output.result == 0 else { return nil }

        let raw = withUnsafeBytes(of: output.bytes) { buffer in
            Array(buffer.prefix(Int(min(info.dataSize, 32))))
        }
        return Self.decode(raw, type: Self.typeString(info.dataType))
    }

    private static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int8(bitPattern: bytes[0])) + Double(bytes[1]) / 256.0
        case "sp87":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 128.0
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "fp88":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256.0
        case "ui8 ", "ui8\0":
            guard let first = bytes.first else { return nil }
            return Double(first)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            var value: UInt32 = 0
            for byte in bytes.prefix(4) { value = value << 8 | UInt32(byte) }
            return Double(value)
        default:
            return nil
        }
    }

    // MARK: - Plumbing

    private func keyInformation(_ code: UInt32) -> KeyInfo? {
        if let cached = keyInfoCache[code] { return cached }

        var input = ParamStruct()
        input.key = code
        input.data8 = Self.getKeyInfo

        guard let output = call(input), output.result == 0 else { return nil }
        keyInfoCache[code] = output.keyInfo
        return output.keyInfo
    }

    private func call(_ input: ParamStruct) -> ParamStruct? {
        var input = input
        var output = ParamStruct()
        let size = MemoryLayout<ParamStruct>.stride
        var outputSize = size

        let result = IOConnectCallStructMethod(connection, Self.kernelIndex,
                                              &input, size,
                                              &output, &outputSize)
        return result == kIOReturnSuccess ? output : nil
    }

    private static func fourCharCode(_ string: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in string.utf8.prefix(4) { code = code << 8 | UInt32(byte) }
        return code
    }

    private static func typeString(_ code: UInt32) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
