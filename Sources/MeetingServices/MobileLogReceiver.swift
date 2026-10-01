import Foundation
import Network
import MeetingCore

@MainActor
public final class MobileLogReceiver: ObservableObject {
    @Published public var isRunning = false
    @Published public var port: UInt16 = 8765
    @Published public var localIPAddress: String = "127.0.0.1"
    @Published public var receivedLogs: [String] = []
    @Published public var pairingPin: String = String(format: "%06d", arc4random_uniform(1_000_000))
    @Published public var pinExpiresAt: Date = Date().addingTimeInterval(300)
    @Published public var isPinLocked: Bool = false
    public var pairingToken: String { pairingPin }
    public private(set) var failedAttempts: Int = 0
    private var activeSessions: [String: Date] = [:] // sessionToken -> expiresAt
    public var sessionDuration: TimeInterval = 3600 // セッショントークン有効期間 (既定1時間)

    public var onLogReceived: ((String) -> Void)?
    public let maxLogBytes: Int = 65536
    public let maxLogsCount: Int = 100

    private var listener: NWListener?

    public init(port: UInt16 = 8765) {
        self.port = port
        self.localIPAddress = Self.resolveLocalIP()
        self.generateNewPin()
    }

    public func generateNewPin() {
        self.pairingPin = String(format: "%06d", arc4random_uniform(1_000_000))
        self.pinExpiresAt = Date().addingTimeInterval(300) // 5分間有効
        self.failedAttempts = 0
        self.isPinLocked = false
        // 新しいPINの生成時は古い全セッショントークンを失効させる
        self.activeSessions.removeAll()
    }

    public func regenerateToken() {
        generateNewPin()
    }

    /// 有効なセッショントークンかを検証（期限切れは自動破棄）
    public func isValidSessionToken(_ token: String) -> Bool {
        guard let expiresAt = activeSessions[token] else { return false }
        if Date() > expiresAt {
            activeSessions.removeValue(forKey: token)
            return false
        }
        return true
    }

    /// テスト用: 期限切れトークン等の注入
    public func addSessionTokenForTesting(_ token: String, expiresAt: Date) {
        activeSessions[token] = expiresAt
    }

    public func start() {
        guard !isRunning else { return }
        do {
            let parameters = NWParameters.tcp
            let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(8765)
            let newListener = try NWListener(using: parameters, on: nwPort)

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.localIPAddress = Self.resolveLocalIP()
                    case .failed(let error):
                        self?.isRunning = false
                        print("[MobileLogReceiver] Failed: \(error)")
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleConnection(connection)
                }
            }

            newListener.start(queue: .main)
            self.listener = newListener
            self.isRunning = true
            self.localIPAddress = Self.resolveLocalIP()
        } catch {
            print("[MobileLogReceiver] Start error: \(error)")
            isRunning = false
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        activeSessions.removeAll()
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        readRequest(connection: connection, accumulated: Data())
    }

    private func readRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var buffer = accumulated
                if let content { buffer.append(content) }

                // 最大許容バッファサイズを超えたら直ちに拒絶
                if buffer.count > self.maxLogBytes + 8192 {
                    self.sendResponse(connection: connection, status: "413 Payload Too Large", body: "Payload Too Large")
                    return
                }

                // HTTPリクエストヘッダーの区切りを確認
                if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
                    let bodyData = buffer.subdata(in: headerRange.upperBound..<buffer.count)
                    let headerString = String(decoding: headerData, as: UTF8.self)

                    // Content-Lengthヘッダーのパース
                    let expectedLength = self.parseContentLength(from: headerString)

                    if expectedLength > self.maxLogBytes {
                        self.sendResponse(connection: connection, status: "413 Payload Too Large", body: "Payload Too Large")
                        return
                    }

                    // Content-Length分に達していない場合、パケット分割中なのでさらに受信を待機
                    if bodyData.count < expectedLength {
                        if isComplete || error != nil {
                            // 受信途中で切断された不完全なリクエスト
                            self.sendResponse(connection: connection, status: "400 Bad Request", body: "Incomplete HTTP body")
                        } else {
                            self.readRequest(connection: connection, accumulated: buffer)
                        }
                        return
                    }

                    // 期待される長さのボディを切り出し
                    let exactBodyData = bodyData.prefix(expectedLength)
                    self.processHTTPRequest(headerString: headerString, bodyData: exactBodyData, connection: connection)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.readRequest(connection: connection, accumulated: buffer)
                }
            }
        }
    }

    private func parseContentLength(from headerString: String) -> Int {
        for line in headerString.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let len = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    return max(0, len)
                }
            }
        }
        return 0
    }

    private func processHTTPRequest(headerString: String, bodyData: Data, connection: NWConnection) {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Bad Request")
            return
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Bad Request")
            return
        }
        let method = parts[0]
        let fullPath = parts[1]
        let path = fullPath.components(separatedBy: "?").first ?? fullPath

        // ヘッダー（X-Meeting-Token または Authorization: Bearer）から認証トークンを検証
        let tokenFromHeader = parseTokenFromHeaders(lines: lines)

        if method == "GET" && (path == "/" || path == "/index.html") {
            // モバイル用試験Web UI（iPhone Safari等で開いた時）
            let html = mobileWebUI()
            sendResponse(connection: connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: html)
        } else if method == "POST" && path == "/api/pair" {
            // ペアリングエンドポイント: 短時間PINを検証し、長いセッショントークンを発行
            if self.isPinLocked || self.failedAttempts >= 5 {
                sendResponse(connection: connection, status: "403 Forbidden", contentType: "application/json", body: "{\"status\":\"error\",\"message\":\"PIN試行回数を超過しました。Mac側でPINを再生成してください。\"}")
                return
            }
            if Date() > self.pinExpiresAt {
                sendResponse(connection: connection, status: "401 Unauthorized", contentType: "application/json", body: "{\"status\":\"error\",\"message\":\"PINの有効期限（5分）が切れています。Mac側でPINを再生成してください。\"}")
                return
            }

            let isJson = lines.contains { $0.lowercased().contains("content-type: application/json") }
            var submittedPin = ""
            if isJson {
                if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                   let pinVal = json["pin"] as? String {
                    submittedPin = pinVal.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else if let rawString = String(data: bodyData, encoding: .utf8) {
                if rawString.hasPrefix("pin=") {
                    submittedPin = String(rawString.dropFirst(4)).removingPercentEncoding ?? String(rawString.dropFirst(4))
                }
            }

            if !submittedPin.isEmpty && submittedPin == self.pairingPin {
                self.failedAttempts = 0
                let sessionToken = UUID().uuidString.lowercased()
                self.activeSessions[sessionToken] = Date().addingTimeInterval(self.sessionDuration)
                if self.activeSessions.count > 20 {
                    let sorted = self.activeSessions.sorted { $0.value < $1.value }
                    for old in sorted.prefix(self.activeSessions.count - 20) {
                        self.activeSessions.removeValue(forKey: old.key)
                    }
                }
                let respJson = "{\"status\":\"ok\",\"token\":\"\(sessionToken)\"}"
                sendResponse(connection: connection, status: "200 OK", contentType: "application/json", body: respJson)
            } else {
                self.failedAttempts += 1
                if self.failedAttempts >= 5 {
                    self.isPinLocked = true
                    sendResponse(connection: connection, status: "403 Forbidden", contentType: "application/json", body: "{\"status\":\"error\",\"message\":\"PIN試行回数を超過しました。Mac側でPINを再生成してください。\"}")
                } else {
                    sendResponse(connection: connection, status: "401 Unauthorized", contentType: "application/json", body: "{\"status\":\"error\",\"message\":\"PINが正しくありません。残り試行回数: \(5 - self.failedAttempts)\"}")
                }
            }
        } else if method == "POST" && (path == "/api/log" || path == "/log") {
            // 認証チェック: 有効なセッショントークンのみ受け付ける（PINは一切認めない・期限切れも拒絶）
            guard let token = tokenFromHeader, self.isValidSessionToken(token) else {
                sendResponse(connection: connection, status: "401 Unauthorized", contentType: "application/json", body: "{\"status\":\"error\",\"message\":\"未認証またはセッション期限切れです。ペアリングを行ってください。\"}")
                return
            }

            // 件数上限チェック
            if self.receivedLogs.count >= self.maxLogsCount {
                sendResponse(connection: connection, status: "429 Too Many Requests", contentType: "application/json", body: "{\"status\":\"error\",\"message\":\"ログ上限（\(maxLogsCount)件）に達しています。\"}")
                return
            }

            // Content-Type に応じた厳格なパース
            let isJson = lines.contains { $0.lowercased().contains("content-type: application/json") }
            var logText = ""

            if isJson {
                guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                      let text = json["text"] as? String else {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "Invalid JSON body: expected {\"text\": \"...\"}")
                    return
                }
                logText = text
            } else if let rawString = String(data: bodyData, encoding: .utf8) {
                if rawString.hasPrefix("text=") {
                    let decoded = rawString.dropFirst(5).removingPercentEncoding ?? String(rawString.dropFirst(5))
                    logText = decoded.replacingOccurrences(of: "+", with: " ")
                } else {
                    logText = rawString
                }
            } else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "Invalid UTF-8 body")
                return
            }

            let trimmed = logText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self.receivedLogs.append(trimmed)
                self.onLogReceived?(trimmed)
                let respJson = "{\"status\":\"ok\",\"length\":\(trimmed.count)}"
                sendResponse(connection: connection, status: "200 OK", contentType: "application/json", body: respJson)
            } else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "Empty log")
            }
        } else {
            sendResponse(connection: connection, status: "404 Not Found", body: "Not Found")
        }
    }

    private func parseTokenFromHeaders(lines: [String]) -> String? {
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("x-meeting-token:") || lower.hasPrefix("x-token:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            } else if lower.hasPrefix("authorization:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let authVal = parts[1].trimmingCharacters(in: .whitespaces)
                    if authVal.lowercased().hasPrefix("bearer ") {
                        return String(authVal.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        return nil
    }

    private func parseQueryParameter(url: String, param: String) -> String? {
        guard let queryIndex = url.firstIndex(of: "?") else { return nil }
        let queryString = String(url[url.index(after: queryIndex)...])
        for pair in queryString.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 && kv[0] == param {
                return kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        return nil
    }

    private func sendResponse(connection: NWConnection, status: String, contentType: String = "text/plain; charset=utf-8", body: String) {
        let bodyData = Data(body.utf8)
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r\n
        """
        var responseData = Data(response.utf8)
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func mobileWebUI() -> String {
        """
        <!DOCTYPE html>
        <html lang="ja">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <title>iPhone ライフログ送信 · 会議の相棒</title>
          <style>
            * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
            body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 20px; }
            .container { max-width: 520px; margin: 0 auto; }
            h1 { font-size: 1.3rem; margin-bottom: 6px; font-weight: 700; color: #38bdf8; }
            p.desc { font-size: 0.85rem; color: #94a3b8; margin-top: 0; margin-bottom: 20px; line-height: 1.4; }
            textarea { width: 100%; height: 160px; background: #1e293b; border: 1px solid #334155; border-radius: 12px; color: #f8fafc; padding: 14px; font-size: 1rem; resize: none; outline: none; }
            textarea:focus { border-color: #38bdf8; }
            .btn-group { display: flex; gap: 10px; margin-top: 14px; }
            button { flex: 1; padding: 14px; font-size: 1rem; font-weight: 600; border-radius: 12px; border: none; cursor: pointer; transition: all 0.2s; }
            .btn-send { background: #0284c7; color: white; }
            .btn-send:active { background: #0369a1; transform: scale(0.98); }
            .btn-mic { background: #334155; color: #f8fafc; }
            .btn-mic.recording { background: #ef4444; color: white; animation: pulse 1.5s infinite; }
            .status { margin-top: 16px; padding: 12px; border-radius: 8px; font-size: 0.9rem; text-align: center; display: none; }
            .status.success { background: rgba(34, 197, 94, 0.2); color: #4ade80; display: block; }
            .status.error { background: rgba(239, 68, 68, 0.2); color: #f87171; display: block; }
            .tips { margin-top: 24px; padding: 14px; background: #1e293b; border-radius: 12px; font-size: 0.8rem; color: #94a3b8; }
            .tips strong { color: #e2e8f0; }
            @keyframes pulse { 0% { opacity: 1; } 50% { opacity: 0.7; } 100% { opacity: 1; } }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>🎙️ 試験用 iPhone 入力</h1>
            <p class="desc">胸ポケット録音・音声入力・メモをMacの「会議の相棒」へ送信する試験用Web画面です。</p>

            <div id="pairSection" style="margin-bottom: 16px; padding: 14px; background: #1e293b; border-radius: 12px;">
              <div style="font-size: 0.85rem; font-weight: 600; color: #38bdf8; margin-bottom: 8px;">Macと接続（6桁PINコード）</div>
              <div style="display: flex; gap: 8px;">
                <input type="text" id="pinInput" placeholder="Mac画面の6桁PIN" maxlength="6" style="flex: 1; padding: 10px; background: #0f172a; border: 1px solid #334155; border-radius: 8px; color: #f8fafc; font-size: 1.1rem; text-align: center; letter-spacing: 2px;">
                <button onclick="pairWithMac()" style="padding: 10px 16px; background: #0284c7; color: white; border-radius: 8px; border: none; font-weight: 600;">接続</button>
              </div>
              <div id="pairStatus" style="font-size: 0.75rem; color: #94a3b8; margin-top: 6px;"></div>
            </div>

            <textarea id="logInput" placeholder="ここにメモを入力、またはマイクボタンで話してください..."></textarea>

            <div class="btn-group">
              <button id="micBtn" class="btn-mic" onclick="toggleSpeech()">🎤 音声入力</button>
              <button class="btn-send" onclick="sendLog()">⚡️ Macへ送信</button>
            </div>

            <div id="statusBox" class="status"></div>
          </div>

          <script>
            let recognition = null;
            let isRecording = false;

            if ('webkitSpeechRecognition' in window || 'SpeechRecognition' in window) {
              const SpeechRec = window.SpeechRecognition || window.webkitSpeechRecognition;
              recognition = new SpeechRec();
              recognition.continuous = true;
              recognition.interimResults = true;
              recognition.lang = 'ja-JP';

              recognition.onresult = (event) => {
                let current = '';
                for (let i = event.resultIndex; i < event.results.length; ++i) {
                  current += event.results[i][0].transcript;
                }
                const input = document.getElementById('logInput');
                input.value = (input.value ? input.value + '\\n' : '') + current;
              };

              recognition.onerror = (e) => {
                console.error(e);
                stopSpeech();
              };
            }

            function toggleSpeech() {
              if (!recognition) {
                alert('お使いのブラウザは音声認識APIに対応していません。キーボードのマイクアイコンをご利用ください。');
                return;
              }
              if (isRecording) {
                stopSpeech();
              } else {
                try {
                  recognition.start();
                  isRecording = true;
                  const btn = document.getElementById('micBtn');
                  btn.classList.add('recording');
                  btn.innerText = '⏹️ 停止';
                } catch(e) { console.error(e); }
              }
            }

            function stopSpeech() {
              if (recognition && isRecording) {
                recognition.stop();
                isRecording = false;
                const btn = document.getElementById('micBtn');
                btn.classList.remove('recording');
                btn.innerText = '🎤 音声入力';
              }
            }

            async function pairWithMac() {
              const pin = document.getElementById('pinInput').value.trim();
              const pStatus = document.getElementById('pairStatus');
              if (!pin) { pStatus.innerText = 'PINを入力してください。'; return; }
              try {
                const res = await fetch('/api/pair', {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ pin: pin })
                });
                const data = await res.json();
                if (res.ok && data.token) {
                  sessionStorage.setItem('meeting_session_token', data.token);
                  pStatus.style.color = '#4ade80';
                  pStatus.innerText = '✅ 接続成功！';
                  document.getElementById('pinInput').value = '••••••';
                  document.getElementById('pinInput').disabled = true;
                } else {
                  pStatus.style.color = '#f87171';
                  pStatus.innerText = '❌ ' + (data.message || '接続に失敗しました');
                }
              } catch(e) {
                pStatus.style.color = '#f87171';
                pStatus.innerText = '❌ 通信エラー: ' + e.message;
              }
            }

            async function sendLog() {
              stopSpeech();
              const text = document.getElementById('logInput').value.trim();
              const statusBox = document.getElementById('statusBox');
              if (!text) {
                statusBox.className = 'status error';
                statusBox.innerText = 'テキストを入力してください。';
                return;
              }
              const token = sessionStorage.getItem('meeting_session_token');
              if (!token) {
                statusBox.className = 'status error';
                statusBox.innerText = '先にPINを入力してMacと接続してください。';
                return;
              }

              try {
                const res = await fetch('/api/log', {
                  method: 'POST',
                  headers: {
                    'Content-Type': 'application/json',
                    'X-Meeting-Token': token
                  },
                  body: JSON.stringify({ text: text })
                });
                if (res.ok) {
                  statusBox.className = 'status success';
                  statusBox.innerText = '✅ Macの「会議の相棒」に送信しました！';
                  document.getElementById('logInput').value = '';
                  setTimeout(() => { statusBox.style.display = 'none'; }, 4000);
                } else if (res.status === 401) {
                  sessionStorage.removeItem('meeting_session_token');
                  document.getElementById('pinInput').disabled = false;
                  throw new Error('認証に失敗しました。再接続してください。');
                } else {
                  throw new Error('サーバーエラー: ' + res.status);
                }
              } catch(e) {
                statusBox.className = 'status error';
                statusBox.innerText = '❌ 送信失敗: ' + e.message;
              }
            }
          </script>
        </body>
        </html>
        """
    }

    private static func resolveLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let name = String(cString: hostname)
                        if !name.hasPrefix("127.") {
                            address = name
                            break
                        }
                    }
                }
            }
        }
        return address
    }
}
