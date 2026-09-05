import Foundation
import IOKit

struct Sensor {
    let name: String
    let value: Double
}

struct TemperatureReading {
    var sensors: [Sensor] = []
    var fans: [Sensor] = []
    var cpu: Double?
    var gpu: Double?
    var source: String = ""

    var primary: Double? { cpu ?? gpu ?? sensors.map(\.value).max() }
    var available: Bool { primary != nil }
}

/// Apple Silicon exposes thermal sensors through the HID event system;
/// Intel Macs expose them through the SMC. Try both, keep whatever answers.
final class TemperatureMonitor {

    private lazy var hid = HIDSensors()
    private lazy var smc = SMC()

    private let intelKeys: [(String, String)] = [
        ("TCXC", "CPU PECI"),
        ("TC0D", "CPU Die"),
        ("TC0E", "CPU Core"),
        ("TC0F", "CPU Core"),
        ("TC0P", "CPU Proximity"),
        ("TG0D", "GPU Die"),
        ("TG0P", "GPU Proximity"),
        ("TA0P", "Ambient"),
        ("TM0P", "Memory"),
        ("Ts0P", "Palm Rest"),
        ("Ts1P", "Palm Rest"),
        ("TB0T", "Battery"),
        ("TW0P", "Wi-Fi"),
        ("TH0P", "Drive")
    ]

    /// Blocking; call this off the main thread.
    func read() -> TemperatureReading {
        var reading = TemperatureReading()

        let hidSensors = hid?.read() ?? []
        if !hidSensors.isEmpty {
            reading.source = "Apple Silicon sensors"
            reading.sensors = hidSensors.sorted { $0.value > $1.value }
            reading.cpu = average(hidSensors, matching: ["pACC", "eACC", "CPU"])
                ?? average(hidSensors, matching: ["SOC"])
            reading.gpu = average(hidSensors, matching: ["GPU"])
        } else if let smc = smc {
            reading.source = "SMC"
            var sensors: [Sensor] = []
            var seen = Set<String>()
            for (key, label) in intelKeys {
                guard let value = smc.temperature(key), value > 1 else { continue }
                let name = seen.contains(label) ? "\(label) (\(key))" : label
                seen.insert(label)
                sensors.append(Sensor(name: name, value: value))
            }
            reading.sensors = sensors
            reading.cpu = sensors.first { $0.name.hasPrefix("CPU") }?.value
            reading.gpu = sensors.first { $0.name.hasPrefix("GPU") }?.value
        }

        if let smc = smc {
            let count = smc.fanCount()
            for index in 0..<count {
                guard let rpm = smc.fanSpeed(index) else { continue }
                reading.fans.append(Sensor(name: count > 1 ? "Fan \(index + 1)" : "Fan", value: rpm))
            }
        }

        return reading
    }

    private func average(_ sensors: [Sensor], matching needles: [String]) -> Double? {
        let matches = sensors.filter { sensor in
            needles.contains { sensor.name.localizedCaseInsensitiveContains($0) }
        }
        guard !matches.isEmpty else { return nil }
        return matches.reduce(0) { $0 + $1.value } / Double(matches.count)
    }
}

// MARK: - Apple Silicon HID sensors

/// IOKit's HID event system exposes thermal sensors, but the functions are
/// not in the public headers, so they are resolved at runtime. If any symbol
/// is missing the whole thing degrades to "temperature unavailable".
private final class HIDSensors {

    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject?, CFDictionary?) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject?) -> Unmanaged<NSArray>?
    private typealias CopyProperty = @convention(c) (AnyObject?, CFString?) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias EventFloatValue = @convention(c) (AnyObject?, Int32) -> Double

    private let copyServices: CopyServices
    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let floatValue: EventFloatValue
    private let client: AnyObject

    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16
    private static let appleVendorPage = 0xff00
    private static let temperatureUsage = 5

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }

        guard let createSymbol = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchingSymbol = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let servicesSymbol = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let propertySymbol = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let eventSymbol = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatSymbol = dlsym(handle, "IOHIDEventGetFloatValue") else { return nil }

        let create = unsafeBitCast(createSymbol, to: CreateClient.self)
        let setMatching = unsafeBitCast(matchingSymbol, to: SetMatching.self)
        copyServices = unsafeBitCast(servicesSymbol, to: CopyServices.self)
        copyProperty = unsafeBitCast(propertySymbol, to: CopyProperty.self)
        copyEvent = unsafeBitCast(eventSymbol, to: CopyEvent.self)
        floatValue = unsafeBitCast(floatSymbol, to: EventFloatValue.self)

        guard let created = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        client = created

        let matching: [String: Any] = [
            "PrimaryUsagePage": Self.appleVendorPage,
            "PrimaryUsage": Self.temperatureUsage
        ]
        _ = setMatching(client, matching as CFDictionary)
    }

    func read() -> [Sensor] {
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }

        var sensors: [Sensor] = []
        for service in services {
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  !name.isEmpty else { continue }
            guard let event = copyEvent(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else { continue }

            let value = floatValue(event, Self.temperatureField)
            guard value.isFinite, value > 1, value < 150 else { continue }
            sensors.append(Sensor(name: name, value: value))
        }
        return sensors
    }
}
