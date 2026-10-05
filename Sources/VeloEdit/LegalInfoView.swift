import SwiftUI
import AppKit

struct LegalInfoView: View {
    @State private var selection = "LICENSE"

    private var legalDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Legal", isDirectory: true)
    }

    private var document: String {
        guard let url = legalDirectory?.appendingPathComponent(selection + ".txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Документ недоступен в этой сборке."
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Лицензия и компоненты").font(.title2.bold())
            Picker("Документ", selection: $selection) {
                Text("Лицензия VeloEdit").tag("LICENSE")
                Text("Сторонние компоненты").tag("THIRD_PARTY")
            }
            .pickerStyle(.segmented)

            ScrollView {
                Text(document)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Тексты лицензий") {
                    if let url = legalDirectory { NSWorkspace.shared.open(url) }
                }
                Button("Исходники OVRLEY") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("OVRLEY-Source") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "VeloEdit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(minWidth: 640, idealWidth: 780, minHeight: 480, idealHeight: 620)
    }
}
