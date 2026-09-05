import Foundation
import Darwin

struct CPUUsage {
    var user: Double = 0
    var system: Double = 0
    var nice: Double = 0
    var idle: Double = 100
    var perCore: [Double] = []

    var total: Double { max(0, min(100, user + system + nice)) }
}

/// Reads per-core tick counters from the Mach kernel and turns consecutive
/// samples into a percentage. The very first sample has no baseline, so it
/// reports zero.
final class CPUMonitor {

    private(set) var history: [Double] = []
    private var previous: [UInt32] = []
    private var last = CPUUsage()

    let coreCount = ProcessInfo.processInfo.processorCount
    let performanceCores = Int(Sysctl.integer("hw.perflevel0.logicalcpu") ?? 0)
    let efficiencyCores = Int(Sysctl.integer("hw.perflevel1.logicalcpu") ?? 0)

    var loadAverage: [Double] {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads
    }

    var brand: String {
        Sysctl.string("machdep.cpu.brand_string")
            ?? Sysctl.string("hw.model")
            ?? "Unknown CPU"
    }

    @discardableResult
    func read() -> CPUUsage {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(),
                                         processor_flavor_t(PROCESSOR_CPU_LOAD_INFO),
                                         &cpuCount,
                                         &info,
                                         &infoCount)
        guard result == KERN_SUCCESS, let info = info else { return last }

        defer {
            let address = vm_address_t(UInt(bitPattern: UnsafeMutableRawPointer(info)))
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, address, size)
        }

        let states = Int(CPU_STATE_MAX)
        let count = Int(cpuCount) * states
        var current = [UInt32](repeating: 0, count: count)
        for index in 0..<count {
            // Tick counters are unsigned but exposed as Int32.
            current[index] = UInt32(bitPattern: info[index])
        }

        guard previous.count == current.count else {
            previous = current
            return last
        }

        var totalUser = 0.0, totalSystem = 0.0, totalNice = 0.0, totalIdle = 0.0
        var perCore: [Double] = []
        perCore.reserveCapacity(Int(cpuCount))

        for core in 0..<Int(cpuCount) {
            let base = core * states
            let user = Double(current[base + Int(CPU_STATE_USER)] &- previous[base + Int(CPU_STATE_USER)])
            let system = Double(current[base + Int(CPU_STATE_SYSTEM)] &- previous[base + Int(CPU_STATE_SYSTEM)])
            let nice = Double(current[base + Int(CPU_STATE_NICE)] &- previous[base + Int(CPU_STATE_NICE)])
            let idle = Double(current[base + Int(CPU_STATE_IDLE)] &- previous[base + Int(CPU_STATE_IDLE)])

            let ticks = user + system + nice + idle
            perCore.append(ticks > 0 ? (user + system + nice) / ticks * 100 : 0)

            totalUser += user
            totalSystem += system
            totalNice += nice
            totalIdle += idle
        }

        previous = current

        let ticks = totalUser + totalSystem + totalNice + totalIdle
        guard ticks > 0 else { return last }

        var usage = CPUUsage()
        usage.user = totalUser / ticks * 100
        usage.system = totalSystem / ticks * 100
        usage.nice = totalNice / ticks * 100
        usage.idle = totalIdle / ticks * 100
        usage.perCore = perCore

        last = usage
        history.append(usage.total)
        if history.count > 60 { history.removeFirst(history.count - 60) }
        return usage
    }
}
