import SwiftUI

struct SessionQuestionForm: View {
    let intervention: SessionIntervention
    let submitLabel: String?
    let onSubmit: ([String: [String]]) -> Void
    var secondaryActionTitle: String? = nil
    var onSecondaryAction: (() -> Void)? = nil
    var isEditable: Bool = true

    @ObservedObject private var settings = AppSettings.shared
    @State private var answers: [String: [String]] = [:]
    @State private var otherAnswers: [String: String] = [:]
    @State private var measuredQuestionContentHeight: CGFloat = 0

    private var displayQuestions: [SessionInterventionQuestion] {
        intervention.resolvedQuestions
    }

    nonisolated static func optionColumns(
        for question: SessionInterventionQuestion
    ) -> [GridItem] {
        if shouldUseSingleColumnOptions(for: question) {
            return [GridItem(.flexible(minimum: 0), spacing: 8)]
        }

        return [GridItem(.adaptive(minimum: 150), spacing: 8)]
    }

    nonisolated static func shouldUseSingleColumnOptions(
        for question: SessionInterventionQuestion
    ) -> Bool {
        question.options.contains { option in
            option.title.count > 24
                || ((option.detail?.count ?? 0) > 72)
        }
    }

    nonisolated static func questionListMaximumHeight(for maxPanelHeight: Double) -> CGFloat {
        let minimumQuestionListHeight: CGFloat = 230
        let reservedPanelChromeHeight: CGFloat = 250
        let outerScrollSafetyInset: CGFloat = 80

        return max(
            minimumQuestionListHeight,
            CGFloat(maxPanelHeight) - reservedPanelChromeHeight - outerScrollSafetyInset
        )
    }

    nonisolated static func questionListHeight(
        contentHeight: CGFloat,
        maximumHeight: CGFloat
    ) -> CGFloat {
        guard contentHeight > 0 else {
            return maximumHeight
        }

        return min(contentHeight, maximumHeight)
    }

    nonisolated static func optionSequenceLabel(for index: Int) -> String {
        guard index >= 0 else { return "" }

        var remaining = index
        var label = ""

        repeat {
            let scalarValue = 65 + remaining % 26
            if let scalar = UnicodeScalar(scalarValue) {
                label.insert(Character(scalar), at: label.startIndex)
            }
            remaining = remaining / 26 - 1
        } while remaining >= 0

        return label
    }

    nonisolated static func nextQuestionIDToReveal(
        after questionID: String,
        in questions: [SessionInterventionQuestion],
        answeredQuestionIDs: Set<String>
    ) -> String? {
        guard questions.count > 1,
              let currentIndex = questions.firstIndex(where: { $0.id == questionID })
        else {
            return nil
        }

        let laterQuestions = questions[questions.index(after: currentIndex)...]
        if let nextUnansweredQuestion = laterQuestions.first(where: { !answeredQuestionIDs.contains($0.id) }) {
            return nextUnansweredQuestion.id
        }

        return laterQuestions.first?.id
    }

    private var questionListMaximumHeight: CGFloat {
        Self.questionListMaximumHeight(for: settings.maxPanelHeight)
    }

    private var questionListHeight: CGFloat {
        Self.questionListHeight(
            contentHeight: measuredQuestionContentHeight,
            maximumHeight: questionListMaximumHeight
        )
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
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    questionsContent(scrollProxy: scrollProxy)
                        .padding(.vertical, 1)
                        .readHeight { measuredQuestionContentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(height: questionListHeight)
            .clipped()

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

    private func questionsContent(scrollProxy: ScrollViewProxy) -> some View {
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

                    questionInput(question, scrollProxy: scrollProxy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(question.id)
            }
        }
    }

    @ViewBuilder
    private func questionInput(
        _ question: SessionInterventionQuestion,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        if !question.options.isEmpty {
            let reservesDetailSpace = question.options.contains { optionDetail(for: $0) != nil }
            LazyVGrid(columns: Self.optionColumns(for: question), spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.element.id) { optionIndex, option in
                    Button {
                        guard isEditable else { return }
                        toggle(option.title, for: question)
                        revealNextQuestion(after: question, using: scrollProxy)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.optionSequenceLabel(for: optionIndex))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(isSelected(option.title, for: question) ? TerminalColors.blue : .white.opacity(0.62))
                                .frame(width: 20, height: 20)
                                .background(
                                    Circle()
                                        .fill(
                                            isSelected(option.title, for: question)
                                                ? TerminalColors.blue.opacity(0.16)
                                                : Color.white.opacity(0.06)
                                        )
                                )

                            if question.allowsMultiple {
                                Image(systemName: isSelected(option.title, for: question) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(isSelected(option.title, for: question) ? TerminalColors.blue : .white.opacity(0.55))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let detail = optionDetail(for: option) {
                                    Text(detail)
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.55))
                                        .fixedSize(horizontal: false, vertical: true)
                                } else if reservesDetailSpace {
                                    Text(" ")
                                        .font(.system(size: 10))
                                        .hidden()
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
                                .strokeBorder(
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
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
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
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
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
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
    }

    private var canSubmit: Bool {
        !displayQuestions.contains { finalAnswers(for: $0).isEmpty }
    }

    private func isSelected(_ title: String, for question: SessionInterventionQuestion) -> Bool {
        answers[question.id, default: []].contains(title)
    }

    private var answeredQuestionIDs: Set<String> {
        Set(displayQuestions.compactMap { question in
            finalAnswers(for: question).isEmpty ? nil : question.id
        })
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

    private func revealNextQuestion(
        after question: SessionInterventionQuestion,
        using scrollProxy: ScrollViewProxy
    ) {
        guard !finalAnswers(for: question).isEmpty,
              let nextQuestionID = Self.nextQuestionIDToReveal(
                after: question.id,
                in: displayQuestions,
                answeredQuestionIDs: answeredQuestionIDs
              )
        else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.08)) {
                scrollProxy.scrollTo(nextQuestionID, anchor: .top)
            }
        }
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

    private func optionDetail(for option: SessionInterventionOption) -> String? {
        let trimmed = option.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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

private struct QuestionContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: QuestionContentHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        )
        .onPreferenceChange(QuestionContentHeightPreferenceKey.self, perform: onChange)
    }
}
