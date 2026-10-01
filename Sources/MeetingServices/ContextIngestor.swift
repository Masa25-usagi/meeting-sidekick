import Foundation
import MeetingCore

public enum IngestionError: LocalizedError, Equatable {
    case emptyResponse
    case missingRequiredCriteria(String)
    case invalidResponseFormat(String)

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "AIからの応答が空でした。判断基準を生成できませんでした。"
        case .missingRequiredCriteria(let msg):
            return "判断基準の必須項目が不足しています: \(msg)"
        case .invalidResponseFormat(let msg):
            return "判断基準の生成に失敗しました: \(msg)"
        }
    }
}

public struct IngestedContext: Sendable {
    public var projectSummary: String
    public var prototypeHistory: [String]
    public var recentLogs: String
    public var externalNotes: String

    public init(projectSummary: String = "", prototypeHistory: [String] = [], recentLogs: String = "", externalNotes: String = "") {
        self.projectSummary = projectSummary
        self.prototypeHistory = prototypeHistory
        self.recentLogs = recentLogs
        self.externalNotes = externalNotes
    }

    public var combinedDescription: String {
        var sections: [String] = []
        if !projectSummary.isEmpty {
            sections.append("【プロジェクト・設計情報】\n\(projectSummary)")
        }
        if !prototypeHistory.isEmpty {
            sections.append("【過去の試作品・制作履歴】\n" + prototypeHistory.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !recentLogs.isEmpty {
            sections.append("【直近の作業・Git履歴】\n\(recentLogs)")
        }
        if !externalNotes.isEmpty {
            sections.append("【外部チャット・スマホライフログ・メモ】\n\(externalNotes)")
        }
        return sections.joined(separator: "\n\n")
    }
}

@MainActor
public final class ContextIngestor {
    private let textClient: GeminiTextClient
    private let cliClient: CLITextClient

    public init(textClient: GeminiTextClient? = nil, cliClient: CLITextClient = CLITextClient()) {
        self.textClient = textClient ?? GeminiTextClient()
        self.cliClient = cliClient
    }

    /// スキャン: 指定ディレクトリ（Codex作業場やプロジェクト直下）からコンテキストを抽出
    nonisolated public func scanDirectoryContext(at url: URL, shouldStop: () -> Bool = { false }) -> IngestedContext {
        let fileManager = FileManager.default
        var projectSummary = ""
        var prototypeHistory: [String] = []
        var recentLogs = ""

        // 1. 主要ドキュメントの読み取り
        let docNames = ["REQUEST.md", "README.md", "SPEC.md", "meeting-agent-spec.md", "package.json"]
        for name in docNames {
            if shouldStop() { return IngestedContext() }
            let fileURL = url.appendingPathComponent(name)
            if fileManager.fileExists(atPath: fileURL.path),
               let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                let snippet = String(content.prefix(1500)).trimmingCharacters(in: .whitespacesAndNewlines)
                projectSummary += "[\(name)]\n\(snippet)\n\n"
            }
        }

        // 2. 過去の試作履歴（Prototypesディレクトリ）の探索
        let protoDir = url.appendingPathComponent("Prototypes")
        if fileManager.fileExists(atPath: protoDir.path),
           let items = try? fileManager.contentsOfDirectory(at: protoDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for item in items {
                if shouldStop() { return IngestedContext() }
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    let req = item.appendingPathComponent("REQUEST.md")
                    if let reqText = try? String(contentsOf: req, encoding: .utf8) {
                        let firstLine = reqText.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? item.lastPathComponent
                        prototypeHistory.append("\(item.lastPathComponent): \(firstLine.prefix(120))")
                    } else {
                        prototypeHistory.append(item.lastPathComponent)
                    }
                }
            }
        }

        // 3. Gitの最近のコミット履歴（.git/logs/HEADなどから直接読み込み、コマンド不要）
        let gitLogFile = url.appendingPathComponent(".git/logs/HEAD")
        if fileManager.fileExists(atPath: gitLogFile.path),
           let logText = try? String(contentsOf: gitLogFile, encoding: .utf8) {
            let lines = logText.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let recentLines = lines.suffix(5).compactMap { line -> String? in
                if let tabIndex = line.range(of: "\t") {
                    return String(line[tabIndex.upperBound...])
                }
                return nil
            }
            if !recentLines.isEmpty {
                recentLogs = recentLines.joined(separator: "\n")
            }
        }

        return IngestedContext(projectSummary: projectSummary, prototypeHistory: prototypeHistory, recentLogs: recentLogs)
    }

    /// LLMまたはローカルCLIを使って、コンテキストから高精度な判断基準（4大判断基準）を合成
    public func synthesizeRules(
        objective: String,
        nickname: String,
        context: IngestedContext,
        engine: String = "codex",
        executablePath: String = "",
        apiKey: String = "",
        model: String = "gemini-3.8-flash",
        codexModel: String = "gpt-6-sol",
        codexEffort: String = "low",
        codexBackend: (any CodexBackend)? = nil
    ) async throws -> SynthesizedRules {
        try Task.checkCancellation()
        let contextBody = context.combinedDescription

        let prompt = """
        あなたは自律型AIアシスタントのルール策定エンジンです。
        ユーザーは会議や日々の作業において、AI相棒（JEVなどの高速判断モデルと音声会話モデル）に、
        「文脈を理解した的確なツッコミ」「目的に沿った自動プロトタイプ試作」「危険な変更の自律的見送り」を行わせたいと考えています。

        以下の【入力情報】を注意深く分析し、AIが判断に迷わないための【4大判断基準】をJSONフォーマットで作成してください。

        【入力情報】
        会議・作業の目的: \(objective.isEmpty ? "目的未設定（アイデアからWebアプリを試作する）" : objective)
        希望の呼び名: \(nickname.isEmpty ? "サイドキック" : nickname)
        事前コンテキスト（プロジェクト設計、過去の試作、チャットログ、ライフログ等）:
        \(contextBody.isEmpty ? "事前コンテキストなし" : String(contextBody.prefix(8000)))

        【出力要件】
        必ず以下のキーを持つJSONオブジェクトのみを出力してください（前後に余計な解説を付けないこと）。
        ```json
        {
          "objective": "整理された本質的な目的（1〜2文）",
          "nickname": "\(nickname.isEmpty ? "サイドキック" : nickname)",
          "persona": "この文脈に最適な役割と発話トーン（例: ユーザー目線でUI/UXの矛盾や実装難度を率直に指摘するシニアテックリード）",
          "speakCriteria": [
            "発言・ツッコミを入れる具体的な基準1（例: 既存機能や過去の試作と重複する提案が出たとき）",
            "基準2（例: スケジュールや技術スタックの前提が非現実的なとき）",
            "基準3（例: 目的から外れた枝葉の議論が続いたとき）"
          ],
          "buildCriteria": [
            "自動試作（Webアプリ実装）を開始する基準1（例: 具体的な画面レイアウトやボタン配置の合意ができたとき）",
            "基準2（例: 「これ動かしてみたい」「プロトタイプが欲しい」といった前向きな要望が出たとき）",
            "基準3（例: ユーザー入力と出力の具体的なフローが決まったとき）"
          ],
          "doNotBuildCriteria": [
            "絶対に自動試作しない・見送る基準1（例: 外部決済や課金APIの連携）",
            "基準2（例: 本番DBマイグレーションや認証基盤の破壊的変更）",
            "基準3（例: 「後でいい」「まだ作らないで」などの保留発言が出たとき）"
          ],
          "projectSummary": "読み込んだコンテキストから抽出したプロジェクトの現状・重要決定事項の要約（200文字程度）"
        }
        ```
        """

        let responseText: String
        let chosenEngine = engine.lowercased()
        if chosenEngine == "codex" {
            let backend = codexBackend ?? CodexExecBackend(client: cliClient, executablePath: executablePath)
            responseText = try await backend.generate(CodexRequest(
                prompt: prompt, model: codexModel, reasoningEffort: codexEffort,
                enableSearch: false, timeoutSeconds: 60, workingDirectory: AppPaths.project.path
            )).text
        } else if chosenEngine == "agy" {
            responseText = try await cliClient.runAgy(prompt: prompt, executablePath: executablePath)
        } else if chosenEngine == "grok" {
            responseText = try await cliClient.runGrok(prompt: prompt, executablePath: executablePath)
        } else if chosenEngine == "gemini" {
            guard !apiKey.isEmpty else { throw ServiceError.missingKey }
            responseText = try await textClient.generate(apiKey: apiKey, model: model, prompt: prompt)
        } else {
            throw IngestionError.invalidResponseFormat("対応していない生成エンジンです。設定を確認してください。")
        }

        try Task.checkCancellation()
        return try parseSynthesizedRules(jsonText: responseText, defaultObjective: objective, defaultNickname: nickname)
    }

    /// JSONまたはテキストからの厳格なパース処理（不正な返答やエラーメッセージをフォールバック成功に化けさせない）
    public func parseSynthesizedRules(jsonText: String, defaultObjective: String, defaultNickname: String) throws -> SynthesizedRules {
        let trimmedRaw = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            throw IngestionError.emptyResponse
        }

        guard trimmedRaw.utf8.count <= 256 * 1024 else {
            throw IngestionError.invalidResponseFormat("応答が大きすぎます。既存の基準を維持します。")
        }

        // Accept only a whole JSON answer or a whole fenced JSON block. Do not extract
        // a plausible example from an error message or silently ignore trailing output.
        var cleanJson = trimmedRaw
        let fenced = trimmedRaw.hasPrefix("```")
        if fenced {
            let lines = trimmedRaw.components(separatedBy: .newlines)
            guard lines.count >= 3, ["```json", "```"].contains(lines[0].lowercased()),
                  lines.last == "```" else { throw invalidFormat() }
            cleanJson = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let data = cleanJson.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard obj["error"] == nil, obj["status"] as? String != "error" else { throw invalidFormat() }
            func string(_ key: String, fallback: String = "") throws -> String {
                guard let value = obj[key] else { return fallback }
                guard let value = value as? String else { throw invalidFormat() }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? fallback : trimmed
            }
            func criteria(_ key: String) throws -> [String] {
                guard let rawValues = obj[key] as? [String] else {
                    throw IngestionError.missingRequiredCriteria("判断基準は文字列の配列で指定してください。")
                }
                let cleaned = rawValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard !cleaned.isEmpty, cleaned.allSatisfy({ !$0.isEmpty }) else {
                    throw IngestionError.missingRequiredCriteria("判断基準の項目が空です。")
                }
                return cleaned
            }

            return SynthesizedRules(
                objective: try string("objective", fallback: defaultObjective),
                nickname: try string("nickname", fallback: defaultNickname),
                persona: try string("persona"),
                speakCriteria: try criteria("speakCriteria"),
                buildCriteria: try criteria("buildCriteria"),
                doNotBuildCriteria: try criteria("doNotBuildCriteria"),
                projectSummary: try string("projectSummary"),
                rawText: jsonText
            )
        }

        // Malformed JSON must not be reinterpreted as three successful Markdown sections.
        guard !fenced, !cleanJson.hasPrefix("{"), !cleanJson.hasPrefix("["),
              !CLIOutputDiagnostics.isAuthenticationFailure(trimmedRaw) else { throw invalidFormat() }

        // Preserve the existing plain-text API for explicit, complete Markdown criteria.
        // Match heading names, never keywords occurring inside a criterion or an error.
        let headings: [String: String] = [
            "ツッコミ": "speak", "発言": "speak", "speakCriteria": "speak",
            "ツッコミ・発言の判断基準": "speak", "💬 ツッコミ・発言の判断基準": "speak",
            "自動試作": "build", "buildCriteria": "build",
            "自動試作に着手する基準": "build", "🛠️ 自動試作に着手する基準": "build",
            "作らない": "donot", "見送り": "donot", "doNotBuildCriteria": "donot",
            "自動試作しない・見送る基準": "donot", "🚫 自動試作しない・見送る基準": "donot",
            "役割・キャラクター": "persona", "🎭 役割・キャラクター": "persona",
            "参照プロジェクト・事前コンテキスト要約": "summary", "📚 参照プロジェクト・事前コンテキスト要約": "summary"
        ]
        var sections: [String: [String]] = [:]
        var currentSection = ""
        for line in trimmedRaw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let heading = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# :："))
            if let section = headings[heading] {
                guard sections[section] == nil else { throw invalidFormat() }
                currentSection = section
                sections[section] = []
            } else if ["persona", "summary"].contains(currentSection) {
                sections[currentSection, default: []].append(trimmed)
            } else if ["speak", "build", "donot"].contains(currentSection),
                      trimmed.hasPrefix("- ") || trimmed.hasPrefix("・") || trimmed.hasPrefix("* ") {
                let item = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                guard !item.isEmpty else { throw invalidFormat() }
                sections[currentSection, default: []].append(item)
            } else {
                throw invalidFormat()
            }
        }
        guard let speak = sections["speak"], !speak.isEmpty,
              let build = sections["build"], !build.isEmpty,
              let doNot = sections["donot"], !doNot.isEmpty else { throw invalidFormat() }
        return SynthesizedRules(
            objective: defaultObjective,
            nickname: defaultNickname,
            persona: sections["persona", default: []].joined(separator: "\n"),
            speakCriteria: speak,
            buildCriteria: build,
            doNotBuildCriteria: doNot,
            projectSummary: sections["summary", default: []].joined(separator: "\n"),
            rawText: jsonText
        )
    }

    private func invalidFormat() -> IngestionError {
        // Deliberately omit the raw response: CLI errors can contain keys and private inputs.
        .invalidResponseFormat("有効な判断基準を読み取れませんでした。既存の基準を維持します。")
    }
}
