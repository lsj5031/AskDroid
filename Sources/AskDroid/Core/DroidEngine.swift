import Foundation

actor DroidEngine: EngineClient {
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
            engine: .droid,
            override: settings.droidPath,
            fileExists: fileExists
        ) else {
            throw EngineError.binaryNotFound(.droid)
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
            engine: .droid,
            initialActivity: "Opening a Droid session…",
            initializeSession: { process, session in
                let id = await session.registerRequest(as: .initialize)
                try process.write(try JSONRPC.encodeLine(JSONRPC.request(
                    id: id,
                    method: "droid.initialize_session",
                    params: Self.initializeParams(from: settings)
                )))
            },
            acceptTimeoutMessage: "Droid did not start a session in time.",
            turnTimeoutMessage: "Droid did not finish in 10 minutes.",
            isInitialAccepted: { await $0.didInitialize },
            isAuthError: { line in
                line.localizedCaseInsensitiveContains("not authenticated")
                    || line.localizedCaseInsensitiveContains("FACTORY_API_KEY")
                    || line.localizedCaseInsensitiveContains("invalid api key")
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
                onEvent(.activity(turn.turnID, "Sending your question…"))
                let id = await session.registerRequest(as: .userMessage)
                try process.write(try JSONRPC.encodeLine(JSONRPC.request(
                    id: id,
                    method: "droid.add_user_message",
                    params: Self.userMessageParams(from: turn.request)
                )))
                onEvent(.activity(turn.turnID, "Waiting for Droid…"))
                onEvent(.log(turn.turnID, "Question sent"))
                await turn.appendLog("Question sent")
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
            engine: .droid,
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
        if let process = await handle.process, let state = await handle.state {
            let id = await state.registerRequest(as: .interrupt)
            if let line = try? JSONRPC.encodeLine(JSONRPC.request(
                id: id,
                method: "droid.interrupt_session",
                params: [:]
            )) {
                try? process.write(line)
            }
        }
        // The turn ends locally; droid's acknowledgement is incidental. No
        // terminate() — the session stays usable.
        await handle.interruptCurrentTurn()
    }

    func reset(_ handle: SessionHandle) async {
        // Safe default: without a live probe of droid's reset semantics, a
        // fresh process is the only way to guarantee cleared context.
        _ = try? await handle.relaunch()
    }

    func close(_ handle: SessionHandle) async {
        if let process = await handle.process, let state = await handle.state {
            let id = await state.registerRequest(as: .closeSession)
            if let line = try? JSONRPC.encodeLine(JSONRPC.request(
                id: id,
                method: "droid.close_session",
                params: [:]
            )) {
                try? process.write(line)
            }
        }
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
        onEvent(.activity(runID, "Starting Droid…"))
        onEvent(.log(runID, "Looking for the droid CLI…"))

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

    /// Legacy cancel for one-shot runs: kills the process; the death watch
    /// classifies the turn as cancelled. Persistent sessions use
    /// `interrupt(_:)` instead, which keeps the session alive.
    func cancel(runID: UUID) async {
        guard let handle = legacyRuns[runID] else { return }
        legacyRuns[runID] = nil
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
        guard !trimmed.isEmpty, let message = try? JSONRPC.parse(trimmed) else { return }

        let turnID = turn.turnID

        if message["method"] as? String == "droid.request_permission",
           let id = stringID(message["id"])
        {
            writeResponse(process, id: id, result: ["selectedOption": "cancel"])
            return
        }

        if message["method"] as? String == "droid.ask_user",
           let id = stringID(message["id"])
        {
            writeResponse(process, id: id, result: ["cancelled": true, "answers": []])
            return
        }

        if let error = message["error"] as? [String: Any] {
            let detail = (error["message"] as? String) ?? "Droid request failed."
            onEvent(.log(turnID, detail))
            await turn.appendLog(detail)
            var fatal = true
            if let id = stringID(message["id"]), let kind = await session.requestKind(for: id) {
                await session.fulfillRequest(id: id)
                switch kind {
                case .contextStats, .interrupt, .closeSession:
                    // Bookkeeping requests must not tear down the session.
                    fatal = false
                case .initialize, .userMessage:
                    fatal = true
                }
            }
            if fatal {
                await turn.mark(error: detail)
                process.terminate()
            }
            return
        }

        // Responses correlate through the pending-request registry; ids are
        // monotonic, so no branch is pinned to a hardcoded id.
        if let id = stringID(message["id"]), let kind = await session.requestKind(for: id) {
            await session.fulfillRequest(id: id)
            switch kind {
            case .initialize:
                await session.markInitialized()
                if let result = message["result"] as? [String: Any] {
                    var modelId: String?
                    if let sessionObject = result["session"] as? [String: Any],
                       let settings = sessionObject["settings"] as? [String: Any]
                    {
                        modelId = settings["modelId"] as? String
                    }
                    if modelId == nil {
                        modelId = result["modelId"] as? String
                    }
                    if let modelId {
                        await session.setModel(modelId)
                        onEvent(.log(turnID, "Model \(modelId)"))
                    }
                }
                return
            case .userMessage:
                onEvent(.activity(turnID, "Droid is working…"))
                return
            case .contextStats, .interrupt, .closeSession:
                return
            }
        }

        // The turn is over; ignore stragglers. The reader keeps running for
        // the life of the process.
        if await turn.isEnded { return }

        switch DroidNotificationParser.parse(message) {
        case .assistantTextDelta(let text):
            await turn.append(text)
            onEvent(.textDelta(turnID, text))
        case .thinking(let text):
            onEvent(.thinking(turnID, text))
        case .toolCall(let name, let detail):
            let label = Self.activityLabel(for: name)
            onEvent(.activity(turnID, label))
            let line = detail.map { "\(label) \($0)" } ?? label
            onEvent(.log(turnID, line))
            await turn.appendLog(line)
        case .toolProgress(let name):
            let label = Self.activityLabel(for: name)
            onEvent(.activity(turnID, label))
        case .toolResult(let text):
            onEvent(.log(turnID, "→ \(text)"))
            await turn.appendLog("→ \(text)")
        case .tokenUsage(let usage):
            if let summary = usage.summary {
                onEvent(.activity(turnID, "Working… \(summary)"))
            }
        case .workingState(let state):
            let label = Self.workingLabel(for: state)
            onEvent(.activity(turnID, label))
            onEvent(.log(turnID, label))
            await turn.appendLog(label)
        case .milestone(let text):
            onEvent(.log(turnID, text))
            await turn.appendLog(text)
        case .error(let message):
            onEvent(.log(turnID, message))
            await turn.appendLog(message)
            await turn.mark(error: message)
            process.terminate()
        case .turnCompleted(let durationMs, let usage):
            if let durationMs {
                await turn.applyDuration(durationMs: durationMs)
            }
            if let usage {
                await turn.setUsage(usage)
            }
            // The turn ended. Ending a turn is a protocol event — it is not
            // process death (the handle owns the physical teardown). The
            // handle's endTurn performs the first-wins end and settles.
            await turnEnded(turn, .completed)
        case .ignored:
            // Unknown session_notification subtypes are noise; anything else with a
            // method name is worth surfacing for diagnostics.
            if let method = message["method"] as? String, method != "droid.session_notification" {
                let line = method.replacingOccurrences(of: "droid.", with: "")
                onEvent(.log(turnID, line))
                await turn.appendLog(line)
            }
        }
    }

    private func writeResponse(_ process: any ProcessIO, id: String, result: [String: Any]) {
        guard let encoded = try? JSONRPC.encodeLine(JSONRPC.response(id: id, result: result)) else { return }
        try? process.write(encoded)
    }

    private func stringID(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? Int { return String(value) }
        return nil
    }

    static func arguments(from settings: AppSettings) -> [String] {
        var arguments = [
            "exec",
            "--input-format", "stream-jsonrpc",
            "--output-format", "stream-jsonrpc",
        ]
        if let autonomy = settings.autonomy.protocolValue {
            arguments += ["--auto", autonomy]
        }
        if let model = settings.modelOverride.trimmedOrNil {
            arguments += ["--model", model]
        }
        if let reasoning = settings.reasoning.protocolValue {
            arguments += ["--reasoning-effort", reasoning]
        }
        return arguments
    }

    static func initializeParams(from settings: AppSettings) -> [String: Any] {
        var params: [String: Any] = [
            "machineId": "askdroid",
            "cwd": settings.resolvedWorkingDirectory,
            "autoRejectPermissionRequests": true,
        ]
        if let model = settings.modelOverride.trimmedOrNil {
            params["modelId"] = model
        }
        if let reasoning = settings.reasoning.protocolValue {
            params["reasoningEffort"] = reasoning
        }
        if let autonomy = settings.autonomy.protocolValue {
            params["autonomyLevel"] = autonomy
        }
        return params
    }

    static func userMessageParams(from request: EngineRequest) -> [String: Any] {
        var params: [String: Any] = [
            "text": request.prompt,
        ]
        if !request.images.isEmpty {
            params["images"] = request.images.map { image in
                [
                    "type": "base64",
                    "data": image.data.base64EncodedString(),
                    "mediaType": image.mediaType,
                ] as [String: Any]
            }
        }
        return params
    }

    static func activityLabel(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "read", "readfile", "read_file":
            "Reading files…"
        case "grep", "rg", "search", "search_files":
            "Searching…"
        case "glob", "ls", "list", "list_files":
            "Listing files…"
        case "execute", "execute-cli", "bash", "shell":
            "Running a command…"
        case "applypatch", "apply_patch", "edit", "write":
            "Editing…"
        case "web_search":
            "Searching the web…"
        default:
            toolName.isEmpty ? "Working…" : "Using \(toolName)…"
        }
    }

    static func workingLabel(for state: String) -> String {
        switch state.lowercased() {
        case "thinking": "Thinking…"
        case "generating": "Writing…"
        case "executing", "working": "Working…"
        case "idle": "Ready"
        default:
            state.replacingOccurrences(of: "_", with: " ").capitalized + "…"
        }
    }
}
