import Foundation
import Darwin

struct MemoryUsage {
    var total: Double = 0
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var cached: Double = 0
    var free: Double = 0
    var swapUsed: Double = 0
    var swapTotal: Double = 0
    var pressure: String = "Normal"

    var used: Double { app + wired + compressed }
    var percent: Double { total > 0 ? used / total * 100 : 0 }
}

/// Mirrors how Activity Monitor reports "Memory Used":
/// app memory + wired + compressed.
final class MemoryMonitor {

    private(set) var history: [Double] = []
    let total = Double(ProcessInfo.processInfo.physicalMemory)

    // Matches `struct xsw_usage` from <sys/sysctl.h>.
    private struct SwapUsage {
        var total: UInt64 = 0
        var available: UInt64 = 0
        var used: UInt64 = 0
        var pageSize: UInt32 = 0
        var encrypted: Int32 = 0
    }

    @discardableResult
    func read() -> MemoryUsage {
        var usage = MemoryUsage()
        usage.total = total

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), host_flavor_t(HOST_VM_INFO64), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return usage }

        var pageSize: vm_size_t = 0
        if host_page_size(mach_host_self(), &pageSize) != KERN_SUCCESS { pageSize = 4096 }
        let page = Double(pageSize)

        let purgeable = Double(stats.purgeable_count)
        usage.app = max(0, Double(stats.internal_page_count) - purgeable) * page
        usage.wired = Double(stats.wire_count) * page
        usage.compressed = Double(stats.compressor_page_count) * page
        usage.cached = (Double(stats.external_page_count) + purgeable) * page
        usage.free = Double(stats.free_count) * page

        var swap = SwapUsage()
        var swapSize = MemoryLayout<SwapUsage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            usage.swapUsed = Double(swap.used)
            usage.swapTotal = Double(swap.total)
        }

        switch Sysctl.integer("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 2: usage.pressure = "Warning"
        case 4: usage.pressure = "Critical"
        default: usage.pressure = "Normal"
        }

        history.append(usage.percent)
        if history.count > 60 { history.removeFirst(history.count - 60) }
        return usage
    }
}
