@preconcurrency import Foundation

struct GrokTextMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String
}

struct GrokTextUsage: Sendable, Equatable {
    var inputTokens = 0
    var outputTokens = 0
}

struct GrokTextStreamingResult: Sendable, Equatable {
    let text: String
    let usage: GrokTextUsage
}

enum GrokTextStreamingError: LocalizedError {
    case malformedResponse
    case http(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            "Réponse texte xAI illisible."
        case .http(let status, let body):
            "Grok texte HTTP \(status) : \(body.prefix(400))"
        case .emptyResponse:
            "Grok n’a renvoyé aucun texte."
        }
    }
}

actor GrokTextStreamingClient {
    static let model = "grok-4.20-0309-non-reasoning"
    static let inputPricePerMillionTokensUSD = 1.25
    static let outputPricePerMillionTokensUSD = 2.50

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.networkServiceType = .responsiveData
        session = URLSession(configuration: configuration)
    }

    func streamResponse(
        apiKey: String,
        instructions: String,
        history: [GrokTextMessage],
        userText: String,
        tools: [GrokTextToolDefinition] = [],
        onToolCall: (@MainActor @Sendable (GrokTextToolCall) async throws -> GrokTextToolResult)? = nil,
        onDelta: @escaping @Sendable (String, ContinuousClock.Instant) async -> Void
    ) async throws -> GrokTextStreamingResult {
        let trimmedHistory = Array(history.suffix(24))
        var messages: [[String: Any]] = [
            ["role": "system", "content": instructions],
        ]
        messages.append(contentsOf: trimmedHistory.map {
            ["role": $0.role, "content": $0.content]
        })
        messages.append(["role": "user", "content": userText])

        var totalUsage = GrokTextUsage()
        let maximumToolRounds = 4
        for roundIndex in 0 ... maximumToolRounds {
            let round = try await streamRound(
                apiKey: apiKey,
                messages: messages,
                tools: tools,
                onDelta: onDelta)
            totalUsage.inputTokens += round.usage.inputTokens
            totalUsage.outputTokens += round.usage.outputTokens

            guard !round.toolCalls.isEmpty else {
                let finalText = round.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !finalText.isEmpty else { throw GrokTextStreamingError.emptyResponse }
                return GrokTextStreamingResult(text: finalText, usage: totalUsage)
            }
            guard roundIndex < maximumToolRounds, let onToolCall else {
                throw GrokTextStreamingError.malformedResponse
            }

            messages.append([
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": round.toolCalls.map(\.assistantPayload),
            ])
            for toolCall in round.toolCalls {
                let result = try await onToolCall(toolCall.call)
                messages.append([
                    "role": "tool",
                    "tool_call_id": toolCall.id,
                    "content": result.output,
                ])
            }
        }
        throw GrokTextStreamingError.emptyResponse
    }

    private func streamRound(
        apiKey: String,
        messages: [[String: Any]],
        tools: [GrokTextToolDefinition],
        onDelta: @escaping @Sendable (String, ContinuousClock.Instant) async -> Void
    ) async throws -> StreamingRound {
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.networkServiceType = .responsiveData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var body: [String: Any] = [
            "model": Self.model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": 320,
        ]
        let toolPayloads = tools.compactMap(Self.toolPayload)
        if !toolPayloads.isEmpty {
            body["tools"] = toolPayloads
            body["tool_choice"] = "auto"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GrokTextStreamingError.malformedResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw GrokTextStreamingError.http(http.statusCode, body)
        }

        var completeText = ""
        var usage = GrokTextUsage()
        var partialToolCalls: [Int: PartialToolCall] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let usageJSON = json["usage"] as? [String: Any] {
                usage.inputTokens = usageJSON["prompt_tokens"] as? Int ?? usage.inputTokens
                usage.outputTokens = usageJSON["completion_tokens"] as? Int ?? usage.outputTokens
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let delta = choice["delta"] as? [String: Any]
            else { continue }

            if let content = delta["content"] as? String, !content.isEmpty {
                completeText += content
                await onDelta(content, .now)
            }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for payload in calls {
                    let index = payload["index"] as? Int ?? partialToolCalls.count
                    var partial = partialToolCalls[index] ?? PartialToolCall()
                    if let id = payload["id"] as? String { partial.id += id }
                    if let function = payload["function"] as? [String: Any] {
                        if let name = function["name"] as? String { partial.name += name }
                        if let arguments = function["arguments"] as? String {
                            partial.arguments += arguments
                        }
                    }
                    partialToolCalls[index] = partial
                }
            }
        }

        let toolCalls = partialToolCalls.keys.sorted().compactMap { index in
            partialToolCalls[index]?.completed
        }
        return StreamingRound(text: completeText, usage: usage, toolCalls: toolCalls)
    }

    private static func toolPayload(_ tool: GrokTextToolDefinition) -> [String: Any]? {
        guard let parameters = try? JSONSerialization.jsonObject(with: tool.parameters)
                as? [String: Any] else { return nil }
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": parameters,
            ],
        ]
    }
}

private struct StreamingRound {
    let text: String
    let usage: GrokTextUsage
    let toolCalls: [CompletedToolCall]
}

private struct PartialToolCall {
    var id = ""
    var name = ""
    var arguments = ""

    var completed: CompletedToolCall? {
        guard !id.isEmpty,
              !name.isEmpty,
              let data = arguments.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return nil }
        return CompletedToolCall(id: id, name: name, arguments: data)
    }
}

private struct CompletedToolCall {
    let id: String
    let name: String
    let arguments: Data

    var call: GrokTextToolCall {
        GrokTextToolCall(name: name, arguments: arguments)
    }

    var assistantPayload: [String: Any] {
        [
            "id": id,
            "type": "function",
            "function": [
                "name": name,
                "arguments": String(data: arguments, encoding: .utf8) ?? "{}",
            ],
        ]
    }
}
