import Foundation

actor DroidEngine: EngineClient {
    private let launcher: any ProcessLaunching
    private let fileExists: @Sendable (String) -> Bool
    private var activeProcess: (runID: UUID, process: any ProcessIO)?

    init(
        launcher: any ProcessLaunching = FoundationProcessLauncher(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.launcher = launcher
        self.fileExists = fileExists
    }

    func cancel(runID: UUID) {
        guard let active = activeProcess, active.runID == runID else { return }
        active.process.terminate()
        activeProcess = nil
    }

    func run(
        _ request: EngineRequest,
        runID: UUID = UUID(),
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async {
        onEvent(.started(runID))
        onEvent(.activity(runID, "Starting Droid…"))
        onEvent(.log(runID, "Looking for the droid CLI…"))

        guard let executable = BinaryDiscovery.resolve(
            engine: .droid,
            override: request.settings.droidPath,
            fileExists: fileExists
        ) else {
            onEvent(.failed(runID, EngineError.binaryNotFound(Engine.droid).localizedDescription))
            return
        }
        onEvent(.log(runID, "Using \(executable)"))

        do {
            var arguments = [
                "exec",
                "--input-format", "stream-jsonrpc",
                "--output-format", "stream-jsonrpc",
            ]
            if let autonomy = request.settings.autonomy.protocolValue {
                arguments += ["--auto", autonomy]
            }
            if let model = request.settings.modelOverride.trimmedOrNil {
                arguments += ["--model", model]
            }
            if let reasoning = request.settings.reasoning.protocolValue {
                arguments += ["--reasoning-effort", reasoning]
            }

            let cwd = request.settings.resolvedWorkingDirectory
            try FileManager.default.createDirectory(
                atPath: cwd,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: request.settings.resolvedAnswersDirectory,
                withIntermediateDirectories: true
            )

            let process = try launcher.launch(
                executable: executable,
                arguments: arguments,
                environment: EngineSupport.augmentedEnvironment(),
                cwd: cwd
            )
            if let stale = activeProcess {
                stale.process.terminate()
            }
            activeProcess = (runID, process)

            let config = EngineProcessRunner.Configuration(
                engine: .droid,
                initialActivity: "Opening a Droid session…",
                sendInitialMessage: { process, _ in
                    try process.write(try JSONRPC.encodeLine(JSONRPC.request(
                        id: "1",
                        method: "droid.initialize_session",
                        params: Self.initializeParams(from: request.settings)
                    )))
                    onEvent(.log(runID, "initialize_session sent"))
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
                        turnID: runID,
                        onEvent: onEvent
                    )
                },
                onTurnEnd: { _, _ in
                    // Engine-side bookkeeping lands with the persistent lifecycle.
                },
                onProcessExit: { [weak self] _ in
                    await self?.clearActiveProcess(runID: runID)
                }
            )

            await EngineProcessRunner.run(process: process, request: request, turnID: runID, config: config, onEvent: onEvent)
            if activeProcess?.runID == runID {
                activeProcess = nil
            }
        } catch is CancellationError {
            if activeProcess?.runID == runID {
                activeProcess?.process.terminate()
                activeProcess = nil
            }
            onEvent(.failed(runID, EngineError.cancelled.localizedDescription))
        } catch {
            if activeProcess?.runID == runID {
                activeProcess = nil
            }
            onEvent(.failed(runID, error.localizedDescription))
        }
    }

    private func clearActiveProcess(runID: UUID) {
        if activeProcess?.runID == runID {
            activeProcess = nil
        }
    }

    private func handle(
        line: String,
        process: any ProcessIO,
        session: EngineSession,
        turn: TurnState,
        turnEnded: TurnEnder,
        turnID: UUID,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let message = try? JSONRPC.parse(trimmed) else { return }

        // The turn is over; ignore stragglers. The reader keeps running for
        // the life of the process.
        if await turn.isEnded { return }

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
            await turn.mark(error: detail)
            process.terminate()
            return
        }

        if stringID(message["id"]) == "1" {
            if await session.didInitialize { return }
            await session.markInitialized()
            if let result = message["result"] as? [String: Any] {
                if let sessionObject = result["session"] as? [String: Any],
                   let settings = sessionObject["settings"] as? [String: Any],
                   let modelId = settings["modelId"] as? String
                {
                    await session.setModel(modelId)
                    onEvent(.log(turnID, "Model \(modelId)"))
                } else if let modelId = result["modelId"] as? String {
                    await session.setModel(modelId)
                    onEvent(.log(turnID, "Model \(modelId)"))
                }
            }
            onEvent(.activity(turnID, "Sending your question…"))
            do {
                try process.write(try JSONRPC.encodeLine(JSONRPC.request(
                    id: "2",
                    method: "droid.add_user_message",
                    params: Self.userMessageParams(from: turn.request)
                )))
                onEvent(.activity(turnID, "Waiting for Droid…"))
                onEvent(.log(turnID, "Question sent"))
                await turn.appendLog("Question sent")
            } catch {
                await turn.mark(error: error.localizedDescription)
                process.terminate()
            }
            return
        }

        if stringID(message["id"]) == "2" {
            onEvent(.activity(turnID, "Droid is working…"))
            return
        }

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
            // The turn ended. Ending a turn is a protocol event — it is not
            // process death (the runner owns the physical teardown).
            if await turn.end(.completed, tokenUsage: usage) {
                await turnEnded(turn, .completed)
            }
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
