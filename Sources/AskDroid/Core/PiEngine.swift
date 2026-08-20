import Foundation

actor PiEngine: EngineClient {
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
        if let abortPayload = try? JSONSerialization.data(withJSONObject: ["type": "abort"]),
           let abortLine = String(data: abortPayload, encoding: .utf8)
        {
            try? active.process.write(abortLine)
        }
        active.process.terminate()
        activeProcess = nil
    }

    func run(
        _ request: EngineRequest,
        runID: UUID = UUID(),
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async {
        onEvent(.started(runID))
        onEvent(.activity(runID, "Starting Pi…"))
        onEvent(.log(runID, "Looking for the pi CLI…"))

        guard let executable = BinaryDiscovery.resolve(
            engine: .pi,
            override: request.settings.piPath,
            fileExists: fileExists
        ) else {
            onEvent(.failed(runID, EngineError.binaryNotFound(Engine.pi).localizedDescription))
            return
        }
        onEvent(.log(runID, "Using \(executable)"))

        do {
            var arguments = [
                "--mode", "rpc",
                "--no-session",
            ]
            if let model = request.settings.modelOverride.trimmedOrNil {
                arguments += ["--model", model]
            }
            if let thinking = request.settings.reasoning.piProtocolValue {
                arguments += ["--thinking", thinking]
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
                engine: .pi,
                request: request,
                runID: runID,
                initialActivity: "Opening a Pi session…",
                sendInitialMessage: { process, session in
                    let promptPayload = Self.promptParams(from: request)
                    let promptLine = try Self.encodeJSON(promptPayload)
                    try process.write(promptLine)
                    await session.markPromptSent()
                    onEvent(.log(runID, "prompt sent"))
                    onEvent(.activity(runID, "Waiting for Pi…"))
                },
                acceptTimeoutMessage: "Pi did not accept the prompt in time.",
                turnTimeoutMessage: "Pi did not finish in 10 minutes.",
                isInitialAccepted: { await $0.didAccept },
                isAuthError: { line in
                    line.localizedCaseInsensitiveContains("not authenticated")
                        || line.localizedCaseInsensitiveContains("auth_unavailable")
                        || line.localizedCaseInsensitiveContains("no auth available")
                        || line.localizedCaseInsensitiveContains("invalid api key")
                        || line.localizedCaseInsensitiveContains("missing api key")
                },
                handleLine: { [weak self] line, process, session in
                    await self?.handle(line: line, process: process, session: session, runID: runID, onEvent: onEvent)
                }
            )

            await EngineProcessRunner.run(process: process, config: config, onEvent: onEvent)
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

    private func handle(
        line: String,
        process: any ProcessIO,
        session: RunSession,
        runID: UUID,
        onEvent: @escaping @Sendable (EngineEvent) -> Void
    ) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        if await session.lastError != nil { return }
        if await session.isFinished { return }

        guard let type = json["type"] as? String else { return }

        switch type {
        case "response":
            let command = json["command"] as? String
            let success = json["success"] as? Bool ?? false
            if command == "prompt" {
                if success {
                    await session.markAccepted()
                    onEvent(.activity(runID, "Pi is working…"))
                } else {
                    let error = (json["error"] as? String) ?? (json["message"] as? String) ?? "Pi rejected the prompt."
                    onEvent(.log(runID, error))
                    await session.mark(error: error)
                    process.terminate()
                }
            } else if !success {
                let error = (json["error"] as? String) ?? "Pi command failed."
                onEvent(.log(runID, error))
            }

        case "extension_error":
            let error = (json["error"] as? String) ?? "Extension error."
            onEvent(.log(runID, error))
            await session.mark(error: error)
            process.terminate()

        case "auto_retry_start":
            let attempt = json["attempt"] as? Int ?? 1
            let maxAttempts = json["maxAttempts"] as? Int ?? 3
            let errMsg = json["errorMessage"] as? String ?? ""
            onEvent(.log(runID, "Retry \(attempt)/\(maxAttempts): \(errMsg)"))
            onEvent(.activity(runID, "Retrying… (\(attempt)/\(maxAttempts))"))

        case "auto_retry_end":
            let success = json["success"] as? Bool ?? false
            if !success {
                let finalError = (json["finalError"] as? String) ?? (json["errorMessage"] as? String) ?? "Auto retry failed."
                onEvent(.log(runID, finalError))
                if finalError.localizedCaseInsensitiveContains("auth_unavailable")
                    || finalError.localizedCaseInsensitiveContains("no auth available")
                    || finalError.localizedCaseInsensitiveContains("not authenticated")
                {
                    await session.mark(error: EngineError.notAuthenticated(Engine.pi).localizedDescription)
                } else {
                    await session.mark(error: finalError)
                }
                process.terminate()
            }

        case "agent_start", "turn_start":
            onEvent(.activity(runID, "Pi is working…"))

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
                    await session.setUsage(usage)
                }
                if let stopReason = msg["stopReason"] as? String, stopReason == "error" {
                    let errMsg = (msg["errorMessage"] as? String) ?? "Model error occurred."
                    onEvent(.log(runID, errMsg))
                    await session.mark(error: errMsg)
                    process.terminate()
                }
            }

        case "message_update":
            if let usageDict = json["usage"] as? [String: Any],
               let usage = Self.tokenUsage(from: usageDict)
            {
                await session.setUsage(usage)
            }
            if let assistantEvent = json["assistantMessageEvent"] as? [String: Any],
               let eventType = assistantEvent["type"] as? String
            {
                switch eventType {
                case "text_delta":
                    if let delta = assistantEvent["delta"] as? String, !delta.isEmpty {
                        await session.append(delta)
                        onEvent(.textDelta(runID, delta))
                    }
                case "thinking_delta":
                    if let delta = assistantEvent["delta"] as? String, !delta.isEmpty {
                        onEvent(.thinking(runID, delta))
                    }
                default:
                    break
                }
            }

        case "tool_execution_start":
            let toolName = (json["toolName"] as? String) ?? "tool"
            let label = Self.activityLabel(for: toolName)
            onEvent(.activity(runID, label))
            if let args = json["args"] as? [String: Any],
               let detail = Self.toolDetail(from: args)
            {
                onEvent(.log(runID, "\(label) \(detail)"))
            } else {
                onEvent(.log(runID, label))
            }

        case "tool_execution_update":
            let toolName = (json["toolName"] as? String) ?? "tool"
            let label = Self.activityLabel(for: toolName)
            onEvent(.activity(runID, label))

        case "tool_execution_end":
            if let isError = json["isError"] as? Bool, isError {
                onEvent(.log(runID, "Tool execution error"))
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
                        await session.setUsage(usage)
                    }
                }
            }

        case "agent_settled":
            if await session.lastError == nil {
                await session.complete()
                await EngineSupport.emitCompletion(session: session, runID: runID, engine: Engine.pi, onEvent: onEvent)
            }
            process.terminate()

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

    static func promptParams(from request: EngineRequest) -> [String: Any] {
        var params: [String: Any] = [
            "id": "1",
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
}
