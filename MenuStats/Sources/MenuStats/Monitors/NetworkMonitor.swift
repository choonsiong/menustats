import Foundation
import Darwin

struct InterfaceInfo {
    let name: String
    var ipv4: String?
    var download: Double = 0
    var upload: Double = 0
}

struct NetworkUsage {
    var download: Double = 0          // bytes/second
    var upload: Double = 0
    var sessionIn: UInt64 = 0
    var sessionOut: UInt64 = 0
    var interfaces: [InterfaceInfo] = []
}

/// Reads per-interface byte counters and converts them to a rate.
final class NetworkMonitor {

    private struct Counters {
        var input: UInt64
        var output: UInt64
    }

    // Virtual / link-local interfaces that would double count real traffic.
    private let excluded = ["lo", "gif", "stf", "utun", "ipsec", "awdl", "llw",
                            "anpi", "ap", "bridge", "XHC", "vmenet", "p2p"]

    private var previous: [String: Counters] = [:]
    private var lastSample = Date()
    private var addresses: [String: String] = [:]

    private(set) var sessionIn: UInt64 = 0
    private(set) var sessionOut: UInt64 = 0
    private(set) var downloadHistory: [Double] = []
    private(set) var uploadHistory: [Double] = []
    private(set) var peakRate: Double = 0

    private func isExcluded(_ name: String) -> Bool {
        excluded.contains { name.hasPrefix($0) }
    }

    /// `ifmib` is the one source that gives an unentitled process true counts.
    /// `getifaddrs` and `NET_RT_IFLIST2` both round them and cut them to
    /// 32 bits, even in the 64-bit fields of `if_data64`.
    private func byteCounters(for name: String) -> Counters? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA,
                            Int32(if_nametoindex(name)), IFDATA_GENERAL]
        var data = ifmibdata()
        var size = MemoryLayout<ifmibdata>.size
        guard sysctl(&mib, UInt32(mib.count), &data, &size, nil, 0) == 0 else { return nil }
        return Counters(input: data.ifmd_data.ifi_ibytes, output: data.ifmd_data.ifi_obytes)
    }

    @discardableResult
    func read() -> NetworkUsage {
        var usage = NetworkUsage()

        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return usage }
        defer { freeifaddrs(list) }

        var current: [String: Counters] = [:]
        var order: [String] = []
        addresses.removeAll()

        var cursor = list
        while let node = cursor {
            let entry = node.pointee
            let name = String(cString: entry.ifa_name)
            let flags = Int32(bitPattern: entry.ifa_flags)
            let running = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0

            if let address = entry.ifa_addr {
                let family = address.pointee.sa_family

                if family == UInt8(AF_LINK), running, !isExcluded(name), let counters = byteCounters(for: name) {
                    current[name] = counters
                    order.append(name)
                } else if family == UInt8(AF_INET), addresses[name] == nil {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let length = socklen_t(address.pointee.sa_len)
                    if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        addresses[name] = String(cString: host)
                    }
                }
            }
            cursor = entry.ifa_next
        }

        let now = Date()
        let elapsed = max(0.25, now.timeIntervalSince(lastSample))
        lastSample = now

        var totalDown = 0.0
        var totalUp = 0.0
        var interfaces: [InterfaceInfo] = []

        for name in order {
            guard let counters = current[name] else { continue }
            guard let old = previous[name] else { continue }

            // A 64-bit counter never wraps, so going backwards means the
            // interface reset it. What moved that interval is unknowable.
            let inDelta = counters.input >= old.input ? counters.input - old.input : 0
            let outDelta = counters.output >= old.output ? counters.output - old.output : 0

            let down = Double(inDelta) / elapsed
            let up = Double(outDelta) / elapsed

            totalDown += down
            totalUp += up
            sessionIn += inDelta
            sessionOut += outDelta

            var info = InterfaceInfo(name: name)
            info.ipv4 = addresses[name]
            info.download = down
            info.upload = up
            interfaces.append(info)
        }

        previous = current

        usage.download = totalDown
        usage.upload = totalUp
        usage.sessionIn = sessionIn
        usage.sessionOut = sessionOut
        usage.interfaces = interfaces.sorted { ($0.download + $0.upload) > ($1.download + $1.upload) }

        downloadHistory.append(totalDown)
        uploadHistory.append(totalUp)
        if downloadHistory.count > 60 { downloadHistory.removeFirst(downloadHistory.count - 60) }
        if uploadHistory.count > 60 { uploadHistory.removeFirst(uploadHistory.count - 60) }
        peakRate = max(downloadHistory.max() ?? 0, uploadHistory.max() ?? 0)

        return usage
    }
}
