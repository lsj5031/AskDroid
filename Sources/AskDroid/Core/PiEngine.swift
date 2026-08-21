import Foundation

actor PiEngine: EngineClient {
    private let launcher: any ProcessLaunching
    private let fileExists: @Sendable (String) -> Bool
    /// The session established by `begin`. A new `begin` retires it — one
    /// live CLI per engine.
    private var activeHandle: SessionHandle?
    /// Legacy one-shot runs keyed by run id so `cancel(runID:)` keeps working.
    private var legacyRuns: [UUID: SessionHandle] = [:]

    init(
        launcher: any ProcessLaunching = FoundationProcessLauncher(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.launcher = launcher
        self.fileExists = fileExists
    }

    func begin(
        settings: AppSettings,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async throws -> SessionHandle {
        guard let executable = BinaryDiscovery.resolve(
            engine: .pi,
            override: settings.piPath,
            fileExists: fileExists
        ) else {
            throw EngineError.binaryNotFound(.pi)
        }

        let cwd = settings.resolvedWorkingDirectory
        try FileManager.default.createDirectory(
            atPath: cwd,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: settings.resolvedAnswersDirectory,
            withIntermediateDirectories: true
        )

        if let stale = activeHandle {
            activeHandle = nil
            await stale.terminateProcess()
        }

        let config = EngineProcessRunner.Configuration(
            engine: .pi,
            initialActivity: "Opening a Pi session…",
            initializeSession: { _, _ in
                // Pi has no initialization handshake; the process accepts
                // prompts as soon as it is running.
            },
            acceptTimeoutMessage: "Pi did not accept the prompt in time.",
            turnTimeoutMessage: "Pi did not finish in 10 minutes.",
            // Readiness is immediate; prompt acceptance is guarded by the
            // per-turn timer instead.
            isInitialAccepted: { _ in true },
            isAuthError: { line in
                line.localizedCaseInsensitiveContains("not authenticated")
                    || line.localizedCaseInsensitiveContains("auth_unavailable")
                    || line.localizedCaseInsensitiveContains("no auth available")
                    || line.localizedCaseInsensitiveContains("invalid api key")
                    || line.localizedCaseInsensitiveContains("missing api key")
            },
            handleLine: { [weak self] line, process, session, turn, turnEnded in
                await self?.handle(
                    line: line,
                    process: process,
                    session: session,
                    turn: turn,
                    turnEnded: turnEnded,
                    onEvent: onEvent
                )
            },
            composeTurnMessage: { process, session, turn in
                let id = await session.registerRequest(as: .userMessage)
                try process.write(try Self.encodeJSON(Self.promptParams(id: id, from: turn.request)))
                onEvent(.log(turn.turnID, "prompt sent"))
                onEvent(.activity(turn.turnID, "Waiting for Pi…"))
            },
            turnDidEnd: { process, _ in
                // Footer meta: ask for context fill after every settled turn.
                if let line = try? Self.encodeJSON(["type": "get_session_stats"]) {
                    try? process.write(line)
                }
            },
            onTurnEnd: { _, _ in
                // Engine-side bookkeeping (context stats) rides the runner's
                // turnDidEnd hook.
            },
            onProcessExit: { _ in
                // The handle owns exit bookkeeping; nothing engine-side to do.
            }
        )

        let handle = SessionHandle(
            engine: .pi,
            settings: settings,
            sink: onEvent,
            config: config,
            makeProcess: {
                try self.launcher.launch(
                    executable: executable,
                    arguments: Self.arguments(from: settings),
                    environment: EngineSupport.augmentedEnvironment(),
                    cwd: cwd
                )
            }
        )
        activeHandle = handle
        try await handle.open()
        onEvent(.sessionReady(handle, model: nil))
        return handle
    }

    func interrupt(_ handle: SessionHandle) async {
        if let line = try? Self.encodeJSON(["type": "abort"]) {
            try? await handle.writeLine(line)
        }
        // No terminate(): abort stops the turn, the process keeps running.
        await handle.interruptCurrentTurn()
    }

    func reset(_ handle: SessionHandle) async {
        // Verified against the CLI: new_session clears context in-process,
        // no relaunch needed.
        if let line = try? Self.encodeJSON(["type": "new_session"]) {
            try? await handle.writeLine(line)
        }
        await handle.clearConversationContext()
    }

    func close(_ handle: SessionHandle) async {
        await handle.shutdown()
        if activeHandle === handle { activeHandle = nil }
    }

    /// Legacy one-shot convenience: `begin` → one turn → `close`.
    func run(
        _ request: EngineRequest,
        runID: UUID = UUID(),
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async {
        onEvent(.started(runID))
        onEvent(.activity(runID, "Starting Pi…"))
        onEvent(.log(runID, "Looking for the pi CLI…"))

        do {
            let handle = try await begin(settings: request.settings, onEvent: onEvent)
            legacyRuns[runID] = handle
            await handle.send(request, turnID: runID, lifetime: .oneShot)
            legacyRuns[runID] = nil
            await close(handle)
        } catch is CancellationError {
            onEvent(.failed(runID, EngineError.cancelled.localizedDescription))
        } catch {
            onEvent(.failed(runID, error.localizedDescription))
        }
    }

    /// Legacy cancel for one-shot runs: abort, then kill the process. The
    /// abort-then-terminate race noted in plans/README.md only ever applied
    /// here; persistent sessions use `interrupt(_:)`, which never terminates.
    func cancel(runID: UUID) async {
        guard let handle = legacyRuns[runID] else { return }
        legacyRuns[runID] = nil
        if let line = try? Self.encodeJSON(["type": "abort"]) {
            try? await handle.writeLine(line)
        }
        await handle.terminateProcess()
    }

    private func handle(
        line: String,
        process: any ProcessIO,
        session: EngineSession,
        turn: TurnState,
        turnEnded: TurnEnder,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        let turnID = turn.turnID

        // Session-scoped responses can arrive after the turn ended (context
        // stats); dispatch them before the turn gates.
        if json["type"] as? String == "response",
           let command = json["command"] as? String,
           command != "prompt"
        {
            switch command {
            case "get_session_stats":
                // Per spec, contextUsage can be absent and its fields can be
                // null right after compaction — emit only when both fill in.
                if let data = json["data"] as? [String: Any],
                   let usage = data["contextUsage"] as? [String: Any],
                   let tokens = Self.statValue(usage["tokens"]),
                   let window = Self.statValue(usage["contextWindow"])
                {
                    onEvent(.contextStats(used: tokens, limit: window))
                }
                return
            case "new_session", "abort":
                return
            default:
                break // unknown commands fall through to the logged-failure path
            }
        }

        if await turn.lastError != nil { return }
        // The turn is over; ignore stragglers. The reader keeps running for
        // the life of the process.
        if await turn.isEnded { return }

        guard let type = json["type"] as? String else { return }

        switch type {
        case "response":
            let command = json["command"] as? String
            let success = json["success"] as? Bool ?? false
            if command == "prompt" {
                if success {
                    await session.markAccepted()
                    onEvent(.activity(turnID, "Pi is working…"))
                } else {
                    let error = (json["error"] as? String) ?? (json["message"] as? String) ?? "Pi rejected the prompt."
                    onEvent(.log(turnID, error))
                    await turn.appendLog(error)
                    await turn.mark(error: error)
                    process.terminate()
                }
            } else if !success {
                let error = (json["error"] as? String) ?? "Pi command failed."
                onEvent(.log(turnID, error))
                await turn.appendLog(error)
            }

        case "extension_error":
            let error = (json["error"] as? String) ?? "Extension error."
            onEvent(.log(turnID, error))
            await turn.appendLog(error)
            await turn.mark(error: error)
            process.terminate()

        case "auto_retry_start":
            let attempt = json["attempt"] as? Int ?? 1
            let maxAttempts = json["maxAttempts"] as? Int ?? 3
            let errMsg = json["errorMessage"] as? String ?? ""
            let line = "Retry \(attempt)/\(maxAttempts): \(errMsg)"
            onEvent(.log(turnID, line))
            await turn.appendLog(line)
            onEvent(.activity(turnID, "Retrying… (\(attempt)/\(maxAttempts))"))

        case "auto_retry_end":
            let success = json["success"] as? Bool ?? false
            if !success {
                let finalError = (json["finalError"] as? String) ?? (json["errorMessage"] as? String) ?? "Auto retry failed."
                onEvent(.log(turnID, finalError))
                await turn.appendLog(finalError)
                if finalError.localizedCaseInsensitiveContains("auth_unavailable")
                    || finalError.localizedCaseInsensitiveContains("no auth available")
                    || finalError.localizedCaseInsensitiveContains("not authenticated")
                {
                    await turn.mark(error: EngineError.notAuthenticated(Engine.pi).localizedDescription)
                } else {
                    await turn.mark(error: finalError)
                }
                process.terminate()
            }

        case "agent_start", "turn_start":
            onEvent(.activity(turnID, "Pi is working…"))

        case "message_start", "message_end", "turn_end":
            if let msg = json["message"] as? [String: Any],
               msg["role"] as? String == "assistant"
            {
                if let model = msg["model"] as? String, !model.isEmpty {
                    await session.setModel(model)
                }
                if let usageDict = msg["usage"] as? [String: Any],
                   let usage = Self.tokenUsage(from: usageDict)
                {
                    await turn.setUsage(usage)
                }
                if let stopReason = msg["stopReason"] as? String, stopReason == "error" {
                    let errMsg = (msg["errorMessage"] as? String) ?? "Model error occurred."
                    onEvent(.log(turnID, errMsg))
                    await turn.appendLog(errMsg)
                    await turn.mark(error: errMsg)
                    process.terminate()
                }
            }

        case "message_update":
            if let usageDict = json["usage"] as? [String: Any],
               let usage = Self.tokenUsage(from: usageDict)
            {
                await turn.setUsage(usage)
            }
            if let assistantEvent = json["assistantMessageEvent"] as? [String: Any],
               let eventType = assistantEvent["type"] as? String
            {
                switch eventType {
                case "text_delta":
                    if let delta = assistantEvent["delta"] as? String, !delta.isEmpty {
                        await turn.append(delta)
                        onEvent(.textDelta(turnID, delta))
                    }
                case "thinking_delta":
                    if let delta = assistantEvent["delta"] as? String, !delta.isEmpty {
                        onEvent(.thinking(turnID, delta))
                    }
                default:
                    break
                }
            }

        case "tool_execution_start":
            let toolName = (json["toolName"] as? String) ?? "tool"
            let label = Self.activityLabel(for: toolName)
            onEvent(.activity(turnID, label))
            if let args = json["args"] as? [String: Any],
               let detail = Self.toolDetail(from: args)
            {
                let line = "\(label) \(detail)"
                onEvent(.log(turnID, line))
                await turn.appendLog(line)
            } else {
                onEvent(.log(turnID, label))
                await turn.appendLog(label)
            }

        case "tool_execution_update":
            let toolName = (json["toolName"] as? String) ?? "tool"
            let label = Self.activityLabel(for: toolName)
            onEvent(.activity(turnID, label))

        case "tool_execution_end":
            if let isError = json["isError"] as? Bool, isError {
                onEvent(.log(turnID, "Tool execution error"))
                await turn.appendLog("Tool execution error")
            }

        case "agent_end":
            if let messages = json["messages"] as? [[String: Any]] {
                for msg in messages where msg["role"] as? String == "assistant" {
                    if let model = msg["model"] as? String, !model.isEmpty {
                        await session.setModel(model)
                    }
                    if let usageDict = msg["usage"] as? [String: Any],
                       let usage = Self.tokenUsage(from: usageDict)
                    {
                        await turn.setUsage(usage)
                    }
                }
            }

        case "agent_settled":
            // The real turn boundary. `agent_end` above is only one low-level
            // run; retries and compaction may follow it before this point.
            // The handle's endTurn performs the first-wins end and settles.
            if await turn.lastError == nil {
                await turnEnded(turn, .completed)
            } else {
                await turnEnded(turn, .failed)
            }

        case "extension_ui_request":
            if let id = json["id"] as? String,
               let method = json["method"] as? String,
               ["select", "confirm", "input", "editor"].contains(method)
            {
                let resp: [String: Any] = ["type": "extension_ui_response", "id": id, "cancelled": true]
                if let payload = try? Self.encodeJSON(resp) {
                    try? process.write(payload)
                }
            }

        default:
            break
        }
    }

    static func arguments(from settings: AppSettings) -> [String] {
        var arguments = [
            "--mode", "rpc",
            "--no-session",
        ]
        if let model = settings.modelOverride.trimmedOrNil {
            arguments += ["--model", model]
        }
        if let thinking = settings.reasoning.piProtocolValue {
            arguments += ["--thinking", thinking]
        }
        return arguments
    }

    static func promptParams(id: String, from request: EngineRequest) -> [String: Any] {
        var params: [String: Any] = [
            "id": id,
            "type": "prompt",
            "message": request.prompt,
        ]
        if !request.images.isEmpty {
            params["images"] = request.images.map { image in
                [
                    "type": "image",
                    "data": image.data.base64EncodedString(),
                    "mimeType": image.mediaType,
                ] as [String: Any]
            }
        }
        return params
    }

    static func encodeJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else {
            throw EngineError.protocolFailure("Could not encode JSON line.")
        }
        return line
    }

    static func activityLabel(for toolName: String) -> String {
        EngineSupport.activityLabel(for: toolName)
    }

    static func toolDetail(from input: [String: Any]) -> String? {
        for key in ["command", "path", "file_path", "filePath", "pattern", "query", "url", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                return truncate(value, limit: 120)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8)
        {
            return truncate(text, limit: 120)
        }
        return nil
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)) + "…"
    }

    static func tokenUsage(from value: Any?) -> TokenUsage? {
        guard let object = value as? [String: Any] else { return nil }
        return TokenUsage(
            inputTokens: intValue(object["inputTokens"] ?? object["input"]),
            outputTokens: intValue(object["outputTokens"] ?? object["output"])
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        return nil
    }

    private static func statValue(_ value: Any?) -> Int? {
        intValue(value)
    }
}
