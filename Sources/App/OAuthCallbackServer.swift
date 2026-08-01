import Foundation
import Network

/// One-shot HTTP listener that catches the OAuth browser redirect
/// `GET /callback?code=…&state=…` on 127.0.0.1.
///
/// Port 54545 is the localhost redirect Claude Code registered for this
/// client id, so claude.ai redirects the browser here after login and the
/// whole flow completes with zero copy-paste — the "이 코드를 CLI에 붙여넣으세요"
/// page users hit with the console-callback flow never appears. If the port
/// can't be bound (e.g. Claude Code is mid-login), callers fall back to the
/// manual code-paste flow.
final class OAuthCallbackServer {
    static let port: UInt16 = 54545
    static var redirectURI: String { "http://localhost:\(port)/callback" }

    private var listener: NWListener?

    /// `onReady` fires once the port is bound (open the browser then);
    /// `onFail` when binding fails; `onCode` with the redirect's code/state.
    /// All callbacks arrive on the main queue.
    func start(onReady: @escaping () -> Void,
               onFail: @escaping () -> Void,
               onCode: @escaping (_ code: String, _ state: String?) -> Void) {
        stop()
        guard let port = NWEndpoint.Port(rawValue: Self.port),
              let l = try? NWListener(using: .tcp, on: port) else {
            DispatchQueue.main.async { onFail() }
            return
        }
        listener = l

        var announced = false
        l.stateUpdateHandler = { state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    if !announced { announced = true; onReady() }
                case .failed, .cancelled:
                    if !announced { announced = true; onFail() }
                default:
                    break
                }
            }
        }
        l.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let (status, body, values) = Self.route(request)
                let response = "HTTP/1.1 \(status)\r\n"
                    + "Content-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.utf8.count)\r\n"
                    + "Connection: close\r\n\r\n"
                    + body
                conn.send(content: Data(response.utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
                if let values {
                    DispatchQueue.main.async { onCode(values.code, values.state) }
                }
            }
        }
        l.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Request routing

    private static func route(_ request: String)
        -> (status: String, body: String, values: (code: String, state: String?)?) {
        guard let line = request.components(separatedBy: "\r\n").first,
              line.hasPrefix("GET ") else {
            return ("400 Bad Request", html("잘못된 요청입니다."), nil)
        }
        let target = String(line.dropFirst(4)).components(separatedBy: " ").first ?? ""
        guard let comps = URLComponents(string: target), comps.path == "/callback" else {
            return ("404 Not Found", html("찾을 수 없습니다."), nil)
        }
        let items = comps.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            let reason = items.first(where: { $0.name == "error" })?.value ?? "코드 없음"
            return ("200 OK", html("로그인이 완료되지 않았습니다 (\(reason)). 앱에서 다시 시도해주세요."), nil)
        }
        let state = items.first(where: { $0.name == "state" })?.value
        return ("200 OK", html("연결 완료! 이 탭을 닫고 AI 노동청으로 돌아가세요."), (code, state))
    }

    private static func html(_ message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>AI 노동청</title></head>
        <body style="font-family:-apple-system,sans-serif;display:flex;align-items:center;\
        justify-content:center;height:90vh;margin:0"><h2>\(message)</h2></body></html>
        """
    }
}
