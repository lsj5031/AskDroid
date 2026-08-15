import Foundation

enum DroidEngineError: LocalizedError, Equatable {
    case droidNotFound
    case notAuthenticated
    case protocolFailure(String)
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .droidNotFound:
            "Droid was not found. Install the CLI or set its path in Settings."
        case .notAuthenticated:
            "Droid is not authenticated. Run `droid` in Terminal and sign in."
        case .protocolFailure(let message):
            message
        case .cancelled:
            "Cancelled."
        case .failed(let message):
            message
        }
    }
}

struct DroidRunRequest: Sendable {
    var prompt: String
    var images: [AttachedImage]
    var settings: AppSettings
}

struct DroidRunResult: Sendable {
    var text: String
    var model: String?
    var duration: TimeInterval
    var tokenUsage: TokenUsage?
    var archiveURL: URL?
    var archiveError: String?
}

enum DroidRunEvent: Sendable {
    case started(UUID)
    case activity(UUID, String)
    case thinking(UUID, String)
    case textDelta(UUID, String)
    case log(UUID, String)
    case completed(UUID, DroidRunResult)
    case failed(UUID, String)
}

protocol DroidProcessLaunching: Sendable {
    func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        cwd: String
    ) throws -> any DroidProcessIO
}

protocol DroidProcessIO: AnyObject, Sendable {
    var standardOutput: FileHandle { get }
    var standardError: FileHandle { get }
    func write(_ line: String) throws
    func terminate()
    func waitUntilExit() -> Int32
}

final class FoundationDroidProcess: DroidProcessIO, @unchecked Sendable {
    let process: Process
    let stdin: FileHandle
    let standardOutput: FileHandle
    let standardError: FileHandle

    init(process: Process, stdin: FileHandle, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.stdin = stdin
        self.standardOutput = stdout
        self.standardError = stderr
    }

    func write(_ line: String) throws {
        var payload = line
        if !payload.hasSuffix("\n") {
            payload.append("\n")
        }
        guard let data = payload.data(using: .utf8) else { return }
        try stdin.write(contentsOf: data)
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
        try? stdin.close()
    }

    func waitUntilExit() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }
}

struct FoundationProcessLauncher: DroidProcessLaunching {
    func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        cwd: String
    ) throws -> any DroidProcessIO {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        return FoundationDroidProcess(
            process: process,
            stdin: stdin.fileHandleForWriting,
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading
        )
    }
}

actor DroidEngine {
    private let launcher: any DroidProcessLaunching
    private let fileExists: @Sendable (String) -> Bool
    private var activeProcess: (any DroidProcessIO)?

    init(
        launcher: any DroidProcessLaunching = FoundationProcessLauncher(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.launcher = launcher
        self.fileExists = fileExists
    }

    func cancel() {
        activeProcess?.terminate()
        activeProcess = nil
    }

    func run(
        _ request: DroidRunRequest,
        onEvent: @escaping @Sendable (DroidRunEvent) -> Void
    ) async {
        let runID = UUID()
        let startedAt = Date()
        onEvent(.started(runID))
        onEvent(.activity(runID, "Starting Droid…"))
        onEvent(.log(runID, "Looking for the droid CLI…"))

        guard let executable = BinaryDiscovery.resolve(override: request.settings.droidPath, fileExists: fileExists) else {
            onEvent(.failed(runID, DroidEngineError.droidNotFound.localizedDescription))
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
                environment: Self.augmentedEnvironment(),
                cwd: cwd
            )
            activeProcess = process
            onEvent(.activity(runID, "Opening a Droid session…"))
            onEvent(.log(runID, "cwd \(cwd)"))

            let session = RunSession(
                request: request,
                startedAt: startedAt,
                model: request.settings.modelOverride.trimmedOrNil
            )

            try process.write(try JSONRPC.encodeLine(JSONRPC.request(
                id: "1",
                method: "droid.initialize_session",
                params: Self.initializeParams(from: request.settings)
            )))
            onEvent(.log(runID, "initialize_session sent"))

            let initTimeout = Task {
                try? await Task.sleep(for: .seconds(25))
                if await !session.didInitialize, await !session.isFinished {
                    await session.mark(error: "Droid did not start a session in time.")
                    process.terminate()
                }
            }

            let turnTimeout = Task {
                try? await Task.sleep(for: .seconds(600))
                if await !session.isFinished {
                    await session.mark(error: "Droid did not finish in 10 minutes.")
                    process.terminate()
                }
            }

            let stdoutTask = Task.detached {
                let reader = LineReader()
                while let data = try? process.standardOutput.read(upToCount: 16_384), !data.isEmpty {
                    for line in reader.push(data) {
                        await self.handle(line: line, process: process, session: session, runID: runID, onEvent: onEvent)
                        if await session.isFinished { return }
                    }
                }
            }

            let stderrTask = Task.detached {
                let reader = LineReader()
                while let data = try? process.standardError.read(upToCount: 16_384), !data.isEmpty {
                    for line in reader.push(data) {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        onEvent(.log(runID, trimmed))
                        if trimmed.localizedCaseInsensitiveContains("not authenticated")
                            || trimmed.localizedCaseInsensitiveContains("FACTORY_API_KEY")
                        {
                            await session.mark(error: DroidEngineError.notAuthenticated.localizedDescription)
                            process.terminate()
                        }
                    }
                }
            }

            let status = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: process.waitUntilExit())
                }
            }
            initTimeout.cancel()
            turnTimeout.cancel()
            _ = await stdoutTask.result
            _ = await stderrTask.result
            if activeProcess === process {
                activeProcess = nil
            }

            if await session.isFinished { return }

            if let lastError = await session.lastError {
                onEvent(.failed(runID, lastError))
                return
            }
            if Task.isCancelled || status == SIGTERM || status == SIGKILL {
                onEvent(.failed(runID, DroidEngineError.cancelled.localizedDescription))
                return
            }
            if status != 0 {
                onEvent(.failed(runID, "Droid exited with status \(status)."))
                return
            }
            await emitCompletion(session: session, runID: runID, onEvent: onEvent)
        } catch is CancellationError {
            activeProcess?.terminate()
            activeProcess = nil
            onEvent(.failed(runID, DroidEngineError.cancelled.localizedDescription))
        } catch {
            activeProcess = nil
            onEvent(.failed(runID, error.localizedDescription))
        }
    }

    private func handle(
        line: String,
        process: any DroidProcessIO,
        session: RunSession,
        runID: UUID,
        onEvent: @escaping @Sendable (DroidRunEvent) -> Void
    ) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let message = try? JSONRPC.parse(trimmed) else { return }

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
            onEvent(.log(runID, detail))
            await session.mark(error: detail)
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
                    onEvent(.log(runID, "Model \(modelId)"))
                } else if let modelId = result["modelId"] as? String {
                    await session.setModel(modelId)
                    onEvent(.log(runID, "Model \(modelId)"))
                }
            }
            onEvent(.activity(runID, "Sending your question…"))
            do {
                try process.write(try JSONRPC.encodeLine(JSONRPC.request(
                    id: "2",
                    method: "droid.add_user_message",
                    params: Self.userMessageParams(from: session.request)
                )))
                onEvent(.activity(runID, "Waiting for Droid…"))
                onEvent(.log(runID, "Question sent"))
            } catch {
                await session.mark(error: error.localizedDescription)
                process.terminate()
            }
            return
        }

        if stringID(message["id"]) == "2" {
            onEvent(.activity(runID, "Droid is working…"))
            return
        }

        switch DroidNotificationParser.parse(message) {
        case .assistantTextDelta(let text):
            await session.append(text)
            onEvent(.textDelta(runID, text))
        case .thinking(let text):
            onEvent(.thinking(runID, text))
        case .toolCall(let name, let detail):
            let label = Self.activityLabel(for: name)
            onEvent(.activity(runID, label))
            onEvent(.log(runID, detail.map { "\(label) \($0)" } ?? label))
        case .toolProgress(let name):
            let label = Self.activityLabel(for: name)
            onEvent(.activity(runID, label))
        case .toolResult(let text):
            onEvent(.log(runID, "→ \(text)"))
        case .tokenUsage(let usage):
            if let summary = usage.summary {
                onEvent(.activity(runID, "Working… \(summary)"))
            }
        case .workingState(let state):
            let label = Self.workingLabel(for: state)
            onEvent(.activity(runID, label))
            onEvent(.log(runID, label))
        case .error(let message):
            onEvent(.log(runID, message))
            await session.mark(error: message)
            process.terminate()
        case .turnCompleted(let durationMs, let usage):
            await session.complete(durationMs: durationMs, tokenUsage: usage)
            await emitCompletion(session: session, runID: runID, onEvent: onEvent)
            process.terminate()
        case .ignored:
            if let method = message["method"] as? String {
                onEvent(.log(runID, method.replacingOccurrences(of: "droid.", with: "")))
            }
        }
    }

    private func emitCompletion(
        session: RunSession,
        runID: UUID,
        onEvent: @escaping @Sendable (DroidRunEvent) -> Void
    ) async {
        let snapshot = await session.snapshot()
        let duration = Date().timeIntervalSince(snapshot.startedAt)
        if snapshot.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onEvent(.log(runID, "Turn ended with no text answer."))
        }
        var archiveURL: URL?
        var archiveError: String?
        if !snapshot.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let archived = try AnswerArchive.write(
                    directory: URL(fileURLWithPath: snapshot.request.settings.resolvedAnswersDirectory, isDirectory: true),
                    question: snapshot.request.prompt,
                    answer: snapshot.answer,
                    model: snapshot.model,
                    duration: duration,
                    images: snapshot.request.images
                )
                archiveURL = archived.markdownURL
                onEvent(.log(runID, "Saved \(archived.markdownURL.lastPathComponent)"))
            } catch {
                archiveError = "Could not save the answer file: \(error.localizedDescription)"
                onEvent(.log(runID, archiveError ?? "Could not save the answer file."))
            }
        }
        onEvent(.completed(runID, DroidRunResult(
            text: snapshot.answer,
            model: snapshot.model,
            duration: duration,
            tokenUsage: snapshot.tokenUsage,
            archiveURL: archiveURL,
            archiveError: archiveError
        )))
    }

    private func writeResponse(_ process: any DroidProcessIO, id: String, result: [String: Any]) {
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

    static func userMessageParams(from request: DroidRunRequest) -> [String: Any] {
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

    static func augmentedEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [String: String] {
        var environment = base
        let extras = [
            "\(home)/.local/bin",
            "\(home)/.local/share/mise/shims",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let current = environment["PATH"] ?? ""
        environment["PATH"] = (extras + [current]).joined(separator: ":")
        return environment
    }

    static func activityLabel(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "read", "readfile", "read_file":
            "Reading files…"
        case "grep", "rg", "search":
            "Searching…"
        case "glob", "ls", "list":
            "Listing files…"
        case "execute", "execute-cli", "bash", "shell":
            "Running a command…"
        case "applypatch", "apply_patch", "edit":
            "Editing…"
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

private actor RunSession {
    let request: DroidRunRequest
    private(set) var startedAt: Date
    private(set) var model: String?
    private(set) var answer = ""
    private(set) var tokenUsage: TokenUsage?
    private(set) var lastError: String?
    private(set) var finished = false
    private(set) var didInitialize = false

    var isFinished: Bool { finished }

    init(request: DroidRunRequest, startedAt: Date, model: String?) {
        self.request = request
        self.startedAt = startedAt
        self.model = model
    }

    func setModel(_ model: String) {
        self.model = model
    }

    func append(_ text: String) {
        answer.append(text)
    }

    func markInitialized() {
        didInitialize = true
    }

    func mark(error: String) {
        lastError = error
    }

    func complete(durationMs: Double?, tokenUsage: TokenUsage?) {
        self.tokenUsage = tokenUsage ?? self.tokenUsage
        if let durationMs {
            startedAt = Date().addingTimeInterval(-(durationMs / 1000))
        }
        finished = true
    }

    func snapshot() -> (
        request: DroidRunRequest,
        startedAt: Date,
        model: String?,
        answer: String,
        tokenUsage: TokenUsage?
    ) {
        (request, startedAt, model, answer, tokenUsage)
    }
}

final class LineReader: @unchecked Sendable {
    private var buffer = Data()

    func push(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let range = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) {
                let cleaned = line.hasSuffix("\r") ? String(line.dropLast()) : line
                if !cleaned.isEmpty {
                    lines.append(cleaned)
                }
            }
        }
        return lines
    }
}

extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
