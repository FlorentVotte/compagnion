import Foundation
import Network

/// One event forwarded by a Claude Code lifecycle hook
/// (https://code.claude.com/docs/en/hooks). Every field except
/// `hookEventName` is optional: the exact payload shape differs between
/// event types and has drifted across Claude Code versions.
struct HookEvent: Decodable, Sendable {
    let hookEventName: String      // "hook_event_name"
    let sessionId: String?         // "session_id"
    let transcriptPath: String?    // "transcript_path"
    let cwd: String?
    let toolName: String?          // "tool_name"
    let message: String?           // present on Notification events
    let notificationType: String?  // "notification_type" if present
}

/// One statusline refresh forwarded by the user's `statusLine` command
/// (https://code.claude.com/docs/en/statusline). All fields optional; only
/// what's actually present in the installed Claude Code version is filled.
struct StatuslineUpdate: Decodable, Sendable {
    struct ContextWindow: Decodable, Sendable {
        let usedPercentage: Double?
        let contextWindowSize: Int?
        let totalInputTokens: Int?
    }
    struct RateLimitWindow: Decodable, Sendable {
        let usedPercentage: Double?   // 0–100 (the binary sends utilization*100)
        let resetsAt: Date?

        private enum CodingKeys: String, CodingKey {
            case usedPercentage, resetsAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercentage = try? container.decode(Double.self, forKey: .usedPercentage)
            // Verified in the 2.1.220 binary: `resets_at` is Unix epoch
            // seconds (a JSON number). A string here would previously fail
            // the decode of the ENTIRE statusline payload, dropping context
            // and limits alike — so accept both shapes and never throw.
            if let epoch = try? container.decode(Double.self, forKey: .resetsAt) {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let string = try? container.decode(String.self, forKey: .resetsAt) {
                resetsAt = Self.parseISO(string)
            } else {
                resetsAt = nil
            }
        }

        private static func parseISO(_ string: String) -> Date? {
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return withFractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
    }
    struct RateLimits: Decodable, Sendable {
        let fiveHour: RateLimitWindow?
        let sevenDay: RateLimitWindow?
    }
    let sessionId: String?
    let cwd: String?
    let contextWindow: ContextWindow?
    let rateLimits: RateLimits?
}

/// A decoded `POST /event` body, discriminated by which top-level key is
/// present (`hook_event_name` vs `context_window`).
enum CompagnionEvent: Sendable {
    case hook(HookEvent)
    case statusline(StatuslineUpdate)
}

/// Max accepted request size (headers + body). Guards against a misbehaving
/// or abusive local client filling memory.
private let maxRequestBytes = 1_048_576

/// How long a connection may sit without completing a full request before
/// it's cancelled, to reap half-open sockets.
private let connectionIdleSeconds: TimeInterval = 10

/// Delay before EventListener retries a single time after a bind failure
/// (e.g. port already in use by a previous instance that hasn't exited yet).
private let retryDelaySeconds: TimeInterval = 2

/// No-op unless `COMPAGNION_DEBUG` is set in the environment — avoids print
/// spam from a listener that receives a hook POST on every tool call.
private func log(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["COMPAGNION_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data(("[EventListener] " + message() + "\n").utf8))
}

/// Decodes a raw HTTP body into a `CompagnionEvent`. Returns nil (log and
/// drop) for anything that isn't recognizable JSON — a decode failure here
/// must never crash the listener.
private func decodeCompagnionEvent(_ body: Data) -> CompagnionEvent? {
    guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
        log("body is not a JSON object (\(body.count) bytes)")
        return nil
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    if object["hook_event_name"] != nil {
        guard let hook = try? decoder.decode(HookEvent.self, from: body) else {
            log("failed to decode HookEvent")
            return nil
        }
        return .hook(hook)
    }

    if object["context_window"] != nil {
        guard var statusline = try? decoder.decode(StatuslineUpdate.self, from: body) else {
            log("failed to decode StatuslineUpdate")
            return nil
        }
        // Some Claude Code versions nest the id under `session.id` instead
        // of a top-level `session_id`. Small, self-contained fallback dig.
        if statusline.sessionId == nil,
           let session = object["session"] as? [String: Any],
           let nestedId = session["id"] as? String {
            statusline = StatuslineUpdate(
                sessionId: nestedId,
                cwd: statusline.cwd,
                contextWindow: statusline.contextWindow,
                rateLimits: statusline.rateLimits
            )
        }
        return .statusline(statusline)
    }

    log("dropped event: no hook_event_name or context_window key")
    return nil
}

/// A parsed HTTP/1.1 request line + enough body bytes to satisfy
/// Content-Length. Headers beyond Content-Length are not retained — nothing
/// else is needed.
private struct ParsedRequest {
    let method: String
    let path: String
    let body: Data
}

/// Looks for a header (case-insensitive) among raw header lines.
private func headerValue(named name: String, in lines: [Substring]) -> String? {
    let prefix = (name + ":").lowercased()
    for line in lines {
        if line.lowercased().hasPrefix(prefix) {
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

/// Outcome of trying to parse the bytes accumulated so far.
private enum ParseOutcome {
    /// More bytes are needed (headers not yet terminated, or body not yet
    /// fully arrived) — the caller keeps reading.
    case incomplete
    /// The request can never become valid (malformed request line, non-UTF-8
    /// headers, negative or oversized Content-Length) — answer 400 and close.
    case invalid
    case request(ParsedRequest)
}

private func parseHTTPRequest(_ buffer: Data) -> ParseOutcome {
    guard let terminatorRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
    guard let headerText = String(data: buffer[..<terminatorRange.lowerBound], encoding: .utf8) else {
        return .invalid
    }

    let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
    guard let requestLine = lines.first else { return .invalid }
    let requestParts = requestLine.split(separator: " ")
    guard requestParts.count >= 2 else { return .invalid }
    let method = String(requestParts[0])
    let path = String(requestParts[1])

    let contentLength = headerValue(named: "Content-Length", in: Array(lines.dropFirst())).flatMap(Int.init) ?? 0
    // A negative value would form an invalid body range below (crash); an
    // oversized one can never complete within `maxRequestBytes`.
    guard contentLength >= 0, contentLength <= maxRequestBytes else { return .invalid }

    let bodyStart = terminatorRange.upperBound
    let availableBodyBytes = buffer.distance(from: bodyStart, to: buffer.endIndex)
    guard availableBodyBytes >= contentLength else { return .incomplete }

    let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
    return .request(ParsedRequest(method: method, path: path, body: Data(buffer[bodyStart..<bodyEnd])))
}

/// Per-connection read buffer. Touched only serially, on the connection's
/// own callback chain on `EventListener`'s dispatch queue; marked unchecked
/// because that single-queue discipline isn't visible to the compiler.
private final class RequestState: @unchecked Sendable {
    var buffer = Data()
    var finished = false
}

/// Tiny local HTTP listener for Claude Code hook events and statusline
/// updates. Binds `127.0.0.1` only, speaks just enough HTTP/1.1 to accept
/// `POST /event` and reject everything else. Never blocks a socket on
/// consumer work: it responds first, then hands the decoded event to
/// `onEvent` on the main actor.
@MainActor
final class EventListener: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var lastEventAt: Date?
    @Published private(set) var lastError: String?
    let port: UInt16

    /// Always invoked on the main actor.
    var onEvent: ((CompagnionEvent) -> Void)?

    private var listener: NWListener?
    private var hasRetriedAfterFailure = false
    private let queue = DispatchQueue(label: "com.compagnion.eventlistener")

    init(port: UInt16 = 48765) {
        self.port = port
    }

    /// Idempotent: does nothing if already listening (or already trying to).
    func start() {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "invalid port \(port)"
            return
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        parameters.allowLocalEndpointReuse = true

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            lastError = "failed to create listener: \(error.localizedDescription)"
            log("NWListener creation failed: \(error)")
            return
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handleStateUpdate(state) }
        }

        listener = newListener
        newListener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func handleStateUpdate(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
            lastError = nil
            hasRetriedAfterFailure = false
            log("listening on 127.0.0.1:\(port)")
        case .failed(let error):
            isListening = false
            lastError = "listener failed: \(error.localizedDescription)"
            log("listener failed: \(error)")
            listener?.cancel()
            listener = nil
            if !hasRetriedAfterFailure {
                hasRetriedAfterFailure = true
                queue.asyncAfter(deadline: .now() + retryDelaySeconds) { [weak self] in
                    Task { @MainActor in self?.start() }
                }
            }
        case .cancelled:
            isListening = false
        default:
            break
        }
    }

    // MARK: - Connection handling (runs on `queue`, off the main actor)

    nonisolated private func accept(_ connection: NWConnection) {
        let state = RequestState()

        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .failed, .cancelled:
                state.finished = true
            default:
                break
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + connectionIdleSeconds) {
            if !state.finished {
                state.finished = true
                connection.cancel()
            }
        }

        receiveMore(connection, state)
    }

    nonisolated private func receiveMore(_ connection: NWConnection, _ state: RequestState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard !state.finished else { return }

            if let data, !data.isEmpty {
                state.buffer.append(data)
            }

            if state.buffer.count > maxRequestBytes {
                state.finished = true
                self.respond(connection, status: "413 Payload Too Large", body: Data())
                return
            }

            if error != nil {
                state.finished = true
                connection.cancel()
                return
            }

            switch parseHTTPRequest(state.buffer) {
            case .request(let request):
                state.finished = true
                self.handle(request: request, connection: connection)
                return
            case .invalid:
                state.finished = true
                self.respond(connection, status: "400 Bad Request", body: Data())
                return
            case .incomplete:
                break
            }

            if isComplete {
                state.finished = true
                connection.cancel()
                return
            }

            self.receiveMore(connection, state)
        }
    }

    nonisolated private func handle(request: ParsedRequest, connection: NWConnection) {
        guard request.method == "POST", request.path == "/event" else {
            respond(connection, status: "404 Not Found", body: Data())
            return
        }

        // Respond immediately/independently of dispatching the event —
        // never let a slow consumer hold the socket open.
        respond(connection, status: "200 OK", body: Data("{}".utf8))

        guard let event = decodeCompagnionEvent(request.body) else { return }
        // Log the success path too: without this, "nothing in the log" is
        // ambiguous between "no events arriving" and "everything working",
        // which is exactly the wrong thing to be unsure about while
        // debugging an integration.
        switch event {
        case .hook(let hook):
            log("hook \(hook.hookEventName) session=\(hook.sessionId ?? "?") tool=\(hook.toolName ?? "-")")
        case .statusline(let update):
            log("statusline session=\(update.sessionId ?? "?") context=\(update.contextWindow?.usedPercentage.map { "\($0)%" } ?? "-") limits=\(update.rateLimits != nil)")
        }
        Task { @MainActor in
            self.lastEventAt = Date()
            self.onEvent?(event)
        }
    }

    nonisolated private func respond(_ connection: NWConnection, status: String, body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var responseData = Data(head.utf8)
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
