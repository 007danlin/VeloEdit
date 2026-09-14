import Foundation
import Darwin

public enum SystemMemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    public var title: String {
        switch self {
        case .normal: return "Давление памяти в норме"
        case .warning: return "Повышенное давление памяти"
        case .critical: return "Критическое давление памяти"
        }
    }
}

public struct SystemMemoryUsage: Sendable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public var pressure: SystemMemoryPressure?

    public var percent: Double { 100 * Double(usedBytes) / Double(max(1, totalBytes)) }

    static func usedBytes(internalPages: UInt32, purgeablePages: UInt32, wiredPages: UInt32,
                          compressorPages: UInt32, pageSize: UInt64, totalBytes: UInt64) -> UInt64 {
        // App memory + wired memory + the physical compressor. Reclaimable
        // file cache and purgeable pages are not application memory, and pages
        // stored in the compressor must not be counted at uncompressed size.
        let appPages = UInt64(internalPages) - UInt64(min(internalPages, purgeablePages))
        let pages = appPages + UInt64(wiredPages) + UInt64(compressorPages)
        let bytes = pages.multipliedReportingOverflow(by: pageSize)
        return min(totalBytes, bytes.overflow ? UInt64.max : bytes.partialValue)
    }

    static func capture() -> SystemMemoryUsage? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS, total > 0 else { return nil }
        var pressureValue: Int32 = 0
        var size = MemoryLayout.size(ofValue: pressureValue)
        let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureValue, &size, nil, 0)
        return SystemMemoryUsage(
            usedBytes: usedBytes(internalPages: info.internal_page_count, purgeablePages: info.purgeable_count,
                                 wiredPages: info.wire_count, compressorPages: info.compressor_page_count,
                                 pageSize: UInt64(pageSize), totalBytes: total),
            totalBytes: total,
            pressure: pressureResult == 0 ? SystemMemoryPressure(rawValue: Int(pressureValue)) : nil
        )
    }
}
