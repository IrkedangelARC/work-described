import Foundation

enum TranscriberError: LocalizedError {
    case engineMissing
    case modelMissing
    case cancelled
    case failed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .engineMissing:
            return "whisper-cli not found. Install it with: brew install whisper-cpp"
        case .modelMissing:
            return "No whisper model found. Put ggml-large-v3-turbo-q5_0.bin in ~/Library/Application Support/ARC Dictate/models/"
        case .cancelled:
            return "Cancelled."
        case .failed(let code, let message):
            return "whisper-cli exited \(code): \(message)"
        }
    }
}

/// Where the engine and models live, and how raw whisper output is tidied.
enum Transcriber {

    private static let fileManager = FileManager.default

    static var supportDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ARC Dictate", isDirectory: true)
    }

    /// ARC Grab carries the whisper-cli binary, so Dictate borrows it rather than shipping a
    /// second copy. Grab does NOT live in one fixed place: fleet policy installs every ARC app
    /// to ~/Desktop and only the office workstation has it in /Applications, so BOTH are searched. Looking
    /// in /Applications alone meant Dictate ran on the office workstation and nowhere else (2026-09-22).
    private static var grabEngines: [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Desktop/ARC Grab.app/Contents/MacOS/whisper-cli"),
                URL(fileURLWithPath: "/Applications/ARC Grab.app/Contents/MacOS/whisper-cli"),
                home.appendingPathComponent("Applications/ARC Grab.app/Contents/MacOS/whisper-cli")]
    }

    private static var searchedEngines: [URL] {
        [supportDirectory.appendingPathComponent("engine/whisper-cli")]
            + grabEngines
            + [URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
               URL(fileURLWithPath: "/usr/local/bin/whisper-cli")]
    }

    private static var searchedModels: [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [supportDirectory.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin"),
                home.appendingPathComponent("Library/Application Support/ARC Grab/models/ggml-large-v3-turbo-q5_0.bin"),
                home.appendingPathComponent("models/whisper/ggml-large-v3-turbo-q5_0.bin"),
                home.appendingPathComponent("models/whisper/ggml-large-v3.bin")]
    }

    private static var searchedVADModels: [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [supportDirectory.appendingPathComponent("models/ggml-silero-v5.1.2.bin"),
                home.appendingPathComponent("Library/Application Support/ARC Grab/models/ggml-silero-v5.1.2.bin"),
                home.appendingPathComponent("models/whisper/ggml-silero-v5.1.2.bin")]
    }

    static func locateEngine() -> URL? { searchedEngines.first { fileManager.isExecutableFile(atPath: $0.path) } }
    static func locateModel() -> URL? { searchedModels.first { fileManager.fileExists(atPath: $0.path) } }
    static func locateVADModel() -> URL? { searchedVADModels.first { fileManager.fileExists(atPath: $0.path) } }

    /// whisper marks non-speech with bracketed tags such as [BLANK_AUDIO] or (wind blowing).
    /// It can also echo the initial prompt back when a take is nearly silent. Neither belongs
    /// in dictation, so drop both.
    static func clean(_ raw: String, prompt: String? = nil) -> String {
        let promptHead = prompt.map { String($0.prefix(30)).lowercased() }

        let lines = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line.hasPrefix("[") && line.hasSuffix("]") { return false }
                if line.hasPrefix("(") && line.hasSuffix(")") { return false }
                if let promptHead, line.lowercased().hasPrefix(promptHead) { return false }
                return true
            }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One run of whisper.cpp, cancellable.
///
/// The flags follow the recipe that ARC Grab proved out: VAD on, and `-mc 0` so there is no
/// previous-text conditioning. Context conditioning is what makes whisper.cpp loop a phrase
/// forever when it hits silence.
final class TranscriptionJob {

    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    /// Blocking. Call it off the main thread.
    func run(audio: URL, language: String, prompt: String?) throws -> String {
        guard let engine = Transcriber.locateEngine() else { throw TranscriberError.engineMissing }
        guard let model = Transcriber.locateModel() else { throw TranscriberError.modelMissing }

        var arguments = ["-m", model.path,
                         "-f", audio.path,
                         "-l", language,
                         "-t", "8",
                         "-sns",
                         "-nt",
                         "-np"]

        if let vad = Transcriber.locateVADModel() {
            arguments += ["--vad", "-vm", vad.path]
        }

        if let prompt, !prompt.isEmpty {
            // Budget sized to the prompt exactly: vocabulary in, rolling context out.
            // See PromptBudget for why this is not simply `-mc 0`.
            let tokens = PromptBudget.tokenCount(for: prompt, engine: engine, model: model)
            arguments += ["--prompt", prompt,
                          "--carry-initial-prompt",
                          "-mc", String(PromptBudget.maxContext(forTokenCount: tokens))]
        } else {
            arguments += ["-mc", "0"]
        }

        let process = Process()
        process.executableURL = engine
        process.arguments = arguments

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        lock.lock()
        if isCancelled {
            lock.unlock()
            throw TranscriberError.cancelled
        }
        self.process = process
        lock.unlock()

        try process.run()

        // Read both pipes before waiting, or a full pipe buffer deadlocks the child.
        let stdoutData = output.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        lock.lock()
        let cancelled = isCancelled
        self.process = nil
        lock.unlock()

        if cancelled { throw TranscriberError.cancelled }

        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8)?
                .split(separator: "\n").suffix(3).joined(separator: " ") ?? ""
            throw TranscriberError.failed(process.terminationStatus, message)
        }

        return Transcriber.clean(String(data: stdoutData, encoding: .utf8) ?? "", prompt: prompt)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let running = process
        lock.unlock()
        running?.terminate()
    }
}
