import Foundation
import MeetingCore

/// Called by the existing standalone CheckRunner; no API calls or audio access.
func runVoiceCommandChecks() {
    let policy = MeetingPolicy(nickname: "サイドキック")
    func parse(_ text: String, source: AudioSource = .microphone, final: Bool = true, nickname: String = "サイドキック") -> VoiceCommand? {
        VoiceCommandParser.parse(event: TranscriptEvent(text: text, source: source, isFinal: final),
                                 policy: nickname == policy.nickname ? policy : MeetingPolicy(nickname: nickname))
    }

    let commands: [(String, VoiceCommand)] = [
        ("ねえ、サイドキック、聞くだけにして", .listenOnly),
        ("ねえサイドキック聞くだけにしてください。", .listenOnly),
        ("サイドキック。会話を再開して。", .resumeConversation),
        ("サイドキック、会議を終了して", .endSession),
        ("サイドキック、作業を止めてください", .stopWork),
        ("サイドキック、試作を許可して", .allowPrototypes(true)),
        ("サイドキック、自動試作を有効にしてください", .allowPrototypes(true)),
        ("サイドキック、試作しないで", .allowPrototypes(false)),
        ("サイドキック、自動試作を無効にして", .allowPrototypes(false)),
        ("サイドキック、今日は旅行アプリの相談", .setObjective("旅行アプリの相談")),
        ("サイドキック、今日の目的は旅行の計画", .setObjective("旅行の計画")),
        ("サイドキック、今日の会議の目的は失敗しないアプリの設計です。", .setObjective("失敗しないアプリの設計"))
    ]
    for (text, expected) in commands { expectEqual(parse(text), expected) }

    let nonCommands = [
        "サイドキック", "ねえ、サイドキック", "サイドキック、どう思う", "サイドキック、聞くだけにするって何",
        "今からサイドキック、聞くだけにしてと言います", "サイドキックという名前です。聞くだけにして",
        "「サイドキック、聞くだけにして」と言って", "サイドキック、\"会話を再開して\"という説明です",
        "サイドキック、聞くだけにしてほしくない", "サイドキック、作業を止めないで", "サイドキック、終了しないで",
        "サイドキック、試作を許可しないで", "サイドキック、自動試作を無効にしないで",
        "サイドキック、聞くだけにして、という例です", "サイドキック、聞くだけにして。これは例です",
        "サイドキック、今日の目的は旅行の計画ですか", "サイドキック、今日の目的は旅行の計画？",
        "サイドキック、今日の目的は旅行の計画ではない", "サイドキック、今日は旅行アプリの相談じゃない",
        "サイドキック、今日の目的は旅行の計画って言ったらどうなる", "サイドキック、今日の目的は旅行の計画という例です",
        "サイドキック、今日の目的は旅行の計画にしないで", "サイドキック、今日の目的は旅行なら何でもいい",
        "サイドキック、今日の目的は", "サイドキック、今日は旅行", "サイドキック、聞くだけにして\nという例です",
        "スーパーサイドキック、聞くだけにして", "サイドキック2、聞くだけにして"
    ]
    for text in nonCommands { expectEqual(parse(text), nil) }

    expectEqual(parse("サイドキック、聞くだけにして", final: false), nil)
    expectEqual(parse("サイドキック、聞くだけにして", source: .assistant), nil)
    expectEqual(parse("サイドキック、聞くだけにして", nickname: ""), nil)
    expectEqual(parse("ミナ、聞くだけにして", nickname: "ミナ"), .listenOnly)
    expectEqual(parse("ＭＩＮＡ、聞くだけにして", nickname: "Mina"), .listenOnly)
    expectEqual(parse("サイドキック、今日の目的は" + String(repeating: "旅", count: 161)), nil)
}
