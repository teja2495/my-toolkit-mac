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
    @Published private(set) var unpushedPaths: Set<String> = []
    @Published private(set) var commitStates: [String: VSCodeRepoCommitState] = [:]
    @Published private(set) var branchNames: [String: String] = [:]
    @Published private(set) var runStates: [String: VSCodeRepoCommitState] = [:]

    var onChange: (() -> Void)?

    private var refreshGeneration: UInt64 = 0

    func isDirty(_ path: String) -> Bool {
        dirtyPaths.contains(path)
    }

    /// True when the repo has uncommitted changes or commits not yet pushed.
    func hasPendingChanges(_ path: String) -> Bool {
        dirtyPaths.contains(path) || unpushedPaths.contains(path)
    }

    func refresh(paths: [String]) {
        let repoPaths = Array(Set(paths.filter(Self.isGitRepository)))
        refreshGeneration &+= 1
        let generation = refreshGeneration

        Task { @MainActor in
            async let dirtyResult = Self.dirtyRepositories(in: repoPaths)
            async let unpushedResult = Self.unpushedRepositories(in: repoPaths)
            async let branchResult = Self.branchNames(in: repoPaths)
            let dirty = await dirtyResult
            let unpushed = await unpushedResult
            let branches = await branchResult
            guard generation == refreshGeneration else { return }
            let nextDirtyPaths = dirtyPaths.subtracting(repoPaths).union(dirty)
            let nextUnpushedPaths = unpushedPaths.subtracting(repoPaths).union(unpushed)
            var nextBranchNames = branchNames
            for path in repoPaths {
                nextBranchNames[path] = branches[path]
            }
            guard nextDirtyPaths != dirtyPaths
                || nextUnpushedPaths != unpushedPaths
                || nextBranchNames != branchNames
            else { return }
            dirtyPaths = nextDirtyPaths
            unpushedPaths = nextUnpushedPaths
            branchNames = nextBranchNames
            onChange?()
        }
    }

    func commitAndPush(path: String) {
        guard commitStates[path] != .running else { return }
        commitStates[path] = .running
        onChange?()

        Task { @MainActor in
            // Nothing to commit means only a push is needed, which doesn't need Codex.
            let needsCommit = await Self.hasUncommittedChanges(at: path)
            let result = needsCommit
                ? await Self.runCodexCommitAndPush(in: path)
                : await Self.runGitPush(in: path)
            let isDirty = await Self.hasUncommittedChanges(at: path)
            let unpushedCount = await Self.unpushedCommitCount(at: path)

            if isDirty {
                dirtyPaths.insert(path)
            } else {
                dirtyPaths.remove(path)
            }
            if unpushedCount > 0 {
                unpushedPaths.insert(path)
            } else {
                unpushedPaths.remove(path)
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

    /// Runs the user's `run` zsh function from the project folder without
    /// opening a terminal window.
    func runProject(path: String) {
        guard runStates[path] != .running else { return }
        runStates[path] = .running
        onChange?()

        Task { @MainActor in
            let result = await ProcessRunner.run(
                executable: "/bin/zsh",
                arguments: ["-ic", Self.runCommand(for: path)],
                currentDirectory: path
            )
            Self.writeRunLog(path: path, result: result)

            if result.status == 0 {
                runStates[path] = .succeeded
                onChange?()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if runStates[path] == .succeeded {
                    runStates[path] = nil
                }
            } else {
                let output = (result.stderr + "\n" + result.stdout)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let failure = VSCodeRepoCommitState.failed(
                    "run failed (exit \(result.status)).\n\(String(output.suffix(600)))"
                )
                runStates[path] = failure
                onChange?()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if runStates[path] == failure {
                    runStates[path] = nil
                }
            }
            onChange?()
        }
    }

    /// Projects whose play button should install a Release build instead of a dev run.
    private static let releaseProjectNames: Set<String> = ["noted-mac", "my-toolkit-mac"]

    private static func runCommand(for path: String) -> String {
        let name = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).lastPathComponent
        return releaseProjectNames.contains(name) ? "release" : "run"
    }

    /// Keeps the last run's full output at ~/Library/Logs/Toolkit/vscode-run.log for debugging.
    private static func writeRunLog(path: String, result: ProcessRunner.Result) {
        let logDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Toolkit", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let text = """
        [\(Date())] run in \(path)
        exit: \(result.status)
        --- stdout ---
        \(result.stdout)
        --- stderr ---
        \(result.stderr)
        """
        try? text.write(
            to: logDirectory.appendingPathComponent("vscode-run.log"),
            atomically: true,
            encoding: .utf8
        )
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

    private static func unpushedRepositories(in paths: [String]) async -> Set<String> {
        await withTaskGroup(of: (String, Bool).self) { group in
            for path in paths {
                group.addTask { (path, await unpushedCommitCount(at: path) > 0) }
            }
            var unpushed: Set<String> = []
            for await (path, hasUnpushed) in group where hasUnpushed {
                unpushed.insert(path)
            }
            return unpushed
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

    private static func branchNames(in paths: [String]) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for path in paths {
                group.addTask { (path, await currentBranch(at: path)) }
            }
            var names: [String: String] = [:]
            for await (path, name) in group {
                if let name { names[path] = name }
            }
            return names
        }
    }

    /// The checked-out branch, or the short commit hash when HEAD is detached.
    private static func currentBranch(at path: String) async -> String? {
        let branch = await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "branch", "--show-current"]
        )
        let name = branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.status == 0, !name.isEmpty { return name }

        let head = await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "rev-parse", "--short", "HEAD"]
        )
        let hash = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.status == 0 && !hash.isEmpty ? hash : nil
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

    private static let maxDiffCharacters = 60_000

    /// Collects status, diff, and log up front so Codex can go straight to
    /// committing instead of spending model turns inspecting the repo.
    private static func commitPrompt(for path: String) async -> String {
        async let status = gitOutput(["status", "--porcelain=v1", "--branch"], in: path)
        async let stat = gitOutput(["diff", "HEAD", "--stat"], in: path)
        async let diff = gitOutput(["diff", "HEAD"], in: path)
        async let untracked = gitOutput(["ls-files", "--others", "--exclude-standard"], in: path)
        async let log = gitOutput(["log", "-n", "10", "--oneline"], in: path)

        var diffText = await diff
        if diffText.count > maxDiffCharacters {
            diffText = String(diffText.prefix(maxDiffCharacters)) + "\n… (diff truncated; rely on the stat summary for the rest)"
        }

        return """
        Commit and push the pending changes in this git repository. All the context you need is below, so do not run any inspection commands.

        Write a concise, descriptive commit message for these changes that matches the style of the recent commits. Then run exactly one shell command:
        git add -A && git commit -m "<subject>" [-m "<body>"] && git push
        If the branch has no upstream (no "..." in the status header line), use `git push -u origin HEAD` instead of `git push`.

        Rules: do not edit, create, or delete any files; do not amend, rebase, force-push, or rewrite history. If the command fails, explain the error.
        When finished, reply with only the commit subject line.

        ## git status --branch
        \(await status)

        ## Recent commits
        \(await log)

        ## Untracked files (not shown in the diff)
        \(await untracked)

        ## git diff HEAD --stat
        \(await stat)

        ## git diff HEAD
        \(diffText)
        """
    }

    private static func gitOutput(_ arguments: [String], in path: String) async -> String {
        let result = await ProcessRunner.run(executable: "/usr/bin/git", arguments: ["-C", path] + arguments)
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "(none)" : output
    }

    private static func runGitPush(in path: String) async -> CodexResult {
        let upstream = await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]
        )
        let pushArguments = upstream.status == 0 ? ["push"] : ["push", "-u", "origin", "HEAD"]
        let result = await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path] + pushArguments
        )
        // git push reports progress on stderr even when it succeeds.
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status != 0 {
            return CodexResult(
                output: output,
                failureMessage: "git push failed (exit \(result.status)).\n\(String(output.suffix(600)))"
            )
        }
        return CodexResult(output: output, failureMessage: nil)
    }

    private static func runCodexCommitAndPush(in path: String) async -> CodexResult {
        let prompt = await commitPrompt(for: path)
        let result = await ProcessRunner.run(
            executable: "/usr/bin/env",
            arguments: [
                "codex",
                "exec",
                "--cd", path,
                // A commit message is a light task; a small model at low effort is much faster.
                "--model", "gpt-5.6-luna",
                "-c", "model_reasoning_effort=\"low\"",
                // workspace-write keeps .git read-only, so commits need full access.
                "--sandbox", "danger-full-access",
                "--ephemeral",
                prompt
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
