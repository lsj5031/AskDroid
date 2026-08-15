import Foundation

enum JSONRPC {
    static let version = "2.0"
    static let factoryAPIVersion = "1.0.0"
    static let factoryProtocolVersion = "1.1.0"

    static func request(id: String, method: String, params: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": version,
            "factoryApiVersion": factoryAPIVersion,
            "factoryProtocolVersion": factoryProtocolVersion,
            "type": "request",
            "id": id,
            "method": method,
            "params": params,
        ]
    }

    static func response(id: String, result: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": version,
            "factoryApiVersion": factoryAPIVersion,
            "factoryProtocolVersion": factoryProtocolVersion,
            "type": "response",
            "id": id,
            "result": result,
        ]
    }

    static func encodeLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else {
            throw DroidEngineError.protocolFailure("Could not encode JSON-RPC line.")
        }
        return line
    }

    static func parse(_ line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8) else {
            throw DroidEngineError.protocolFailure("Invalid UTF-8 in JSON-RPC line.")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw DroidEngineError.protocolFailure("JSON-RPC line was not an object.")
        }
        return dictionary
    }
}

enum DroidNotification {
    case assistantTextDelta(String)
    case thinking(String)
    case toolCall(name: String)
    case toolProgress(name: String)
    case workingState(String)
    case error(String)
    case turnCompleted(durationMs: Double?, tokenUsage: TokenUsage?)
    case ignored
}

struct TokenUsage: Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?

    var summary: String? {
        switch (inputTokens, outputTokens) {
        case let (input?, output?):
            "\(input) in · \(output) out"
        case let (input?, nil):
            "\(input) in"
        case let (nil, output?):
            "\(output) out"
        default:
            nil
        }
    }
}

enum DroidNotificationParser {
    static func parse(_ message: [String: Any]) -> DroidNotification {
        let params = (message["params"] as? [String: Any]) ?? message
        let payload = (params["notification"] as? [String: Any])
            ?? (params["event"] as? [String: Any])
            ?? params
        guard let type = payload["type"] as? String else {
            return .ignored
        }

        switch type {
        case "assistant_text_delta", "assistant_message":
            let text = (payload["textDelta"] as? String) ?? (payload["text"] as? String) ?? ""
            return text.isEmpty ? .ignored : .assistantTextDelta(text)
        case "thinking_text_delta", "thinking":
            let text = (payload["textDelta"] as? String) ?? (payload["text"] as? String) ?? ""
            return text.isEmpty ? .ignored : .thinking(text)
        case "tool_call":
            let name = toolName(in: payload)
            return .toolCall(name: name)
        case "tool_progress_update", "tool_execution_heartbeat", "tool_execution_phase_changed":
            let name = (payload["toolName"] as? String) ?? toolName(in: payload)
            return .toolProgress(name: name)
        case "droid_working_state_changed":
            return .workingState((payload["newState"] as? String) ?? "working")
        case "error":
            return .error((payload["message"] as? String) ?? "Droid reported an error.")
        case "agent_turn_completed":
            return .turnCompleted(
                durationMs: doubleValue(payload["durationMs"]),
                tokenUsage: tokenUsage(from: payload["tokenUsage"])
            )
        default:
            return .ignored
        }
    }

    private static func toolName(in payload: [String: Any]) -> String {
        if let direct = payload["name"] as? String { return direct }
        if let toolUse = payload["toolUse"] as? [String: Any],
           let name = toolUse["name"] as? String
        {
            return name
        }
        return "tool"
    }

    private static func tokenUsage(from value: Any?) -> TokenUsage? {
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

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return nil
    }
}
