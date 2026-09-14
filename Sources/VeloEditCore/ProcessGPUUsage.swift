import Foundation
import IOKit

/// Driver-reported GPU execution time belonging only to this process.
/// AppUsage is optional: unsupported drivers must remain unavailable, not 0%.
struct ProcessGPUUsage {
    private var previous: [UInt64: UInt64]?
    private var previousTime: TimeInterval?

    mutating func sample(counters: [UInt64: UInt64]?, at time: TimeInterval) -> Double? {
        defer { previous = counters; previousTime = time }
        guard let counters, let previous, let previousTime,
              time > previousTime else { return nil }
        var nanoseconds = 0.0
        var sharedCount = 0
        for (id, current) in counters {
            guard let before = previous[id], current >= before else { continue }
            nanoseconds += Double(current - before)
            sharedCount += 1
        }
        guard sharedCount > 0 else { return nil }
        return min(100, max(0, nanoseconds / 1_000_000_000 / (time - previousTime) * 100))
    }

    static func readCounters() -> [UInt64: UInt64]? {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(accelerators) }
        let ownerPrefix = "pid \(ProcessInfo.processInfo.processIdentifier),"
        var counters: [UInt64: UInt64] = [:]
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                guard let owner = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                      owner.hasPrefix(ownerPrefix),
                      let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] else { continue }
                let values = usage.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }
                guard !values.isEmpty else { continue }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(client, &id) == KERN_SUCCESS else { continue }
                var total: UInt64 = 0
                for value in values {
                    let sum = total.addingReportingOverflow(value)
                    total = sum.overflow ? UInt64.max : sum.partialValue
                }
                counters[id] = total
            }
        }
        return counters.isEmpty ? nil : counters
    }
}
