import Foundation
import Testing
@testable import VeloEditCore

@Test func resourcePolicyBacksOffForHeatLoadAndLowPower() {
    var normal = ResourceLoadPolicy()
    normal.update(thermal: .nominal, cpu: 50, lowPower: false, now: 0)
    #expect(normal.limit == .unrestricted)
    for (thermal, cpu, lowPower, duty) in [
        (SystemThermalLevel.nominal, 90.0, false, 0.65),
        (.nominal, 20.0, true, 0.65),
        (.fair, 20.0, false, 0.7),
        (.serious, 20.0, false, 0.35),
        (.critical, 20.0, false, 0.0)
    ] {
        var policy = normal
        policy.update(thermal: thermal, cpu: cpu, lowPower: lowPower, now: 1)
        #expect(policy.dutyCycle == duty)
        #expect(policy.limit == (duty == 0 ? .cooling : .reduced))
    }
}

@Test func resourceCoolingRequiresContinuousRecoveryAndCannotBeRushedByCallers() {
    var policy = ResourceLoadPolicy()
    policy.update(thermal: .critical, cpu: 90, lowPower: false, now: 0)
    policy.update(thermal: .serious, cpu: 20, lowPower: false, now: 20)
    #expect(policy.limit == .cooling)
    for _ in 0..<100 {
        policy.update(thermal: .nominal, cpu: 20, lowPower: false, now: 21)
    }
    #expect(policy.limit == .cooling)
    policy.update(thermal: .nominal, cpu: 20, lowPower: false, now: 30.9)
    #expect(policy.limit == .cooling)
    policy.update(thermal: .critical, cpu: 20, lowPower: false, now: 31)
    policy.update(thermal: .fair, cpu: 20, lowPower: false, now: 32)
    policy.update(thermal: .fair, cpu: 20, lowPower: false, now: 42)
    #expect(policy.limit == .reduced)
    #expect(policy.dutyCycle == 0.7)
    policy.update(thermal: .nominal, cpu: 20, lowPower: false, now: 43)
    policy.update(thermal: .nominal, cpu: 20, lowPower: false, now: 53)
    #expect(policy.limit == .unrestricted)
}

@Test func resourceCPULoadHasSeparateRecoveryThresholdAndUnknownIsNotIdle() {
    var policy = ResourceLoadPolicy()
    policy.update(thermal: .nominal, cpu: 90, lowPower: false, now: 0)
    policy.update(thermal: .nominal, cpu: 75, lowPower: false, now: 20)
    policy.update(thermal: .nominal, cpu: nil, lowPower: false, now: 40)
    #expect(policy.limit == .reduced)
    policy.update(thermal: .nominal, cpu: 60, lowPower: false, now: 41)
    policy.update(thermal: .nominal, cpu: 60, lowPower: false, now: 50.9)
    #expect(policy.limit == .reduced)
    policy.update(thermal: .nominal, cpu: 60, lowPower: false, now: 51)
    #expect(policy.limit == .unrestricted)
}

@Test func resourceCPUPercentUsesDeltasAndHandlesCounterWrap() {
    let before = SystemCPUTicks(user: 100, system: 100, idle: 100, nice: 100)
    let after = SystemCPUTicks(user: 130, system: 110, idle: 150, nice: 110)
    #expect(after.percent(since: before) == 50)
    #expect(before.percent(since: before) == nil)
    let wrapBefore = SystemCPUTicks(user: UInt32.max - 4, system: 0, idle: 0, nice: 0)
    let wrapAfter = SystemCPUTicks(user: 5, system: 0, idle: 10, nice: 0)
    #expect(wrapAfter.percent(since: wrapBefore) == 50)
}

@Test func resourceMonitorReadsActualMachineWithoutInventingInitialCPU() async throws {
    let monitor = SystemResourceMonitor()
    let initial = await monitor.snapshot()
    #expect(initial.systemCPUPercent == nil)
    #expect(initial.processCPUPercent == nil)
    #expect((initial.processMemoryBytes ?? 0) > 0)
    let memory = try #require(initial.systemMemory)
    #expect(memory.totalBytes == ProcessInfo.processInfo.physicalMemory)
    #expect(memory.usedBytes > 0 && memory.usedBytes <= memory.totalBytes)
    // An unsupported GPU driver is allowed to return nil; never fabricate zero.
    if let gpu = initial.systemGPUPercent { #expect((0...100).contains(gpu)) }
    try await Task.sleep(for: .milliseconds(1050))
    let measured = await monitor.snapshot()
    #expect(try #require(measured.systemCPUPercent) >= 0)
    #expect(try #require(measured.systemCPUPercent) <= 100)
    #expect(try #require(measured.processCPUPercent) >= 0)
    #expect(try #require(measured.processCPUPercent) <= 100)
    let cached = await monitor.snapshot()
    #expect(cached.systemCPUPercent == measured.systemCPUPercent)
    #expect(cached.systemGPUPercent == measured.systemGPUPercent)
    #expect(cached.systemMemory?.usedBytes == measured.systemMemory?.usedBytes)
}

@Test func resourceCoolingWaitRemainsCancellable() async throws {
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let task = Task {
        var pacer = ResourceWorkPacer(readSnapshot: {
            continuation.yield(())
            return resourceTestSnapshot(cooling: true)
        })
        try await pacer.checkpoint()
    }
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    task.cancel()
    do {
        try await task.value
        Issue.record("Cooling must propagate cancellation")
    } catch is CancellationError {
        // Expected: sleep exits immediately, without waiting for the machine.
    }
    continuation.finish()
}

@Test func resourceCoolingWaitResumesAtSameWorkBoundary() async throws {
    actor Observations {
        var count = 0
        func next() -> SystemResourceSnapshot {
            count += 1
            return resourceTestSnapshot(cooling: count == 1)
        }
    }
    let observations = Observations()
    var pacer = ResourceWorkPacer(readSnapshot: { await observations.next() })
    try await pacer.checkpoint()
    #expect(await observations.count == 2)
}

private func resourceTestSnapshot(cooling: Bool) -> SystemResourceSnapshot {
    SystemResourceSnapshot(systemCPUPercent: 20, processCPUPercent: 5, processMemoryBytes: 1_000,
                           thermalLevel: cooling ? .critical : .nominal, lowPowerMode: false,
                           workLimit: cooling ? .cooling : .unrestricted, dutyCycle: cooling ? 0 : 1,
                           reason: "Test")
}

@Test func processGPULoadUsesElapsedTimeAndKeepsUnavailableDistinctFromIdle() {
    var meter = ProcessGPUUsage()
    #expect(meter.sample(counters: nil, at: 0) == nil)
    #expect(meter.sample(counters: [1: 100_000_000], at: 1) == nil)
    #expect(meter.sample(counters: [1: 600_000_000], at: 3) == 25)
    #expect(meter.sample(counters: [1: 600_000_000], at: 4) == 0)
    #expect(meter.sample(counters: nil, at: 5) == nil)
    #expect(meter.sample(counters: [1: 900_000_000], at: 6) == nil)
}

@Test func processGPULoadHandlesClientChurnCounterResetsAndParallelWork() {
    var meter = ProcessGPUUsage()
    #expect(meter.sample(counters: [1: 900_000_000, 2: 100_000_000], at: 0) == nil)
    // A departed client cannot subtract time; a new client's lifetime is not this interval.
    #expect(meter.sample(counters: [2: 300_000_000, 3: 9_000_000_000], at: 1) == 20)
    #expect(meter.sample(counters: [2: 100, 3: 10], at: 2) == nil)
    #expect(meter.sample(counters: [2: 2_000_000_100, 3: 10], at: 3) == 100)
    #expect(meter.sample(counters: [2: 2_000_000_100, 3: 10], at: 3) == nil)
}

@Test func systemGPUReadsOnlyActualDriverPercentages() {
    #expect(SystemGPUUsage.percent(from: [:]) == nil)
    #expect(SystemGPUUsage.percent(from: ["Device Utilization %": 0]) == 0)
    #expect(SystemGPUUsage.percent(from: ["Device Utilization %": 73, "Renderer Utilization %": 71]) == 73)
    #expect(SystemGPUUsage.percent(from: ["GPU Activity(%)": 42.5]) == 42.5)
    #expect(SystemGPUUsage.percent(from: ["Device Utilization %": -1]) == nil)
    #expect(SystemGPUUsage.percent(from: ["Device Utilization %": 101]) == nil)
    #expect(SystemGPUUsage.percent(from: ["Device Utilization %": Double.nan]) == nil)
    #expect(SystemGPUUsage.percent(from: ["Device Utilization %": true]) == nil)
    #expect(SystemGPUUsage.percent(from: ["Device Utilization %": "73"]) == nil)
    #expect(SystemGPUUsage.percent(from: ["Renderer Utilization %": 80]) == nil)
}

@Test func systemMemoryCountsPhysicalUseWithoutCacheOrDoubleCountingCompression() {
    // 100 anonymous pages include 20 purgeable pages; 30 wired + 40 physical
    // compressor pages yield 150 used pages. Test both Intel/Apple page sizes.
    for pageSize in [UInt64(4096), 16384] {
        #expect(SystemMemoryUsage.usedBytes(internalPages: 100, purgeablePages: 20,
                                           wiredPages: 30, compressorPages: 40,
                                           pageSize: pageSize, totalBytes: 200 * pageSize) == 150 * pageSize)
    }
    #expect(SystemMemoryUsage.usedBytes(internalPages: 5, purgeablePages: 10, wiredPages: 2,
                                       compressorPages: 3, pageSize: 4096, totalBytes: 8192) == 8192)
    let usage = SystemMemoryUsage(usedBytes: 75, totalBytes: 100, pressure: .normal)
    #expect(usage.percent == 75)
    #expect(usage.pressure == .normal)
}
