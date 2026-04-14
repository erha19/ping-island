import SwiftUI

struct SessionQuestionForm: View {
    let intervention: SessionIntervention
    let submitLabel: String?
    let onSubmit: ([String: [String]]) -> Void
    var secondaryActionTitle: String? = nil
    var onSecondaryAction: (() -> Void)? = nil
    var isEditable: Bool = true

    @State private var answers: [String: [String]] = [:]
    @State private var otherAnswers: [String: String] = [:]

    private var displayQuestions: [SessionInterventionQuestion] {
        intervention.resolvedQuestions
    }

    nonisolated static func shouldUseScrollableQuestionList(
        for questions: [SessionInterventionQuestion]
    ) -> Bool {
        if questions.count > 1 {
            return true
        }

        return questions.contains { question in
            let weightedOptions = question.options.reduce(0) { partial, option in
                partial + (option.detail == nil ? 1 : 2)
            }
            return weightedOptions >= 3 || question.allowsOther || question.isSecret
        }
    }

    private var shouldUseScrollableQuestionList: Bool {
        Self.shouldUseScrollableQuestionList(for: displayQuestions)
    }

    init(
        intervention: SessionIntervention,
        submitLabel: String? = nil,
        initialAnswers: [String: [String]] = [:],
        onSubmit: @escaping ([String: [String]]) -> Void,
        secondaryActionTitle: String? = nil,
        onSecondaryAction: (() -> Void)? = nil,
        isEditable: Bool = true
    ) {
        self.intervention = intervention
        self.submitLabel = submitLabel
        self.onSubmit = onSubmit
        self.secondaryActionTitle = secondaryActionTitle
        self.onSecondaryAction = onSecondaryAction
        self.isEditable = isEditable
        _answers = State(initialValue: initialAnswers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if shouldUseScrollableQuestionList {
                    ScrollView(.vertical, showsIndicators: false) {
                        questionsContent
                            .padding(.vertical, 1)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 230)
                } else {
                    questionsContent
                }
            }

            HStack(spacing: 8) {
                if let submitLabel {
                    Button {
                        onSubmit(submissionPayload())
                    }
                    label: {
                        Text(appLocalized: submitLabel)
                    }
                    .buttonStyle(SessionQuestionButtonStyle(background: Color.white.opacity(0.9), foreground: .black))
                    .disabled(!canSubmit || !isEditable)
                }

                if let secondaryActionTitle, let onSecondaryAction {
                    Button {
                        onSecondaryAction()
                    }
                    label: {
                        Text(verbatim: secondaryActionTitle)
                    }
                    .buttonStyle(SessionQuestionButtonStyle(background: Color.white.opacity(0.1)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var questionsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(displayQuestions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(question.header)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(TerminalColors.blue.opacity(0.9))

                        if question.allowsMultiple {
                            Text("多选")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(TerminalColors.amber.opacity(0.95))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(TerminalColors.amber.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }

                    Text(question.prompt)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let detail = question.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    questionInput(question)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func questionInput(_ question: SessionInterventionQuestion) -> some View {
        if !question.options.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(question.options) { option in
                    Button {
                        guard isEditable else { return }
                        toggle(option.title, for: question)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            if question.allowsMultiple {
                                Image(systemName: isSelected(option.title, for: question) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(isSelected(option.title, for: question) ? TerminalColors.blue : .white.opacity(0.55))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                if let detail = option.detail {
                                    Text(detail)
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.55))
                                        .lineLimit(2)
                                }
                            }

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    isSelected(option.title, for: question)
                                        ? TerminalColors.blue.opacity(0.12)
                                        : Color.white.opacity(0.04)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    isSelected(option.title, for: question)
                                        ? TerminalColors.blue.opacity(0.72)
                                        : Color.white.opacity(0.14),
                                    lineWidth: 1
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEditable)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if question.allowsOther {
                TextField("其他答案", text: Binding(
                    get: { otherAnswers[question.id] ?? "" },
                    set: { otherAnswers[question.id] = $0 }
                ))
                .textFieldStyle(.plain)
                .padding(10)
                .disabled(!isEditable)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
            }
        } else if question.isSecret {
            SecureField("Answer", text: Binding(
                get: { answers[question.id]?.first ?? "" },
                set: { answers[question.id] = normalizedAnswers(from: $0) }
            ))
            .textFieldStyle(.plain)
            .padding(10)
            .disabled(!isEditable)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        } else {
            TextField("Answer", text: Binding(
                get: { answers[question.id]?.first ?? "" },
                set: { answers[question.id] = normalizedAnswers(from: $0) }
            ))
            .textFieldStyle(.plain)
            .padding(10)
            .disabled(!isEditable)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
    }

    private var canSubmit: Bool {
        !displayQuestions.contains { finalAnswers(for: $0).isEmpty }
    }

    private func isSelected(_ title: String, for question: SessionInterventionQuestion) -> Bool {
        answers[question.id, default: []].contains(title)
    }

    private func toggle(_ title: String, for question: SessionInterventionQuestion) {
        if question.allowsMultiple {
            var current = answers[question.id, default: []]
            if current.contains(title) {
                current.removeAll { $0 == title }
            } else {
                current.append(title)
            }
            answers[question.id] = current
            return
        }

        answers[question.id] = [title]
    }

    private func finalAnswers(for question: SessionInterventionQuestion) -> [String] {
        var current = answers[question.id, default: []]
        let other = otherAnswers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !other.isEmpty {
            current.append(other)
        }
        return current.filter { !$0.isEmpty }
    }

    private func submissionPayload() -> [String: [String]] {
        displayQuestions.reduce(into: [String: [String]]()) { partial, question in
            let resolved = finalAnswers(for: question)
            if !resolved.isEmpty {
                partial[question.id] = resolved
            }
        }
    }

    private func normalizedAnswers(from value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [trimmed]
    }
}

private struct SessionQuestionButtonStyle: ButtonStyle {
    let background: Color
    var foreground: Color = .white
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(
                foreground.opacity(
                    isEnabled
                        ? (configuration.isPressed ? 0.75 : 1)
                        : 0.45
                )
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(
                        background.opacity(
                            isEnabled
                                ? (configuration.isPressed ? 0.85 : 1)
                                : 0.35
                        )
                    )
            )
    }
}
