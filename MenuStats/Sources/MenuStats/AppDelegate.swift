import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: Dependencies

    private let settings = Settings()
    private let cpuMonitor = CPUMonitor()
    private let memoryMonitor = MemoryMonitor()
    private let networkMonitor = NetworkMonitor()
    private let temperatureMonitor = TemperatureMonitor()
    private let backgroundQueue = DispatchQueue(label: "app.menustats.sensors", qos: .utility)

    // MARK: State

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var menuIsOpen = false
    private var temperatureBusy = false
    private var temperature = TemperatureReading()
    private var lastCPU = CPUUsage()
    private var lastMemory = MemoryUsage()
    private var lastNetwork = NetworkUsage()

    // MARK: Menu items

    private let systemItem = NSMenuItem()
    private let cpuGraphItem = NSMenuItem()
    private let cpuSummaryItem = NSMenuItem()
    private let cpuBreakdownItem = NSMenuItem()
    private let loadItem = NSMenuItem()
    private var cpuProcessItems: [NSMenuItem] = []

    private let memoryGraphItem = NSMenuItem()
    private let memorySummaryItem = NSMenuItem()
    private let memoryBreakdownItem = NSMenuItem()
    private let swapItem = NSMenuItem()
    private var memoryProcessItems: [NSMenuItem] = []

    private let networkGraphItem = NSMenuItem()
    private let networkRateItem = NSMenuItem()
    private let networkSessionItem = NSMenuItem()
    private var interfaceItems: [NSMenuItem] = []

    private let temperatureHeaderItem = NSMenuItem()
    private let temperatureSummaryItem = NSMenuItem()
    private let sensorsItem = NSMenuItem()
    private let sensorsMenu = NSMenu()
    private let fanItem = NSMenuItem()
    private let temperatureSeparator = NSMenuItem.separator()

    private let launchAtLoginItem = NSMenuItem()
    private var intervalItems: [NSMenuItem] = []
    private var modeItems: [NSMenuItem] = []
    private var displayItems: [NSMenuItem] = []
    private var unitItems: [NSMenuItem] = []

    private let cpuGraph = SparklineView(frame: NSRect(x: 0, y: 0, width: 300, height: 68))
    private let memoryGraph = SparklineView(frame: NSRect(x: 0, y: 0, width: 300, height: 68))
    private let networkGraph = SparklineView(frame: NSRect(x: 0, y: 0, width: 300, height: 68))

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading

        buildMenu()
        statusItem.menu = menu

        // Prime the counters so the first visible sample is a real delta.
        cpuMonitor.read()
        networkMonitor.read()

        startTimer()
        refreshTemperature()
        refresh()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: settings.interval,
                          target: self,
                          selector: #selector(refresh),
                          userInfo: nil,
                          repeats: true)
        // .common keeps sampling alive while the menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Refresh

    @objc private func refresh() {
        let cpu = cpuMonitor.read()
        let memory = memoryMonitor.read()
        let network = networkMonitor.read()

        lastCPU = cpu
        lastMemory = memory
        lastNetwork = network

        refreshTemperature()
        updateStatusBar(cpu: cpu, memory: memory, network: network)

        if menuIsOpen {
            updateMenu(cpu: cpu, memory: memory, network: network)
        }
    }

    /// Repaint from the most recent samples, without disturbing the sampling
    /// cadence (a resample here would push a short, misleading delta).
    private func redraw() {
        updateStatusBar(cpu: lastCPU, memory: lastMemory, network: lastNetwork)
        if menuIsOpen {
            updateMenu(cpu: lastCPU, memory: lastMemory, network: lastNetwork)
        }
    }

    private func refreshTemperature() {
        guard settings.showTemperature || settings.iconOnly || menuIsOpen, !temperatureBusy else { return }
        temperatureBusy = true
        backgroundQueue.async { [weak self] in
            guard let self = self else { return }
            let reading = self.temperatureMonitor.read()
            DispatchQueue.main.async {
                self.temperature = reading
                self.temperatureBusy = false
            }
        }
    }

    // MARK: - Menu bar

    private func updateStatusBar(cpu: CPUUsage, memory: MemoryUsage, network: NetworkUsage) {
        guard let button = statusItem.button else { return }

        var segments: [String] = []
        if !settings.iconOnly {
            if settings.showCPU {
                segments.append("CPU " + Fmt.percent(cpu.total))
            }
            if settings.showMemory {
                segments.append("MEM " + Fmt.percent(memory.percent))
            }
            if settings.showNetwork {
                let down = Fmt.rate(network.download, bits: settings.bits, short: true)
                let up = Fmt.rate(network.upload, bits: settings.bits, short: true)
                segments.append("↓\(down) ↑\(up)")
            }
            if settings.showTemperature, let value = temperature.primary {
                segments.append(Fmt.temperature(value, fahrenheit: settings.fahrenheit))
            }
        }

        if segments.isEmpty {
            // Icon only. Also the fallback if every text segment is switched off,
            // so the item never collapses to zero width and become unclickable.
            button.attributedTitle = NSAttributedString(string: "")
            button.image = statusIcon
            button.imagePosition = .imageOnly
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = NSAttributedString(
                string: segments.joined(separator: "  "),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular),
                    .foregroundColor: NSColor.labelColor
                ])
        }

        var lines = [
            "CPU  \(Fmt.percent(cpu.total, decimals: 1))",
            "Memory  \(Fmt.bytes(memory.used)) of \(Fmt.bytes(memory.total))  (\(Fmt.percent(memory.percent)))",
            "Network  ↓ \(Fmt.rate(network.download, bits: settings.bits, short: false))"
                + "  ↑ \(Fmt.rate(network.upload, bits: settings.bits, short: false))"
        ]
        if let value = temperature.primary {
            lines.append("Temperature  \(Fmt.temperature(value, fahrenheit: settings.fahrenheit))")
        }
        button.toolTip = lines.joined(separator: "\n")
    }

    /// Template image so macOS tints it correctly in light, dark, and while
    /// the menu is open. Falls back to a hand-drawn bar chart if the symbol
    /// isn't available on this OS version.
    private lazy var statusIcon: NSImage = {
        for name in ["gauge.medium", "gauge", "speedometer"] {
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "MenuStats") else { continue }
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let image = symbol.withSymbolConfiguration(configuration) ?? symbol
            image.isTemplate = true
            return image
        }

        let image = NSImage(size: NSSize(width: 17, height: 13), flipped: false) { rect in
            NSColor.black.setFill()
            let heights: [CGFloat] = [0.45, 1.0, 0.7]
            for (index, fraction) in heights.enumerated() {
                let bar = NSRect(x: rect.minX + CGFloat(index) * 6 + 1,
                                 y: rect.minY,
                                 width: 4,
                                 height: rect.height * fraction)
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    // MARK: - Menu construction

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        var machine = Sysctl.string("hw.model") ?? "Mac"
        if let name = Sysctl.string("machdep.cpu.brand_string") { machine = name }
        var cores = "\(cpuMonitor.coreCount) cores"
        if cpuMonitor.performanceCores > 0 && cpuMonitor.efficiencyCores > 0 {
            cores = "\(cpuMonitor.coreCount) cores (\(cpuMonitor.performanceCores)P + \(cpuMonitor.efficiencyCores)E)"
        }
        configure(systemItem, label: machine, value: cores)
        menu.addItem(systemItem)
        menu.addItem(.separator())

        // CPU
        menu.addItem(header("CPU"))
        cpuGraph.caption = "CPU"
        cpuGraph.maxValue = 100
        cpuGraph.series = [SparklineView.Series(values: [], color: .systemBlue)]
        cpuGraphItem.view = cpuGraph
        menu.addItem(cpuGraphItem)
        menu.addItem(cpuSummaryItem)
        menu.addItem(cpuBreakdownItem)
        menu.addItem(loadItem)
        cpuProcessItems = (0..<5).map { _ in makeInfoItem() }
        cpuProcessItems.forEach { menu.addItem($0) }
        menu.addItem(.separator())

        // Memory
        menu.addItem(header("MEMORY"))
        memoryGraph.caption = "Memory used"
        memoryGraph.maxValue = 100
        memoryGraph.series = [SparklineView.Series(values: [], color: .systemGreen)]
        memoryGraphItem.view = memoryGraph
        menu.addItem(memoryGraphItem)
        menu.addItem(memorySummaryItem)
        menu.addItem(memoryBreakdownItem)
        menu.addItem(swapItem)
        memoryProcessItems = (0..<3).map { _ in makeInfoItem() }
        memoryProcessItems.forEach { menu.addItem($0) }
        menu.addItem(.separator())

        // Network
        menu.addItem(header("NETWORK"))
        networkGraph.caption = "Throughput"
        networkGraph.series = [
            SparklineView.Series(values: [], color: .systemTeal),
            SparklineView.Series(values: [], color: .systemOrange)
        ]
        networkGraphItem.view = networkGraph
        menu.addItem(networkGraphItem)
        menu.addItem(networkRateItem)
        menu.addItem(networkSessionItem)
        interfaceItems = (0..<3).map { _ in makeInfoItem() }
        interfaceItems.forEach { menu.addItem($0) }
        menu.addItem(temperatureSeparator)

        // Temperature
        temperatureHeaderItem.attributedTitle = headerTitle("TEMPERATURE")
        temperatureHeaderItem.isEnabled = false
        menu.addItem(temperatureHeaderItem)
        menu.addItem(temperatureSummaryItem)
        sensorsItem.title = "All sensors"
        sensorsItem.isEnabled = true
        sensorsItem.submenu = sensorsMenu
        sensorsMenu.autoenablesItems = false
        menu.addItem(sensorsItem)
        menu.addItem(fanItem)
        menu.addItem(.separator())

        menu.addItem(buildSettingsItem())

        let quit = NSMenuItem(title: "Quit MenuStats", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        [cpuSummaryItem, cpuBreakdownItem, loadItem,
         memorySummaryItem, memoryBreakdownItem, swapItem,
         networkRateItem, networkSessionItem,
         temperatureSummaryItem, fanItem, systemItem].forEach { $0.isEnabled = false }
    }

    private func buildSettingsItem() -> NSMenuItem {
        let root = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        root.isEnabled = true
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(header("MENU BAR"))
        let modes: [(String, Int)] = [("Icon only", 1), ("Show stats as text", 2)]
        for (title, tag) in modes {
            let item = NSMenuItem(title: title, action: #selector(setMenuBarMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.isEnabled = true
            modeItems.append(item)
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        submenu.addItem(header("TEXT SEGMENTS"))
        let displays: [(String, Int)] = [("CPU", 1), ("Memory", 2), ("Network", 3), ("Temperature", 4)]
        for (title, tag) in displays {
            let item = NSMenuItem(title: title, action: #selector(toggleDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.isEnabled = true
            displayItems.append(item)
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        submenu.addItem(header("UPDATE INTERVAL"))
        for seconds in [1, 2, 5, 10] {
            let item = NSMenuItem(title: seconds == 1 ? "1 second" : "\(seconds) seconds",
                                  action: #selector(setInterval(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.isEnabled = true
            intervalItems.append(item)
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        submenu.addItem(header("UNITS"))
        let units: [(String, Int)] = [("Network in bits (Mbps)", 1), ("Temperature in °F", 2)]
        for (title, tag) in units {
            let item = NSMenuItem(title: title, action: #selector(toggleUnit(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.isEnabled = true
            unitItems.append(item)
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        launchAtLoginItem.title = "Launch at Login"
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin(_:))
        launchAtLoginItem.target = self
        launchAtLoginItem.isEnabled = true
        if #available(macOS 13.0, *) {} else { launchAtLoginItem.isHidden = true }
        submenu.addItem(launchAtLoginItem)

        root.submenu = submenu
        return root
    }

    // MARK: - Menu updates

    private func updateMenu(cpu: CPUUsage, memory: MemoryUsage, network: NetworkUsage) {
        // CPU
        cpuGraph.series = [SparklineView.Series(values: cpuMonitor.history, color: .systemBlue)]
        cpuGraph.readout = Fmt.percent(cpu.total, decimals: 1)
        configure(cpuSummaryItem, label: "Total", value: Fmt.percent(cpu.total, decimals: 1))
        configure(cpuBreakdownItem,
                  label: "User / System / Idle",
                  value: "\(Fmt.percent(cpu.user, decimals: 1)) · \(Fmt.percent(cpu.system, decimals: 1)) · \(Fmt.percent(cpu.idle, decimals: 1))")
        let load = cpuMonitor.loadAverage
        configure(loadItem,
                  label: "Load average",
                  value: String(format: "%.2f  %.2f  %.2f", load[0], load[1], load[2]))

        // Memory
        memoryGraph.series = [SparklineView.Series(values: memoryMonitor.history, color: .systemGreen)]
        memoryGraph.readout = Fmt.percent(memory.percent, decimals: 1)
        configure(memorySummaryItem,
                  label: "Used",
                  value: "\(Fmt.bytes(memory.used)) of \(Fmt.bytes(memory.total))  (\(Fmt.percent(memory.percent)))")
        configure(memoryBreakdownItem,
                  label: "App / Wired / Compressed",
                  value: "\(Fmt.bytes(memory.app)) · \(Fmt.bytes(memory.wired)) · \(Fmt.bytes(memory.compressed))")
        configure(swapItem,
                  label: "Swap · Pressure",
                  value: "\(Fmt.bytes(memory.swapUsed)) of \(Fmt.bytes(memory.swapTotal)) · \(memory.pressure)")

        // Network
        let ceiling = max(networkMonitor.peakRate, 131_072)
        networkGraph.maxValue = ceiling
        networkGraph.series = [
            SparklineView.Series(values: networkMonitor.downloadHistory, color: .systemTeal),
            SparklineView.Series(values: networkMonitor.uploadHistory, color: .systemOrange)
        ]
        networkGraph.readout = "peak " + Fmt.rate(ceiling, bits: settings.bits, short: false)
        configure(networkRateItem,
                  label: "Down / Up",
                  value: "↓ \(Fmt.rate(network.download, bits: settings.bits, short: false))   ↑ \(Fmt.rate(network.upload, bits: settings.bits, short: false))")
        configure(networkSessionItem,
                  label: "Since launch",
                  value: "↓ \(Fmt.bytes(Double(network.sessionIn)))   ↑ \(Fmt.bytes(Double(network.sessionOut)))")

        for (index, item) in interfaceItems.enumerated() {
            if index < network.interfaces.count {
                let interface = network.interfaces[index]
                let address = interface.ipv4 ?? "no IPv4"
                item.isHidden = false
                configure(item,
                          label: interface.name,
                          value: "\(address)   ↓ \(Fmt.rate(interface.download, bits: settings.bits, short: true)) ↑ \(Fmt.rate(interface.upload, bits: settings.bits, short: true))",
                          indented: true)
            } else {
                item.isHidden = true
            }
        }

        updateTemperatureSection()
        updateSettingsState()
    }

    private func updateTemperatureSection() {
        let hasSensors = !temperature.sensors.isEmpty || !temperature.fans.isEmpty
        temperatureHeaderItem.isHidden = !hasSensors
        temperatureSummaryItem.isHidden = !hasSensors
        sensorsItem.isHidden = temperature.sensors.isEmpty
        fanItem.isHidden = temperature.fans.isEmpty
        temperatureSeparator.isHidden = !hasSensors

        if !hasSensors { return }

        var parts: [String] = []
        if let cpu = temperature.cpu { parts.append("CPU " + Fmt.temperature(cpu, fahrenheit: settings.fahrenheit)) }
        if let gpu = temperature.gpu { parts.append("GPU " + Fmt.temperature(gpu, fahrenheit: settings.fahrenheit)) }
        if parts.isEmpty, let value = temperature.primary {
            parts.append("Hottest " + Fmt.temperature(value, fahrenheit: settings.fahrenheit))
        }
        configure(temperatureSummaryItem, label: temperature.source, value: parts.joined(separator: "   "))

        sensorsMenu.removeAllItems()
        for sensor in temperature.sensors.prefix(20) {
            let item = makeInfoItem()
            configure(item,
                      label: sensor.name,
                      value: Fmt.temperature(sensor.value, fahrenheit: settings.fahrenheit))
            sensorsMenu.addItem(item)
        }

        let fans = temperature.fans
            .map { "\($0.name): \(Int($0.value)) rpm" }
            .joined(separator: "   ")
        configure(fanItem, label: "Fans", value: fans)
    }

    private func updateSettingsState() {
        for item in modeItems {
            item.state = (item.tag == 1) == settings.iconOnly ? .on : .off
        }
        let flags = [settings.showCPU, settings.showMemory, settings.showNetwork, settings.showTemperature]
        for item in displayItems where item.tag >= 1 && item.tag <= 4 {
            item.state = flags[item.tag - 1] ? .on : .off
            item.isEnabled = !settings.iconOnly
        }
        for item in intervalItems {
            item.state = Int(settings.interval.rounded()) == item.tag ? .on : .off
        }
        for item in unitItems {
            item.state = (item.tag == 1 ? settings.bits : settings.fahrenheit) ? .on : .off
        }
        if #available(macOS 13.0, *) {
            launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    private func refreshProcesses() {
        backgroundQueue.async { [weak self] in
            let cpu = ProcessMonitor.topCPU(limit: 5)
            let memory = ProcessMonitor.topMemory(limit: 3)
            DispatchQueue.main.async {
                guard let self = self else { return }
                for (index, item) in self.cpuProcessItems.enumerated() {
                    if index < cpu.count {
                        item.isHidden = false
                        self.configure(item,
                                       label: cpu[index].name,
                                       value: String(format: "%.1f%%", cpu[index].value),
                                       indented: true)
                    } else {
                        item.isHidden = true
                    }
                }
                for (index, item) in self.memoryProcessItems.enumerated() {
                    if index < memory.count {
                        item.isHidden = false
                        self.configure(item,
                                       label: memory[index].name,
                                       value: Fmt.bytes(memory[index].value),
                                       indented: true)
                    } else {
                        item.isHidden = true
                    }
                }
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuIsOpen = true
        refreshProcesses()
        refreshTemperature()
        updateMenu(cpu: lastCPU, memory: lastMemory, network: lastNetwork)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuIsOpen = false
    }

    // MARK: - Actions

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: settings.showCPU.toggle()
        case 2: settings.showMemory.toggle()
        case 3: settings.showNetwork.toggle()
        case 4: settings.showTemperature.toggle()
        default: break
        }
        updateSettingsState()
        redraw()
    }

    @objc private func setMenuBarMode(_ sender: NSMenuItem) {
        settings.iconOnly = (sender.tag == 1)
        updateSettingsState()
        redraw()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        settings.interval = Double(sender.tag)
        startTimer()
        updateSettingsState()
    }

    @objc private func toggleUnit(_ sender: NSMenuItem) {
        if sender.tag == 1 { settings.bits.toggle() } else { settings.fahrenheit.toggle() }
        updateSettingsState()
        redraw()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        updateSettingsState()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Item helpers

    private func makeInfoItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func headerTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.6
        ])
    }

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = headerTitle(text)
        item.isEnabled = false
        return item
    }

    private func configure(_ item: NSMenuItem, label: String, value: String, indented: Bool = false) {
        let title = NSMutableAttributedString(
            string: (indented ? "    " : "") + label + "   ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
        title.append(NSAttributedString(
            string: value,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]))
        item.attributedTitle = title
    }
}
