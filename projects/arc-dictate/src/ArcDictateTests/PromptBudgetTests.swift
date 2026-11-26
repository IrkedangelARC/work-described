import XCTest
@testable import ARC_Dictate

final class PromptBudgetTests: XCTestCase {

    /// The whole point of the budget: prompt tokens plus one, so whisper's
    /// `n_take1 = max_prompt_ctx - n_take0 - 1` lands on zero and no rolling context is
    /// carried. Anything larger reopens the loop-hallucination path.
    func testMaxContextLeavesNoRoomForRollingContext() {
        XCTAssertEqual(PromptBudget.maxContext(forTokenCount: 133), 134)
        let budget = PromptBudget.maxContext(forTokenCount: 133)
        let takeFromPrompt = min(133, budget - 1)
        let takeFromHistory = budget - takeFromPrompt - 1
        XCTAssertEqual(takeFromPrompt, 133)
        XCTAssertEqual(takeFromHistory, 0)
    }

    func testMaxContextNeverDropsToZero() {
        // -mc 0 would disable the prompt entirely, which is the bug this class exists for.
        XCTAssertGreaterThanOrEqual(PromptBudget.maxContext(forTokenCount: 0), 2)
        XCTAssertGreaterThanOrEqual(PromptBudget.maxContext(forTokenCount: 1), 2)
    }

    func testParsesTokenCountFromWhisperWarning() {
        let log = """
        whisper_init_from_file_with_params_no_state: loading model
        whisper_full_with_state: initial prompt is too long (133 tokens), will use only the last 1 tokens
        """
        XCTAssertEqual(PromptBudget.parseTokenCount(from: log), 133)
    }

    func testParseReturnsNilWhenThereIsNoWarning() {
        XCTAssertNil(PromptBudget.parseTokenCount(from: "whisper_print_timings: total time = 512 ms"))
    }

    /// The measured ratio for a comma list of proper nouns was 348 characters to 133 tokens,
    /// about 2.6. The estimate must not come out under that or the vocabulary gets truncated.
    func testEstimateIsNotBelowTheMeasuredRatio() {
        let estimate = PromptBudget.estimatedTokenCount(for: String(repeating: "x", count: 348))
        XCTAssertGreaterThanOrEqual(estimate, 133)
    }

    func testEstimateHandlesEmptyString() {
        XCTAssertGreaterThanOrEqual(PromptBudget.estimatedTokenCount(for: ""), 1)
    }

    func testSilenceWAVHasAValidHeader() {
        let data = PromptBudget.silenceWAV(frames: 3_200, sampleRate: 16_000)

        XCTAssertEqual(data.count, 44 + 6_400)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")

        func readUInt32(at offset: Int) -> UInt32 {
            data[offset..<(offset + 4)].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        XCTAssertEqual(readUInt32(at: 4), UInt32(36 + 6_400))    // RIFF size
        XCTAssertEqual(readUInt32(at: 24), 16_000)               // sample rate
        XCTAssertEqual(readUInt32(at: 40), 6_400)                // data size
        XCTAssertTrue(data[44...].allSatisfy { $0 == 0 })        // actually silent
    }

    /// End to end against the real engine, when one is installed.
    func testMeasuresTheRealPromptTokenCount() throws {
        guard let engine = Transcriber.locateEngine(), let model = Transcriber.locateModel() else {
            throw XCTSkip("whisper-cli or model not installed")
        }
        let prompt = Vocabulary.buildPrompt(from: Vocabulary.seed)!
        let tokens = PromptBudget.tokenCount(for: prompt, engine: engine, model: model)
        XCTAssertGreaterThan(tokens, 50)
        XCTAssertLessThan(tokens, 400)
    }
}
