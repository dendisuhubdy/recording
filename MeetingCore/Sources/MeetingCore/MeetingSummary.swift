import Foundation

public struct MeetingSummary: Codable, Equatable, Sendable {
    public struct ActionItem: Codable, Equatable, Sendable {
        public let owner: String
        public let task: String

        public init(owner: String, task: String) {
            self.owner = owner
            self.task = task
        }
    }

    public let title: String
    public let summary: String
    public let decisions: [String]
    public let actionItems: [ActionItem]
    public let openQuestions: [String]

    private enum CodingKeys: String, CodingKey {
        case title, summary, decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    public init(
        title: String,
        summary: String,
        decisions: [String],
        actionItems: [ActionItem],
        openQuestions: [String]
    ) {
        self.title = title
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    /// Rendered form written to `summary.md`.
    public var markdown: String {
        var lines = ["# \(title)", "", summary]
        if !decisions.isEmpty {
            lines += ["", "## Decisions"] + decisions.map { "- \($0)" }
        }
        if !actionItems.isEmpty {
            lines += ["", "## Action items"] + actionItems.map { "- **\($0.owner)**: \($0.task)" }
        }
        if !openQuestions.isEmpty {
            lines += ["", "## Open questions"] + openQuestions.map { "- \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
