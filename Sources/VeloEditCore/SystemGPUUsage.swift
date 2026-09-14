import Foundation
import IOKit

/// Whole-device utilization reported by the graphics driver. This includes
/// other applications and system services, unlike per-client GPU time.
enum SystemGPUUsage {
    static func percent(from statistics: [String: Any]) -> Double? {
        for key in ["Device Utilization %", "GPU Activity(%)"] {
            guard let number = statistics[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let value = number.doubleValue
            if value.isFinite, (0...100).contains(value) { return value }
        }
        return nil
    }

    static func readPercent() -> Double? {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(accelerators) }
        var values: [Double] = []
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            guard let statistics = IORegistryEntryCreateCFProperty(accelerator, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let value = percent(from: statistics) else { continue }
            values.append(value)
        }
        // Different GPUs have different capacities. Report the busiest device;
        // summing or averaging these percentages would invent a machine total.
        return values.max()
    }
}
