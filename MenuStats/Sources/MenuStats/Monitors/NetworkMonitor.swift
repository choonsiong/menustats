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
/// Counters are 32-bit and wrap, so deltas use wrapping subtraction.
final class NetworkMonitor {

    private struct Counters {
        var input: UInt32
        var output: UInt32
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

                if family == UInt8(AF_LINK), running, !isExcluded(name), let raw = entry.ifa_data {
                    let data = raw.assumingMemoryBound(to: if_data.self)
                    current[name] = Counters(input: UInt32(truncatingIfNeeded: data.pointee.ifi_ibytes),
                                             output: UInt32(truncatingIfNeeded: data.pointee.ifi_obytes))
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

            // Wrapping subtraction stays correct across the 4 GB counter roll.
            let inDelta = Double(counters.input &- old.input)
            let outDelta = Double(counters.output &- old.output)

            // Guard against interface resets producing absurd spikes.
            let limit = 8_000_000_000.0
            let down = inDelta < limit ? inDelta / elapsed : 0
            let up = outDelta < limit ? outDelta / elapsed : 0

            totalDown += down
            totalUp += up
            sessionIn += UInt64(max(0, min(inDelta, limit)))
            sessionOut += UInt64(max(0, min(outDelta, limit)))

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
