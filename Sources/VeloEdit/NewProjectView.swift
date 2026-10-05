import SwiftUI
import AppKit

struct NewProjectView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: Field?
    @State private var showsTags = false

    private enum Field { case name, tags }
    private let accent = Color(red: 0.70, green: 0.59, blue: 0.96)
    private let secondary = Color(red: 0.64, green: 0.63, blue: 0.70)

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                projectPreview
                    .frame(width: min(180, max(124, geometry.size.width * 0.28)))
                    .frame(maxHeight: .infinity)
                    .background(.black.opacity(0.12))

                Rectangle().fill(.white.opacity(0.09)).frame(width: 1)

                form
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("new-project-form")
        .task { focusedField = .name }
    }

    private var projectPreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer().frame(height: 17)

            Spacer(minLength: 8)

            VStack(spacing: 16) {
                ZStack {
                    Image(systemName: "film")
                        .font(.system(size: 56, weight: .light))
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .medium))
                }
                .foregroundStyle(Color(red: 0.89, green: 0.86, blue: 0.81))
                .accessibilityHidden(true)

                Text(model.newProjectDraft.projectName.isEmpty ? "Мой фильм" : model.newProjectDraft.projectName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 8)

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.44))
                        .frame(width: geometry.size.width * 0.76, height: 7)
                    RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.36))
                        .frame(width: geometry.size.width * 0.68, height: 7)
                        .offset(x: geometry.size.width * 0.30, y: 13)
                    RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.52))
                        .frame(width: geometry.size.width * 0.34, height: 7)
                        .offset(x: geometry.size.width * 0.52, y: 26)
                    Rectangle().fill(accent.opacity(0.9))
                        .frame(width: 1, height: 44).offset(x: geometry.size.width * 0.45, y: -5)
                }
            }
            .frame(height: 44)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { scroll in
                ScrollView(.vertical) {
                    formFields.padding(2)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: showsTags) { _, expanded in
                    guard expanded else { return }
                    DispatchQueue.main.async {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            scroll.scrollTo("new-project-tags", anchor: .bottom)
                        }
                    }
                }
            }
            formActions
        }
        .disabled(model.isCreatingProject)
    }

    private var formFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Новый проект")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Название проекта")
                TextField("Мой фильм", text: $model.newProjectDraft.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(focusedField == .name ? accent : .white.opacity(0.12), lineWidth: focusedField == .name ? 2 : 1)
                    }
                    .focused($focusedField, equals: .name)
                    .accessibilityLabel("Название проекта")
                    .accessibilityIdentifier("new-project-name")
                    .onSubmit(createProject)
            }

            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("Расположение")
                HStack(spacing: 7) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color(red: 0.35, green: 0.70, blue: 0.95))
                    Text(FileManager.default.displayName(atPath: model.newProjectDraft.directoryURL.path))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Изменить…", action: model.chooseNewProjectDirectory)
                        .buttonStyle(StudioProjectButtonStyle(compact: true))
                        .accessibilityLabel("Изменить папку проекта")
                }
                .padding(.horizontal, 9)
                .frame(height: 36)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07), lineWidth: 1) }
                .help(model.newProjectDraft.directoryURL.path)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { showsTags.toggle() }
                    if showsTags { focusedField = .tags }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(showsTags ? 90 : 0))
                        Text("Добавить теги").font(.system(size: 12))
                    }
                    .foregroundStyle(secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsTags ? "Развёрнуто" : "Свёрнуто")

                if showsTags {
                    TextField("Например: путешествие, семья", text: $model.newProjectDraft.tags)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(9)
                        .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(focusedField == .tags ? accent : .white.opacity(0.12), lineWidth: 1) }
                        .focused($focusedField, equals: .tags)
                        .accessibilityLabel("Теги через запятую")
                        .onSubmit(createProject)
                        .id("new-project-tags")
                }
            }

            if let message = model.newProjectDraft.validationMessage ?? model.newProjectError {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1, green: 0.64, blue: 0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formActions: some View {
        VStack(spacing: 10) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Отмена") {
                    DispatchQueue.main.async { model.cancelProjectCreation() }
                }
                .buttonStyle(StudioProjectButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button(action: createProject) {
                    HStack(spacing: 8) {
                        if model.isCreatingProject { ProgressView().controlSize(.small).tint(.black) }
                        Text(model.isCreatingProject ? "Создаю…" : "Создать проект")
                    }
                }
                .buttonStyle(StudioProjectButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .disabled(model.newProjectDraft.validationMessage != nil)
                .accessibilityIdentifier("create-project-confirm")
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(secondary)
    }

    private func createProject() {
        Task { await model.confirmProjectCreation() }
    }
}

private struct StudioProjectButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var primary = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 13, weight: primary ? .semibold : .medium))
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 26 : 32)
            .foregroundStyle(primary ? Color(red: 0.10, green: 0.07, blue: 0.16) : .white.opacity(0.90))
            .background(
                primary ? Color(red: 0.70, green: 0.59, blue: 0.96) : .white.opacity(configuration.isPressed ? 0.13 : 0.065),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(primary ? 0.12 : 0.10), lineWidth: 1) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}
