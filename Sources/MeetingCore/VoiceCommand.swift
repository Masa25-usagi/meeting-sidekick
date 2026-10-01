import Foundation

/// Explicit meeting controls. General questions and uncertain language stay in the
/// ordinary conversation/judgment path instead of becoming settings changes.
public enum VoiceCommand: Equatable, Sendable {
    case listenOnly
    case resumeConversation
    case endSession
    case stopWork
    case setObjective(String)
    case allowPrototypes(Bool)
}

public enum VoiceCommandParser {
    /// Pure parser: callers deduplicate events and decide whether this source is
    /// allowed to control their meeting. Only final, non-assistant input qualifies.
    public static func parse(event: TranscriptEvent, policy: MeetingPolicy) -> VoiceCommand? {
        guard event.isFinal, event.source != .assistant else { return nil }
        let nickname = policy.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nickname.isEmpty, event.text.count <= 512 else { return nil }
        var text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Quoted instructions, questions, and multiple lines are not commands.
        guard text.rangeOfCharacter(from: forbiddenCharacters) == nil else { return nil }

        for greeting in ["ねえ", "ねぇ", "ねー", "おーい"] {
            if text.hasPrefix(greeting) {
                text.removeFirst(greeting.count)
                text = trimmingSeparators(text)
                break
            }
        }
        guard let nameRange = text.range(of: nickname, options: [.anchored, .caseInsensitive, .widthInsensitive]) else { return nil }
        text = trimmingSeparators(String(text[nameRange.upperBound...]))
        text = text.trimmingCharacters(in: endingCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // A complete command is required. Never find a command by substring in
        // commentary such as 「聞くだけにして、と言うとどうなる」.
        let command = removingPoliteEnding(text)
        if listenCommands.contains(command) { return .listenOnly }
        if resumeCommands.contains(command) { return .resumeConversation }
        if endCommands.contains(command) { return .endSession }
        if stopCommands.contains(command) { return .stopWork }
        if allowCommands.contains(command) { return .allowPrototypes(true) }
        if disallowCommands.contains(command) { return .allowPrototypes(false) }

        return objective(from: text).map(VoiceCommand.setObjective)
    }

    private static let forbiddenCharacters = CharacterSet(charactersIn: "「」『』\"“”‘’`?？\n\r")
    private static let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "、,，:：。．."))
    private static let endingCharacters = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "。．.!！"))

    private static func trimmingSeparators(_ text: String) -> String {
        text.trimmingCharacters(in: separators)
    }

    private static func removingPoliteEnding(_ text: String) -> String {
        if text.hasSuffix("ください") { return String(text.dropLast("ください".count)) }
        return text
    }

    private static let listenCommands: Set<String> = [
        "聞くだけにして", "聞くだけモードにして", "聞くだけ", "黙って聞いて", "会話を休止して"
    ]
    private static let resumeCommands: Set<String> = [
        "会話を再開して", "会話に戻って", "会話モードに戻って", "会話モードにして", "参加を再開して", "また話して"
    ]
    private static let endCommands: Set<String> = [
        "セッションを終了して", "会議を終了して", "終了して", "今日は終わり", "会議を終えて"
    ]
    private static let stopCommands: Set<String> = [
        "作業を止めて", "制作を止めて", "開発を止めて", "作業を停止して", "制作を停止して",
        "作業を中止して", "制作を中止して", "作業をキャンセルして", "制作をキャンセルして", "止めて"
    ]
    private static let allowCommands: Set<String> = [
        "試作を許可して", "試作していいよ", "自動試作を有効にして", "試作をオンにして", "自動制作を有効にして"
    ]
    private static let disallowCommands: Set<String> = [
        "試作しないで", "試作を禁止して", "自動試作を無効にして", "試作をオフにして",
        "自動制作を無効にして", "勝手に作らないで"
    ]

    private static func objective(from text: String) -> String? {
        // Only these declaration forms change the objective. The payload is kept
        // as user text; it is never interpreted as another command.
        let prefixes = ["今日の会議の目的は", "今日の目的は"]
        var value: String?
        for prefix in prefixes where text.hasPrefix(prefix) {
            value = String(text.dropFirst(prefix.count))
            break
        }
        if value == nil, text.hasPrefix("今日は") {
            let candidate = removingDeclarativeEnding(String(text.dropFirst("今日は".count)))
            if candidate.hasSuffix("の相談") { value = candidate }
        }
        guard let value else { return nil }
        let result = removingDeclarativeEnding(trimmingSeparators(value))
        guard (2...160).contains(result.count),
              result.rangeOfCharacter(from: CharacterSet(charactersIn: "。．.!！;；")) == nil,
              !objectiveNonDeclarations.contains(where: result.contains),
              !["か", "かな", "でしょう", "だろう"].contains(where: result.hasSuffix) else { return nil }
        return result
    }

    private static func removingDeclarativeEnding(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasSuffix("です") ? String(text.dropLast(2)).trimmingCharacters(in: .whitespaces) : text
    }

    // Deferrals, negations, quoted examples and conditionals need a conversation,
    // not a setting change. Ordinary goal language such as "失敗しないアプリ"
    // remains valid because it does not negate the declaration itself.
    private static let objectiveNonDeclarations = [
        "ではない", "じゃない", "ではなく", "じゃなく", "ではありません", "じゃありません",
        "にしない", "にするな", "にしなく", "やめて", "という", "っていう", "と言う", "といえば",
        "と言っ", "と言い", "って言", "の例", "だったら", "としたら", "の場合", "なら",
        "教えて", "説明して", "どうなる", "どう思う", "ですか", "ますか"
    ]
}
