import Foundation

/// The answers to a survey as they're given, checked by the same rules the server applies to
/// survey.submitted (DeviceEvents::answer), as on Android: choices by id, one for a single
/// choice; a rating a whole number from 1 to 5; true/false; a number; text of at most 2000
/// characters. Every required question needs an answer before it can be sent.
package struct SurveyForm: Sendable {
    package typealias Question = BubblNotification.Question

    package static let maxText = 2000
    /// The contract leaves the slider's range open; 0–10 in halves, like a recommend score.
    package static let sliderMin = 0.0
    package static let sliderMax = 10.0
    package static let sliderStep = 0.5

    package let questions: [Question]
    private var answers: [String: JSONValue] = [:]

    package init(_ questions: [Question]) {
        self.questions = questions
    }

    package func answer(_ questionId: String) -> JSONValue? { answers[questionId] }

    package mutating func setText(_ question: Question, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        set(question, trimmed.isEmpty ? nil : .string(String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(Self.maxText)))))
    }

    package mutating func setChoice(_ question: Question, _ choiceId: String) {
        set(question, .string(choiceId))
    }

    package mutating func toggleChoice(_ question: Question, _ choiceId: String, chosen: Bool) {
        var current: [String] = []
        if case .array(let values)? = answers[question.id] { current = values.compactMap(\.stringValue) }
        let next = chosen ? current + [choiceId] : current.filter { $0 != choiceId }
        // Keep the question's own order, whatever order they were ticked in.
        let ordered = question.choices.map(\.id).filter(next.contains)
        set(question, ordered.isEmpty ? nil : .array(ordered.map(JSONValue.string)))
    }

    package mutating func setRating(_ question: Question, _ stars: Int) {
        set(question, .int(Int64(min(max(stars, 1), 5))))
    }

    package mutating func setBoolean(_ question: Question, _ value: Bool) {
        set(question, .bool(value))
    }

    /// A number typed in; anything that isn't one clears the answer.
    package mutating func setNumber(_ question: Question, _ text: String) {
        set(question, Self.parseNumber(text))
    }

    package mutating func setSlider(_ question: Question, _ value: Double) {
        set(question, Self.normalise(min(max(value, Self.sliderMin), Self.sliderMax)))
    }

    /// Required questions still without an answer.
    package var missing: [Question] { questions.filter { $0.required && answers[$0.id] == nil } }

    package var isComplete: Bool { missing.isEmpty }

    /// survey.submitted's data, in the contract's shape (events.json); nil until complete. (Never a
    /// trap: an SDK must not bring down the app it's in.)
    package func eventData(_ campaignNotificationId: String) -> [String: JSONValue]? {
        guard isComplete else { return nil }
        let list = questions.compactMap { question in
            answers[question.id].map { JSONValue.object(["question_id": .string(question.id), "value": $0]) }
        }
        return ["campaign_notification_id": .string(campaignNotificationId), "answers": .array(list)]
    }

    /// Answers `question` (or clears it, for nil). A question of another survey is ignored.
    private mutating func set(_ question: Question, _ value: JSONValue?) {
        guard questions.contains(question) else {
            BubblLog.warning("An answer to \"\(question.id)\", which isn't a question of this survey, was ignored")
            return
        }
        answers[question.id] = value
    }

    /// A form filled from an app's own survey UI: `answers` by question id, as a choice id (single
    /// choice), choice ids (multiple), a whole number 1–5 (rating), true/false, a number (number,
    /// slider within its range) or text. Returns the form, or why it can't be sent.
    package static func fromAnswers(_ questions: [Question], _ answers: [String: JSONValue]) -> Result<SurveyForm, SurveyProblem> {
        var form = SurveyForm(questions)
        let byId = Dictionary(questions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, value) in answers.sorted(by: { $0.key < $1.key }) {
            guard let question = byId[id] else { return .failure(SurveyProblem("\"\(id)\" isn't a question of this survey")) }
            if value == .null { continue }
            let choiceIds = Set(question.choices.map(\.id))
            let problem: String?

            switch question.kind {
            case .singleChoice:
                if let choice = value.stringValue, choiceIds.contains(choice) {
                    form.setChoice(question, choice)
                    problem = nil
                } else {
                    problem = "one of its choice ids"
                }
            case .multipleChoice:
                if case .array(let items) = value, items.allSatisfy({ $0.stringValue.map(choiceIds.contains) == true }) {
                    items.compactMap(\.stringValue).forEach { form.toggleChoice(question, $0, chosen: true) }
                    problem = nil
                } else {
                    problem = "a list of its choice ids"
                }
            case .rating:
                if let stars = value.number, stars == stars.rounded(), (1...5).contains(stars) {
                    form.setRating(question, Int(stars))
                    problem = nil
                } else {
                    problem = "a whole number from 1 to 5"
                }
            case .boolean:
                if case .bool(let answer) = value {
                    form.setBoolean(question, answer)
                    problem = nil
                } else {
                    problem = "true or false"
                }
            case .number:
                if let number = value.number, number.isFinite {
                    form.set(question, normalise(number))
                    problem = nil
                } else {
                    problem = "a number"
                }
            case .slider:
                if let number = value.number, (sliderMin...sliderMax).contains(number) {
                    form.setSlider(question, number)
                    problem = nil
                } else {
                    problem = "a number from \(sliderMin) to \(sliderMax)"
                }
            case .openEnded:
                if let text = value.stringValue, text.unicodeScalars.count <= maxText {
                    form.setText(question, text)
                    problem = nil
                } else {
                    problem = "text of at most \(maxText) characters"
                }
            }

            if let problem { return .failure(SurveyProblem("the answer to \"\(question.text)\" must be \(problem)")) }
        }

        if let missing = form.missing.first { return .failure(SurveyProblem("\"\(missing.text)\" needs an answer")) }
        return .success(form)
    }

    /// A number as a person types it ("3", " 2,5 "); nil for anything else.
    package static func parseNumber(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return normalise(value)
    }

    /// Whole numbers are sent as integers (4, not 4.0), as a person would expect to see them.
    private static func normalise(_ value: Double) -> JSONValue {
        if value == value.rounded(), abs(value) < 9.0e15 { return .int(Int64(value)) }
        return .double(value)
    }
}

/// Why a survey's answers can't be sent, in words fit for a developer's log.
package struct SurveyProblem: Error, Equatable, CustomStringConvertible {
    package let description: String
    package init(_ description: String) { self.description = description }
}

extension JSONValue {
    /// A number, whole or not; nil for anything else (true/false included).
    package var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}
