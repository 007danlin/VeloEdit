import SwiftUI
import VeloEditCore

/// Owns the one-second UI updates so they do not invalidate the editor model.
struct SystemResourceStatusView: View {
    @State private var snapshot: SystemResourceSnapshot?
    @State private var showsDetails = false

    private func loadTint(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value >= 85 { return .red }
        if value >= 60 { return .orange }
        return .green
    }

    private var thermalTint: Color {
        switch snapshot?.thermalLevel {
        case .critical, .serious: return .red
        case .fair: return .orange
        case .nominal: return .green
        case nil: return .secondary
        }
    }

    private var summary: String {
        switch snapshot?.thermalLevel {
        case .nominal: return "Нагрев в норме"
        case .fair: return "Mac нагревается"
        case .serious: return "Высокий нагрев"
        case .critical: return "Охлаждение"
        case nil: return "Проверяю Mac"
        }
    }

    var body: some View {
        Button { showsDetails.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(thermalTint)
                    .frame(width: 18)
                Text(summary)
                    .font(.system(size: 11, weight: .medium))
                VStack(alignment: .leading, spacing: 3) {
                    Text("CPU \(percent(snapshot?.systemCPUPercent))")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                    loadMeter(snapshot?.systemCPUPercent, processValue: snapshot?.processCPUPercent,
                              label: "Общая нагрузка Mac · CPU", height: 4)
                }
                .frame(width: 54)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Нагрузка и нагрев Mac")
        .accessibilityLabel("Состояние компьютера")
        .accessibilityValue("\(summary), CPU \(percent(snapshot?.systemCPUPercent))")
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "thermometer.medium")
                        .font(.title2)
                        .foregroundStyle(thermalTint)
                        .frame(width: 36, height: 36)
                        .background(thermalTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Состояние Mac").font(.headline)
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                loadRow("Общая нагрузка Mac · CPU", value: snapshot?.systemCPUPercent,
                        processValue: snapshot?.processCPUPercent)
                    .help("Занятость всех ядер CPU за интервал около секунды. 100% — занят весь процессор Mac. Синий участок — доля VeloEdit в этой нагрузке.")
                loadRow("Нагрузка Mac · GPU", value: snapshot?.systemGPUPercent,
                        processValue: snapshot?.processGPUPercent)
                    .help("Общая занятость GPU по данным драйвера, включая все приложения и системные службы. При нескольких GPU показан самый занятый. Синий участок — нагрузка VeloEdit по времени работы GPU. Если драйвер не сообщает нагрузку приложения, синий участок не отображается, а значение VeloEdit показано как «Нет данных».")
                loadRow("Память Mac", value: snapshot?.systemMemory?.percent,
                        processValue: processMemoryPercent, formattedValue: snapshot?.systemMemory.map {
                    "\(memorySize($0.usedBytes)) из \(memorySize($0.totalBytes))"
                }, tint: memoryTint)
                .help("Память приложений, системная и сжатая память всего Mac. Освобождаемый файловый кэш исключён. Синий участок — резидентная память VeloEdit в масштабе всей памяти Mac. Цвет остальной занятой памяти отражает давление памяти macOS.")
                Text(snapshot?.systemMemory?.pressure?.title ?? "Давление памяти: нет данных")
                    .font(.caption)
                    .foregroundStyle(memoryTint)
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    Text("VeloEdit: CPU \(percent(snapshot?.processCPUPercent)) · GPU \(snapshot?.processGPUPercent.map { percent($0) } ?? "Нет данных") · память \(snapshot?.processMemoryBytes.map(memorySize) ?? "—")")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .help("Синие участки показывают долю процесса VeloEdit в общей нагрузке. При нулевой или небольшой нагрузке остаётся круглый синий маркер; точные значения указаны рядом. CPU — доля всех ядер Mac, GPU — по данным драйвера, память — резидентная. Другие процессы учитываются в общих показателях выше.")
                if snapshot?.workLimit == .cooling {
                    Label("Обработка ждёт охлаждения", systemImage: "pause.circle")
                        .foregroundStyle(.red)
                } else if snapshot?.workLimit == .reduced {
                    Label("Нагрузка ограничена", systemImage: "gauge.with.dots.needle.33percent")
                        .foregroundStyle(.orange)
                }
                if snapshot?.lowPowerMode == true {
                    Label("Энергосбережение", systemImage: "leaf")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(20)
            .frame(width: 360)
        }
        .task {
            while !Task.isCancelled {
                snapshot = await SystemResourceMonitor.shared.snapshot()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    private var memoryTint: Color {
        switch snapshot?.systemMemory?.pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case nil: return .secondary
        }
    }

    private func memorySize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    private var processMemoryPercent: Double? {
        guard let bytes = snapshot?.processMemoryBytes,
              let totalBytes = snapshot?.systemMemory?.totalBytes, totalBytes > 0 else { return nil }
        return 100 * Double(bytes) / Double(totalBytes)
    }

    private func loadRow(_ label: String, value: Double?, processValue: Double?, formattedValue: String? = nil, tint: Color? = nil) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(formattedValue ?? (value == nil ? "Нет данных" : percent(value)))
                    .font(.callout.weight(.semibold)).monospacedDigit()
            }
            loadMeter(value, processValue: processValue, label: label, height: 8, tint: tint)
        }
    }

    private func loadMeter(_ value: Double?, processValue: Double?, label: String, height: CGFloat, tint: Color? = nil) -> some View {
        GeometryReader { geometry in
            // Both segments use the full machine's capacity as their scale.
            // Clamp independently sampled process usage to the total fill.
            let fraction = CGFloat(min(100, max(0, value ?? 0))) / 100
            let processFraction = min(fraction, CGFloat(min(100, max(0, processValue ?? 0))) / 100)
            // Keep known idle/low usage visible as a circle, then grow it into
            // a capsule. Unavailable measurements never get a blue marker.
            let processWidth = min(geometry.size.width, max(height, geometry.size.width * processFraction))
            let tint = tint ?? loadTint(value)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if value != nil {
                    Capsule().fill(tint.gradient)
                        .frame(width: geometry.size.width * fraction)
                    if processValue != nil {
                        Capsule().fill(Color.blue.gradient)
                            .overlay {
                                Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
                            }
                            .frame(width: processWidth)
                    }
                }
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.4), value: value)
        .animation(.easeInOut(duration: 0.4), value: processValue)
        .accessibilityLabel(label)
        .accessibilityValue("\(percent(value)), VeloEdit: \(processValue.map { percent($0) } ?? "Нет данных")")
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }
}
