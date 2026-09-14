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
                    loadMeter(snapshot?.systemCPUPercent, label: "Общая нагрузка Mac · CPU", height: 4)
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
                loadRow("Общая нагрузка Mac · CPU", value: snapshot?.systemCPUPercent)
                    .help("Занятость всех ядер CPU за интервал около секунды. 100% — занят весь процессор Mac.")
                loadRow("Нагрузка Mac · GPU", value: snapshot?.systemGPUPercent)
                    .help("Общая занятость GPU по данным драйвера, включая все приложения и системные службы. При нескольких GPU показан самый занятый. Если драйвер не отдаёт показатель, отображается «Нет данных».")
                loadRow("Память Mac", value: snapshot?.systemMemory?.percent, formattedValue: snapshot?.systemMemory.map {
                    "\(memorySize($0.usedBytes)) из \(memorySize($0.totalBytes))"
                }, tint: memoryTint)
                .help("Память приложений, системная и сжатая память всего Mac. Освобождаемый файловый кэш исключён. Цвет отражает давление памяти macOS.")
                Text(snapshot?.systemMemory?.pressure?.title ?? "Давление памяти: нет данных")
                    .font(.caption)
                    .foregroundStyle(memoryTint)
                Divider()
                Text("VeloEdit: CPU \(percent(snapshot?.processCPUPercent)) · память \(snapshot?.processMemoryBytes.map(memorySize) ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Только процесс VeloEdit: CPU как доля всех ядер Mac и резидентная память. Другие процессы учитываются в общих показателях выше.")
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

    private func loadRow(_ label: String, value: Double?, formattedValue: String? = nil, tint: Color? = nil) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(formattedValue ?? (value == nil ? "Нет данных" : percent(value)))
                    .font(.callout.weight(.semibold)).monospacedDigit()
            }
            loadMeter(value, label: label, height: 8, tint: tint)
        }
    }

    private func loadMeter(_ value: Double?, label: String, height: CGFloat, tint: Color? = nil) -> some View {
        GeometryReader { geometry in
            // Keep the rounded marker's shape independent of the measured value.
            // Its travel, rather than its width, represents 0...100% of the scale.
            let markerWidth = min(geometry.size.width, height * 2.5)
            let fraction = CGFloat(min(100, max(0, value ?? 0))) / 100
            let markerOffset = max(0, geometry.size.width - markerWidth) * fraction
            let tint = tint ?? loadTint(value)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if value != nil {
                    Capsule().fill(tint.gradient)
                        .frame(width: markerOffset + markerWidth)
                    Capsule().fill(tint.gradient)
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        }
                        .frame(width: markerWidth)
                        .offset(x: markerOffset)
                }
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.4), value: value)
        .accessibilityLabel(label)
        .accessibilityValue(percent(value))
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }
}
