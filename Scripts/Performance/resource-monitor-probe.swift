// Compile with the actual monitor sources for independent, live verification:
// swiftc -O -parse-as-library Sources/VeloEditCore/{SystemResourceMonitor,ProcessGPUUsage,SystemGPUUsage,SystemMemoryUsage}.swift Scripts/Performance/resource-monitor-probe.swift -o /tmp/veloedit-resource-probe
// /tmp/veloedit-resource-probe 30
import Foundation

@main
struct ResourceMonitorProbe {
    static func main() async throws {
        let count = max(1, Int(CommandLine.arguments.dropFirst().first ?? "10") ?? 10)
        let monitor = SystemResourceMonitor()
        for index in 0..<count {
            let state = await monitor.snapshot()
            var record: [String: Any] = [
                "sample": index,
                "timestamp": Date().timeIntervalSince1970,
                "thermal": state.thermalLevel.rawValue,
                "lowPower": state.lowPowerMode,
                "cpu": state.systemCPUPercent as Any? ?? NSNull(),
                "gpu": state.systemGPUPercent as Any? ?? NSNull(),
                "processCPU": state.processCPUPercent as Any? ?? NSNull(),
                "processGPU": state.processGPUPercent as Any? ?? NSNull(),
                "processMemoryBytes": state.processMemoryBytes as Any? ?? NSNull()
            ]
            if let memory = state.systemMemory {
                record["memoryUsedBytes"] = memory.usedBytes
                record["memoryTotalBytes"] = memory.totalBytes
                record["memoryPercent"] = memory.percent
                record["memoryPressure"] = memory.pressure?.rawValue as Any? ?? NSNull()
            }
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
            if index + 1 < count { try await Task.sleep(for: .seconds(1)) }
        }
    }
}
