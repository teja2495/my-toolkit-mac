import Foundation
import FoundationModels

struct GrammarTypoCorrector {
    static let defaultPromptTemplate = """
    Correct this text:

    {{text}}
    """

    enum CorrectionError: LocalizedError {
        case modelUnavailable(SystemLanguageModel.Availability)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable(.unavailable(.deviceNotEligible)):
                return "This Mac is not eligible for Apple Intelligence."
            case .modelUnavailable(.unavailable(.appleIntelligenceNotEnabled)):
                return "Apple Intelligence is not enabled."
            case .modelUnavailable(.unavailable(.modelNotReady)):
                return "The Apple Intelligence model is not ready yet."
            case .modelUnavailable:
                return "Apple Intelligence is unavailable."
            }
        }
    }

    func correctedText(
        for text: String,
        promptTemplate: String,
        provider: WritingFixProvider,
        systemPrompt: String
    ) async throws -> String {
        let instructions = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = renderedPrompt(from: promptTemplate, text: text)

        switch provider {
        case .appleIntelligence:
            return try await correctedTextWithAppleIntelligence(
                original: text,
                prompt: prompt,
                instructions: instructions
            )
        case .chatGPT:
            let response = try await ChatGPTRewriteClient().correctedText(
                for: prompt,
                systemPrompt: instructions
            )
            return clean(response, original: text)
        case .codexCLI:
            let response = try await CLIRewriteClient().correctedText(
                for: prompt,
                systemPrompt: instructions,
                provider: provider
            )
            return clean(response, original: text)
        }
    }

    private func correctedTextWithAppleIntelligence(
        original: String,
        prompt: String,
        instructions: String
    ) async throws -> String {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw CorrectionError.modelUnavailable(model.availability)
        }

        let session = LanguageModelSession(model: model, instructions: instructions)

        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(
                sampling: .greedy,
                temperature: 0,
                maximumResponseTokens: max(64, min(4096, original.count + 128))
            )
        )

        return clean(response.content, original: original)
    }

    private func renderedPrompt(from template: String, text: String) -> String {
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTemplate = trimmedTemplate.isEmpty ? Self.defaultPromptTemplate : trimmedTemplate

        if safeTemplate.contains("{{text}}") {
            return safeTemplate.replacingOccurrences(of: "{{text}}", with: text)
        }

        return "\(safeTemplate)\n\n\(text)"
    }

    private func clean(_ response: String, original: String) -> String {
        var cleaned = response

        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```text", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let wrappers: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”")]
        for (open, close) in wrappers where cleaned.first == open && cleaned.last == close {
            guard original.first != open || original.last != close else { continue }
            cleaned.removeFirst()
            cleaned.removeLast()
            break
        }

        return cleaned.isEmpty ? original : cleaned
    }
}
