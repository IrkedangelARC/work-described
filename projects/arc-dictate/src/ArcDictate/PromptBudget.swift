import CryptoKit
import Foundation

/// Sizes whisper's text-context budget around the vocabulary prompt.
///
/// This is fiddly but it matters. whisper.cpp only builds a prompt at all when
/// `n_max_text_ctx > 0`, so the `-mc 0` that protects against loop hallucination also throws
/// the vocabulary away — the two settings are in direct conflict.
///
/// This build keeps the initial prompt (`prompt_past0`) separate from rolling decoded text
/// (`prompt_past1`) and fills the budget with the prompt first:
///
///     n_take1 = max_prompt_ctx - n_take0 - 1
///
/// So setting the budget to exactly `prompt tokens + 1` gives the vocabulary its full weight
/// and leaves **zero** rolling context — no previous-text conditioning, no loop reinforcement.
/// Both properties at once.
///
/// The token count cannot be guessed: a list of proper nouns measured 2.6 characters per
/// token, not the 3-4 that ordinary prose gives. So it is measured once per prompt, by asking
/// whisper itself, and cached.
enum PromptBudget {

    private static let cacheKey = "promptTokenCounts"

    /// The `-mc` value for a prompt of this many tokens.
    static func maxContext(forTokenCount tokens: Int) -> Int {
        max(tokens + 1, 2)
    }

    /// Fallback when the measurement cannot run. Deliberately slightly generous: too low
    /// truncates the vocabulary, too high only lets a few tokens of rolling context in.
    static func estimatedTokenCount(for prompt: String) -> Int {
        max(1, Int((Double(prompt.count) / 2.5).rounded(.up)))
    }

    /// Measured token count for `prompt`, cached across launches.
    static func tokenCount(for prompt: String, engine: URL, model: URL) -> Int {
        let key = digest(of: prompt)

        var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Int] ?? [:]
        if let cached = cache[key] { return cached }

        guard let measured = measure(prompt: prompt, engine: engine, model: model) else {
            return estimatedTokenCount(for: prompt)
        }

        // Keep the cache from growing without bound as the list is edited.
        if cache.count > 20 { cache.removeAll() }
        cache[key] = measured
        UserDefaults.standard.set(cache, forKey: cacheKey)
        return measured
    }

    /// Asks whisper to tokenize the prompt by giving it a budget of one token: it then warns
    /// how many tokens the prompt really was. Runs against 0.2 s of silence, so it costs one
    /// model load and nothing else.
    private static func measure(prompt: String, engine: URL, model: URL) -> Int? {
        guard let silence = try? writeSilenceFile() else { return nil }
        defer { try? FileManager.default.removeItem(at: silence) }

        let process = Process()
        process.executableURL = engine
        process.arguments = ["-m", model.path,
                             "-f", silence.path,
                             "-l", "en",
                             "-mc", "2",
                             "--carry-initial-prompt",
                             "-nt",
                             "--prompt", prompt]

        let errors = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return parseTokenCount(from: String(data: data, encoding: .utf8) ?? "")
    }

    /// Pulls the count out of "initial prompt is too long (133 tokens), will use only …".
    static func parseTokenCount(from log: String) -> Int? {
        guard let range = log.range(of: #"initial prompt is too long \((\d+) tokens\)"#,
                                    options: .regularExpression) else { return nil }
        let match = log[range]
        let digits = match.filter(\.isNumber)
        return Int(digits)
    }

    /// 0.2 s of 16 kHz mono silence, written by hand so this does not need ffmpeg.
    static func writeSilenceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arc-dictate-silence-\(UUID().uuidString).wav")
        try silenceWAV(frames: 3_200, sampleRate: 16_000).write(to: url)
        return url
    }

    /// A minimal 16-bit mono PCM WAV.
    static func silenceWAV(frames: Int, sampleRate: Int) -> Data {
        let dataBytes = frames * 2
        var data = Data()

        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + dataBytes))
        append("WAVE")
        append("fmt ")
        append32(16)                                  // PCM chunk size
        append16(1)                                   // PCM
        append16(1)                                   // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))              // byte rate
        append16(2)                                   // block align
        append16(16)                                  // bits per sample
        append("data")
        append32(UInt32(dataBytes))
        data.append(Data(count: dataBytes))

        return data
    }

    private static func digest(of string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
