import Foundation
import Darwin

public enum SystemThermalLevel: Int, Sendable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }

    public var title: String {
        switch self {
        case .nominal: return "Нагрев в норме"
        case .fair: return "Mac нагревается"
        case .serious: return "Высокий нагрев"
        case .critical: return "Требуется охлаждение"
        }
    }
}

public enum ResourceWorkLimit: Int, Sendable {
    case unrestricted, reduced, cooling

    public var title: String {
        switch self {
        case .unrestricted: return "Автоматический контроль нагрузки"
        case .reduced: return "Обработка замедлена"
        case .cooling: return "Тяжёлая обработка ждёт охлаждения"
        }
    }
}

public struct SystemResourceSnapshot: Sendable {
    /// Percent of the whole machine, 0...100 (also for the process value).
    /// The first CPU measurement is unavailable until two samples exist.
    public var systemCPUPercent: Double?
    /// Busiest GPU's driver-reported utilization; nil on unsupported drivers.
    public var systemGPUPercent: Double? = nil
    public var systemMemory: SystemMemoryUsage? = nil
    public var processCPUPercent: Double?
    public var processGPUPercent: Double? = nil
    public var processMemoryBytes: UInt64?
    public var thermalLevel: SystemThermalLevel
    public var lowPowerMode: Bool
    public var workLimit: ResourceWorkLimit
    public var dutyCycle: Double
    public var reason: String
}

/// Immediate backoff and time-based recovery. Repeated callers cannot shorten
/// the cooldown: recovery requires ten continuous seconds below the low mark.
struct ResourceLoadPolicy {
    private(set) var limit: ResourceWorkLimit = .unrestricted
    private(set) var dutyCycle = 1.0
    private(set) var reason = "При высокой нагрузке VeloEdit оставляет ресурсы системе."
    private var recoverySince: TimeInterval?

    mutating func update(thermal: SystemThermalLevel, cpu: Double?, lowPower: Bool, now: TimeInterval) {
        let requestedDuty: Double
        let requestedReason: String
        if thermal == .critical {
            requestedDuty = 0
            requestedReason = "macOS сообщает о критическом нагреве. Обработка продолжится после охлаждения."
        } else if thermal == .serious {
            requestedDuty = 0.35
            requestedReason = "macOS сообщает о высоком нагреве — снижаю интенсивность обработки."
        } else if thermal == .fair {
            requestedDuty = 0.7
            requestedReason = "Mac нагревается — снижаю интенсивность обработки."
        } else if lowPower {
            requestedDuty = 0.65
            requestedReason = "Включён режим энергосбережения macOS."
        } else if let cpu, cpu >= 85 {
            requestedDuty = 0.65
            requestedReason = "CPU компьютера занят на 85% или больше — оставляю запас для других задач."
        } else {
            requestedDuty = 1
            requestedReason = "При высокой нагрузке VeloEdit оставляет ресурсы системе."
        }

        if requestedDuty < dutyCycle {
            dutyCycle = requestedDuty
            reason = requestedReason
            recoverySince = nil
        } else if requestedDuty == dutyCycle {
            reason = requestedReason
            recoverySince = nil
        } else {
            reason = dutyCycle == 0
                ? "Ожидаю десять секунд устойчивого охлаждения Mac перед продолжением обработки."
                : "Ожидаю устойчивого снижения нагрузки перед увеличением скорости обработки."
            // Cooling must reach fair or nominal. CPU pressure slows work but
            // never suspends it indefinitely; unknown CPU is not zero load.
            let canRecover = dutyCycle == 0
                ? thermal.rawValue <= SystemThermalLevel.fair.rawValue
                : requestedDuty < 1 || (cpu.map { $0 < 70 } ?? false)
            if canRecover {
                if recoverySince == nil { recoverySince = now }
                if now - (recoverySince ?? now) >= 10 {
                    dutyCycle = requestedDuty
                    reason = requestedReason
                    recoverySince = nil
                }
            } else {
                recoverySince = nil
            }
        }
        limit = dutyCycle == 0 ? .cooling : dutyCycle < 1 ? .reduced : .unrestricted
    }
}

struct SystemCPUTicks {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    func percent(since previous: SystemCPUTicks) -> Double? {
        // Mach's counters wrap independently; subtract before widening.
        let busy = UInt64(user &- previous.user) + UInt64(system &- previous.system) + UInt64(nice &- previous.nice)
        let total = busy + UInt64(idle &- previous.idle)
        return total > 0 ? min(100, 100 * Double(busy) / Double(total)) : nil
    }
}

public actor SystemResourceMonitor {
    public static let shared = SystemResourceMonitor()
    private var previousTicks: SystemCPUTicks?
    private var previousProcessCPU: Double?
    private var previousSampleTime: TimeInterval?
    private var systemCPU: Double?
    private var systemGPU: Double?
    private var systemMemory: SystemMemoryUsage?
    private var processCPU: Double?
    private var memory: UInt64?
    private var gpuUsage = ProcessGPUUsage()
    private var processGPU: Double?
    private var policy = ResourceLoadPolicy()

    public init() {}

    public func snapshot() async -> SystemResourceSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        if previousSampleTime == nil || now - (previousSampleTime ?? now) >= 1 {
            let ticks = Self.cpuTicks()
            systemCPU = ticks.flatMap { current in previousTicks.flatMap { current.percent(since: $0) } }
            previousTicks = ticks
            let usage = Self.processCPUTime()
            if let usage, let previousProcessCPU, let previousSampleTime, now > previousSampleTime {
                processCPU = min(100, max(0, (usage - previousProcessCPU) / (now - previousSampleTime)
                    / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) * 100))
            } else {
                processCPU = nil
            }
            processGPU = gpuUsage.sample(counters: ProcessGPUUsage.readCounters(), at: now)
            systemGPU = SystemGPUUsage.readPercent()
            systemMemory = SystemMemoryUsage.capture()
            previousProcessCPU = usage
            previousSampleTime = now
            memory = Self.residentMemory()
        }
        let thermal = SystemThermalLevel(ProcessInfo.processInfo.thermalState)
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        policy.update(thermal: thermal, cpu: systemCPU, lowPower: lowPower, now: now)
        return SystemResourceSnapshot(systemCPUPercent: systemCPU, systemGPUPercent: systemGPU, systemMemory: systemMemory,
                                      processCPUPercent: processCPU, processGPUPercent: processGPU,
                                      processMemoryBytes: memory, thermalLevel: thermal, lowPowerMode: lowPower,
                                      workLimit: policy.limit, dutyCycle: policy.dutyCycle, reason: policy.reason)
    }

    private static func processCPUTime() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func cpuTicks() -> SystemCPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return SystemCPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private static func residentMemory() -> UInt64? {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}

/// Cooperative pacing at safe work boundaries. Export keeps every frame and
/// timestamp. It yields wall-clock time, never lowers delivery quality. An
/// already submitted OS encoder/GPU operation runs to its next boundary.
struct ResourceWorkPacer {
    var readSnapshot: @Sendable () async -> SystemResourceSnapshot
    private var lastCheckpoint: TimeInterval?

    init(readSnapshot: @escaping @Sendable () async -> SystemResourceSnapshot = { await SystemResourceMonitor.shared.snapshot() }) {
        self.readSnapshot = readSnapshot
    }

    mutating func checkpoint() async throws {
        try Task.checkCancellation()
        let now = ProcessInfo.processInfo.systemUptime
        if let lastCheckpoint, now - lastCheckpoint < 0.25 { return }
        var state = await readSnapshot()
        while state.workLimit == .cooling {
            try await Task.sleep(for: .milliseconds(500))
            state = await readSnapshot()
        }
        try Task.checkCancellation()
        if let lastCheckpoint, state.dutyCycle < 1 {
            let workTime = min(0.5, max(0, now - lastCheckpoint))
            let delay = min(1, workTime * (1 / max(0.1, state.dutyCycle) - 1))
            try await Task.sleep(for: .seconds(delay))
        }
        lastCheckpoint = ProcessInfo.processInfo.systemUptime
    }
}
