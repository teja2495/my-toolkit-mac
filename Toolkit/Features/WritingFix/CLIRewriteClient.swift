import Foundation

struct CLIRewriteClient {
    enum ClientError: LocalizedError {
        case commandNotFound(String, installCommand: String)
        case commandFailed(String, String)
        case emptyResponse(String)

        var errorDescription: String? {
            switch self {
            case .commandNotFound(let command, let installCommand):
                return "\(command) was not found. Install it, sign in, then try again: \(installCommand)"
            case .commandFailed(let command, let message):
                return "\(command) failed: \(message)"
            case .emptyResponse(let command):
                return "\(command) returned an empty response."
            }
        }
    }

    func correctedText(
        for prompt: String,
        systemPrompt: String,
        provider: WritingFixProvider
    ) async throws -> String {
        let request = rewriteRequest(prompt: prompt, systemPrompt: systemPrompt)

        switch provider {
        case .codexCLI:
            return try await run(
                command: "codex",
                arguments: [
                    "exec",
                    "--model", "gpt-5.6-luna",
                    "--sandbox", "read-only",
                    "--skip-git-repo-check",
                    "--ephemeral",
                    request
                ],
                installCommand: "npm install -g @openai/codex"
            )
        case .appleIntelligence, .chatGPT:
            preconditionFailure("CLIRewriteClient only supports CLI providers.")
        }
    }

    private func rewriteRequest(prompt: String, systemPrompt: String) -> String {
        let trimmedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemInstructions = trimmedSystemPrompt.isEmpty
            ? ""
            : "\n\nAdditional instructions:\n\(trimmedSystemPrompt)"

        return """
        Rewrite the provided text according to the request below. Return only the rewritten text, without commentary, labels, markdown fences, or quotation marks unless they are part of the rewritten text.

        Request:
        \(prompt)\(systemInstructions)
        """
    }

    private func run(
        command: String,
        arguments: [String],
        installCommand: String
    ) async throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = environment()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let output = String(
                    data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let error = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus == 127 {
                    continuation.resume(throwing: ClientError.commandNotFound(command, installCommand: installCommand))
                } else if process.terminationStatus != 0 {
                    continuation.resume(
                        throwing: ClientError.commandFailed(
                            command,
                            error.isEmpty ? "exit status \(process.terminationStatus)" : error
                        )
                    )
                } else if output.isEmpty {
                    continuation.resume(throwing: ClientError.emptyResponse(command))
                } else {
                    continuation.resume(returning: output)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(
                    throwing: ClientError.commandNotFound(command, installCommand: installCommand)
                )
            }
        }
    }

    private func environment() -> [String: String] {
        let home = NSHomeDirectory()
        let commandPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/bin",
            "/usr/bin",
            "/bin"
        ]
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (commandPaths + [inheritedPath])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        return environment
    }
}
