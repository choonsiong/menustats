import Foundation

struct ProcessEntry {
    let name: String
    let value: Double   // percent for CPU, bytes for memory
}

/// Shells out to `ps` only while the menu is open, so it costs nothing
/// during normal background sampling.
enum ProcessMonitor {

    static func topCPU(limit: Int = 5) -> [ProcessEntry] {
        run(arguments: ["-Aceo", "pcpu=,comm=", "-r"], limit: limit) { $0 }
    }

    static func topMemory(limit: Int = 5) -> [ProcessEntry] {
        run(arguments: ["-Aceo", "rss=,comm=", "-m"], limit: limit) { $0 * 1024 }
    }

    private static func run(arguments: [String],
                            limit: Int,
                            transform: (Double) -> Double) -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var entries: [ProcessEntry] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let split = trimmed.firstIndex(of: " ") else { continue }
            guard let number = Double(trimmed[trimmed.startIndex..<split]) else { continue }

            let name = trimmed[split...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            entries.append(ProcessEntry(name: name, value: transform(number)))
            if entries.count == limit { break }
        }
        return entries
    }
}
