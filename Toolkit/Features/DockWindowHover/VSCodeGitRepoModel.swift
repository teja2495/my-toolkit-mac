import Combine
import Foundation

enum VSCodeRepoCommitState: Equatable {
    case running
    case succeeded
    case failed(String)
}

/// Tracks which VS Code project folders have uncommitted changes and runs
/// Codex to commit and push them. Owned by the popup controller so commit
/// jobs keep running after the popup hides.
@MainActor
final class VSCodeGitRepoModel: ObservableObject {
    @Published private(set) var dirtyPaths: Set<String> = []
    @Published private(set) var commitStates: [String: VSCodeRepoCommitState] = [:]

    var onChange: (() -> Void)?

    private var refreshGeneration: UInt64 = 0

    func isDirty(_ path: String) -> Bool {
        dirtyPaths.contains(path)
    }

    func refresh(paths: [String]) {
        let repoPaths = Array(Set(paths.filter(Self.isGitRepository)))
        refreshGeneration &+= 1
        let generation = refreshGeneration

        Task { @MainActor in
            let dirty = await Self.dirtyRepositories(in: repoPaths)
            guard generation == refreshGeneration else { return }
            let nextDirtyPaths = dirtyPaths.subtracting(repoPaths).union(dirty)
            guard nextDirtyPaths != dirtyPaths else { return }
            dirtyPaths = nextDirtyPaths
            onChange?()
        }
    }

    func commitAndPush(path: String) {
        guard commitStates[path] != .running else { return }
        commitStates[path] = .running
        onChange?()

        Task { @MainActor in
            let result = await Self.runCodexCommitAndPush(in: path)
            let isDirty = await Self.hasUncommittedChanges(at: path)
            let unpushedCount = await Self.unpushedCommitCount(at: path)

            if isDirty {
                dirtyPaths.insert(path)
            } else {
                dirtyPaths.remove(path)
            }

            if let failure = result.failureMessage {
                commitStates[path] = .failed(failure)
            } else if isDirty {
                commitStates[path] = .failed("Codex finished but uncommitted changes remain.\n\(result.output)")
            } else if unpushedCount > 0 {
                commitStates[path] = .failed("Committed, but \(unpushedCount) commit(s) were not pushed.\n\(result.output)")
            } else {
                commitStates[path] = .succeeded
                onChange?()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if commitStates[path] == .succeeded {
                    commitStates[path] = nil
                }
            }
            onChange?()
        }
    }

    // MARK: - Git

    private static func isGitRepository(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    private static func dirtyRepositories(in paths: [String]) async -> Set<String> {
        await withTaskGroup(of: (String, Bool).self) { group in
            for path in paths {
                group.addTask { (path, await hasUncommittedChanges(at: path)) }
            }
            var dirty: Set<String> = []
            for await (path, isDirty) in group where isDirty {
                dirty.insert(path)
            }
            return dirty
        }
    }

    private static func hasUncommittedChanges(at path: String) async -> Bool {
        let result = await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "status", "--porcelain"]
        )
        return result.status == 0
            && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func unpushedCommitCount(at path: String) async -> Int {
        let result = await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "rev-list", "--count", "@{upstream}..HEAD"]
        )
        guard result.status == 0 else { return 0 }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - Codex

    private struct CodexResult {
        let output: String
        let failureMessage: String?
    }

    private static let commitPrompt = """
    You are committing and pushing the pending changes in this git repository.

    1. Inspect the uncommitted changes (staged, unstaged, and untracked files) using `git status` and `git diff` (include `git diff --cached`).
    2. Look at `git log -n 10 --oneline` and match the style of the existing commit messages.
    3. Write a concise, descriptive commit message summarizing the changes.
    4. Stage everything with `git add -A` and commit with that message.
    5. Push the current branch. If it has no upstream, use `git push -u origin HEAD`.

    Rules: do not edit, create, or delete any files; do not amend, rebase, force-push, or rewrite history. If any step fails, stop and explain the error.
    When finished, reply with only the commit subject line.
    """

    private static func runCodexCommitAndPush(in path: String) async -> CodexResult {
        let result = await ProcessRunner.run(
            executable: "/usr/bin/env",
            arguments: [
                "codex",
                "exec",
                "--cd", path,
                // workspace-write keeps .git read-only, so commits need full access.
                "--sandbox", "danger-full-access",
                "--ephemeral",
                commitPrompt
            ],
            currentDirectory: path
        )

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 127 {
            return CodexResult(
                output: output,
                failureMessage: "codex was not found. Install it with: npm install -g @openai/codex"
            )
        }
        if result.status != 0 {
            let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(error.suffix(600))
            return CodexResult(
                output: output,
                failureMessage: "codex failed (exit \(result.status)).\n\(tail.isEmpty ? output : tail)"
            )
        }
        return CodexResult(output: output, failureMessage: nil)
    }
}

private enum ProcessRunner {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil
    ) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.environment = environment()
                if let currentDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(status: 127, stdout: "", stderr: error.localizedDescription))
                    return
                }

                // Drain both pipes concurrently so large output cannot block the child.
                var errorData = Data()
                let errorGroup = DispatchGroup()
                errorGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    errorGroup.leave()
                }
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                errorGroup.wait()
                process.waitUntilExit()

                continuation.resume(
                    returning: Result(
                        status: process.terminationStatus,
                        stdout: String(data: outputData, encoding: .utf8) ?? "",
                        stderr: String(data: errorData, encoding: .utf8) ?? ""
                    )
                )
            }
        }
    }

    private static func environment() -> [String: String] {
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
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? ""
        environment["PATH"] = (commandPaths + [inheritedPath])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        return environment
    }
}
