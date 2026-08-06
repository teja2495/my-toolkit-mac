import Foundation

struct ChatGPTRewriteClient {
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private static let model = "gpt-5.6-luna"

    enum ClientError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case requestFailed(String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add an OpenAI API key in Rewritely settings before using ChatGPT."
            case .invalidResponse:
                return "ChatGPT returned an invalid response."
            case .requestFailed(let message):
                return message
            case .emptyResponse:
                return "ChatGPT returned an empty response."
            }
        }
    }

    func correctedText(for prompt: String, systemPrompt: String) async throws -> String {
        guard let apiKey = WritingFixAPIKeyStore.load() else {
            throw ClientError.missingAPIKey
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: Self.model,
                instructions: systemPrompt,
                input: prompt,
                maxOutputTokens: max(64, min(4096, prompt.count + 128)),
                reasoning: .init(effort: "none"),
                store: false
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            throw ClientError.requestFailed(
                apiError?.error.message ?? "ChatGPT request failed with status \(httpResponse.statusCode)."
            )
        }

        let responseBody = try JSONDecoder().decode(ResponseBody.self, from: data)
        let text = responseBody.output
            .compactMap(\.content)
            .flatMap { $0 }
            .first(where: { $0.type == "output_text" })?
            .text?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let text, !text.isEmpty else { throw ClientError.emptyResponse }
        return text
    }

    private struct RequestBody: Encodable {
        let model: String
        let instructions: String
        let input: String
        let maxOutputTokens: Int
        let reasoning: Reasoning
        let store: Bool

        enum CodingKeys: String, CodingKey {
            case model
            case instructions
            case input
            case maxOutputTokens = "max_output_tokens"
            case reasoning
            case store
        }
    }

    private struct Reasoning: Encodable {
        let effort: String
    }

    private struct ResponseBody: Decodable {
        let output: [Output]
    }

    private struct Output: Decodable {
        let content: [Content]?
    }

    private struct Content: Decodable {
        let type: String
        let text: String?
    }

    private struct ErrorEnvelope: Decodable {
        let error: APIError
    }

    private struct APIError: Decodable {
        let message: String
    }
}
