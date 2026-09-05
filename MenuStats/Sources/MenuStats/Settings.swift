import Foundation

final class Settings {
    private let defaults = UserDefaults.standard

    private enum Key {
        static let interval = "updateInterval"
        static let showCPU = "showCPU"
        static let showMemory = "showMemory"
        static let showNetwork = "showNetwork"
        static let showTemperature = "showTemperature"
        static let fahrenheit = "useFahrenheit"
        static let bits = "networkInBits"
        static let iconOnly = "iconOnly"
    }

    init() {
        defaults.register(defaults: [
            Key.interval: 2.0,
            Key.iconOnly: true,
            Key.showCPU: true,
            Key.showMemory: true,
            Key.showNetwork: true,
            Key.showTemperature: true,
            Key.fahrenheit: false,
            Key.bits: false
        ])
    }

    var interval: Double {
        get {
            let value = defaults.double(forKey: Key.interval)
            return value > 0 ? value : 2.0
        }
        set { defaults.set(newValue, forKey: Key.interval) }
    }

    /// When true the menu bar shows a single icon and all detail lives in the menu.
    var iconOnly: Bool {
        get { defaults.bool(forKey: Key.iconOnly) }
        set { defaults.set(newValue, forKey: Key.iconOnly) }
    }

    var showCPU: Bool {
        get { defaults.bool(forKey: Key.showCPU) }
        set { defaults.set(newValue, forKey: Key.showCPU) }
    }

    var showMemory: Bool {
        get { defaults.bool(forKey: Key.showMemory) }
        set { defaults.set(newValue, forKey: Key.showMemory) }
    }

    var showNetwork: Bool {
        get { defaults.bool(forKey: Key.showNetwork) }
        set { defaults.set(newValue, forKey: Key.showNetwork) }
    }

    var showTemperature: Bool {
        get { defaults.bool(forKey: Key.showTemperature) }
        set { defaults.set(newValue, forKey: Key.showTemperature) }
    }

    var fahrenheit: Bool {
        get { defaults.bool(forKey: Key.fahrenheit) }
        set { defaults.set(newValue, forKey: Key.fahrenheit) }
    }

    var bits: Bool {
        get { defaults.bool(forKey: Key.bits) }
        set { defaults.set(newValue, forKey: Key.bits) }
    }
}
