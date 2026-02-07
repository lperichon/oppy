import Foundation

final class WorkerLauncher {
    typealias ProgressHandler = (String) -> Void
    static let readinessProbeScript = "import mlx_audio; import pyannote.audio; import soundfile"

    func run(
        config: WorkerConfig,
        hfToken: String,
        onProgress: @escaping ProgressHandler
    ) async throws -> WorkerResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runSynchronously(config: config, hfToken: hfToken, onProgress: onProgress)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func bootstrapASRModel(
        asrModel: String,
        language: String,
        onProgress: @escaping ProgressHandler
    ) async throws -> WorkerResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try self.runBootstrapSynchronously(
                        asrModel: asrModel,
                        language: language,
                        onProgress: onProgress
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runSynchronously(
        config: WorkerConfig,
        hfToken: String,
        onProgress: @escaping ProgressHandler
    ) throws -> WorkerResult {
        let configURL = try writeTempConfig(config)
        defer { try? FileManager.default.removeItem(at: configURL) }

        return try runWorkerSynchronously(
            scriptArguments: ["--config", configURL.path],
            scriptPath: try resolveWorkerScriptPath(),
            hfToken: hfToken,
            onProgress: onProgress
        )
    }

    private func runBootstrapSynchronously(
        asrModel: String,
        language: String,
        onProgress: @escaping ProgressHandler
    ) throws -> WorkerResult {
        return try runWorkerSynchronously(
            scriptArguments: ["--bootstrap-asr", "--asr-model", asrModel, "--language", language],
            scriptPath: try resolveWorkerScriptPath(),
            hfToken: nil,
            onProgress: onProgress
        )
    }

    private func runWorkerSynchronously(
        scriptArguments: [String],
        scriptPath: String,
        hfToken: String?,
        onProgress: @escaping ProgressHandler
    ) throws -> WorkerResult {
        let launchCommand = resolvePythonLaunchCommand(scriptPath: scriptPath)
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.executableURL = URL(fileURLWithPath: launchCommand.executable)
        process.arguments = launchCommand.arguments + [scriptPath] + scriptArguments

        var environment = ProcessInfo.processInfo.environment
        if let hfToken, !hfToken.isEmpty {
            environment["HF_TOKEN"] = hfToken
        }
        environment["PYANNOTE_METRICS_ENABLED"] = "0"
        process.environment = environment

        let decoder = JSONDecoder()
        var buffered = ""
        var finalResult: WorkerResult?
        var rawWorkerLines: [String] = []

        pipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            buffered += chunk

            while let newLineRange = buffered.range(of: "\n") {
                let line = String(buffered[..<newLineRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                buffered = String(buffered[newLineRange.upperBound...])
                self.handleWorkerLine(
                    line,
                    decoder: decoder,
                    onProgress: onProgress,
                    finalResult: &finalResult,
                    rawWorkerLines: &rawWorkerLines
                )
            }
        }

        try process.run()
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        let trailing = buffered.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            handleWorkerLine(
                trailing,
                decoder: decoder,
                onProgress: onProgress,
                finalResult: &finalResult,
                rawWorkerLines: &rawWorkerLines
            )
        }

        if let result = finalResult {
            return result
        }

        if process.terminationStatus == 0 {
            return WorkerResult(
                type: "result",
                success: false,
                transcriptPath: nil,
                wavPath: nil,
                jsonPath: nil,
                errorCode: "WORKER_PROTOCOL_ERROR",
                message: "Worker exited without returning a final result"
            )
        }

        return WorkerResult(
            type: "result",
            success: false,
            transcriptPath: nil,
            wavPath: nil,
            jsonPath: nil,
            errorCode: "WORKER_UNEXPECTED_EXIT",
            message: makeUnexpectedExitMessage(
                status: process.terminationStatus,
                rawWorkerLines: rawWorkerLines,
                pythonExecutable: launchCommand.executable,
                workerScriptPath: scriptPath
            )
        )
    }

    private func handleWorkerLine(
        _ line: String,
        decoder: JSONDecoder,
        onProgress: @escaping ProgressHandler,
        finalResult: inout WorkerResult?,
        rawWorkerLines: inout [String]
    ) {
        guard !line.isEmpty else { return }
        if let progress = try? decoder.decode(WorkerProgressEvent.self, from: Data(line.utf8)), progress.type == "progress" {
            let message = progress.message ?? progress.stage ?? "Working"
            onProgress(message)
            return
        }

        if let result = try? decoder.decode(WorkerResult.self, from: Data(line.utf8)), result.type == "result" {
            finalResult = result
            return
        }

        rawWorkerLines.append(line)
        if rawWorkerLines.count > 30 {
            rawWorkerLines.removeFirst(rawWorkerLines.count - 30)
        }
    }

    private func resolvePythonLaunchCommand(scriptPath: String) -> (executable: String, arguments: [String]) {
        let workerDirectory = URL(fileURLWithPath: scriptPath).deletingLastPathComponent()
        let venvPython = workerDirectory
            .appendingPathComponent(".venv/bin/python3")
            .path
        if FileManager.default.fileExists(atPath: venvPython) {
            if isWorkerEnvironmentReady(pythonExecutable: venvPython) {
                return (venvPython, [])
            }

            if isPackagedWorkerScriptPath(scriptPath) {
                return (venvPython, [])
            }
        }
        return ("/usr/bin/env", ["python3"])
    }

    private func isPackagedWorkerScriptPath(_ scriptPath: String) -> Bool {
        let normalizedPath = (scriptPath as NSString).standardizingPath
        return normalizedPath.contains(".app/Contents/Resources/worker/main.py")
    }

    private func isWorkerEnvironmentReady(pythonExecutable: String) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.executableURL = URL(fileURLWithPath: pythonExecutable)
        process.arguments = ["-c", Self.readinessProbeScript]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func makeUnexpectedExitMessage(
        status: Int32,
        rawWorkerLines: [String],
        pythonExecutable: String,
        workerScriptPath: String
    ) -> String {
        let tail = rawWorkerLines.last ?? ""
        let runtimeInfo = "python executable: \(pythonExecutable), worker script: \(workerScriptPath)"
        if !tail.isEmpty {
            return "Worker exited with status \(status): \(tail) [\(runtimeInfo)]"
        }
        return "Worker exited with status \(status) [\(runtimeInfo)]"
    }

    private func writeTempConfig(_ config: WorkerConfig) throws -> URL {
        let data = try JSONEncoder().encode(config)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppy-worker-config-\(UUID().uuidString)")
            .appendingPathExtension("json")
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    private func resolveWorkerScriptPath() throws -> String {
        if let resourceURL = Bundle.main.resourceURL {
            let fromBundleResources = resourceURL.appendingPathComponent("worker/main.py")
            if FileManager.default.fileExists(atPath: fromBundleResources.path) {
                return fromBundleResources.path
            }
        }

        let cwdPath = FileManager.default.currentDirectoryPath
        let fromCwd = URL(fileURLWithPath: cwdPath)
            .appendingPathComponent("worker/main.py")
        if FileManager.default.fileExists(atPath: fromCwd.path) {
            return fromCwd.path
        }

        let fromExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("worker/main.py")
        if FileManager.default.fileExists(atPath: fromExecutable.path) {
            return fromExecutable.path
        }

        throw NSError(domain: "Oppy", code: 4001, userInfo: [NSLocalizedDescriptionKey: "Could not locate worker/main.py"])
    }
}

extension WorkerLauncher: @unchecked Sendable {}
