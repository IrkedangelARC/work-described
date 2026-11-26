//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import XCTest
@testable import ArcGrabTests

final class TranscriptTests: XCTestCase {
    func testWhisperArgs() {
        let a = CommandBuilder.whisperArgs(model: "/m/turbo.bin", vadModel: "/m/vad.bin", input: "/t/in.wav", outputBase: "/d/Title [id]", threads: 8)
        XCTAssertEqual(a.prefix(4), ["-m", "/m/turbo.bin", "-f", "/t/in.wav"])
        XCTAssertTrue(a.contains("-mc") && a.contains("0"), "no text context between windows (loop guard)")
        XCTAssertTrue(a.contains("--vad") && a.contains("/m/vad.bin"))
        XCTAssertTrue(a.contains("-osrt") && a.contains("/d/Title [id]"))
        XCTAssertFalse(a.contains("-otxt"), "the .txt is paragraphed from the SRT, not whisper's own")
        XCTAssertTrue(a.contains("auto"))
        let b = CommandBuilder.whisperArgs(model: "m", vadModel: nil, input: "i", outputBase: "o", threads: 0)
        XCTAssertFalse(b.contains("--vad"))
        XCTAssertTrue(b.contains("1"), "thread floor")
    }

    func testWhisperWavArgs() {
        let a = CommandBuilder.whisperWavArgs(input: "in.mp4", output: "/tmp/x.wav")
        XCTAssertTrue(a.contains("16000") && a.contains("pcm_s16le") && a.contains("-vn"))
        XCTAssertEqual(a.last, "/tmp/x.wav")
        if let i = a.firstIndex(of: "-ac") { XCTAssertEqual(a[i + 1], "1") } else { XCTFail("mono") }
    }

    func testWhisperProgressLine() {
        XCTAssertEqual(ProgressParser.parseWhisperProgress("whisper_print_progress_callback: progress =  42%"), 0.42)
        XCTAssertEqual(ProgressParser.parseWhisperProgress("whisper_print_progress_callback: progress = 100%"), 1)
        XCTAssertNil(ProgressParser.parseWhisperProgress("[00:00:00.000 --> 00:00:02.000]   Hello"))
    }

    func testModelURLsAndGate() {
        XCTAssertEqual(ModelFetcher.whisper.url.absoluteString,
                       "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(ModelFetcher.vad.url.absoluteString,
                       "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")
        // a 15-byte "Entry not found" body must not count as a model
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("arcgrab-models-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? "Entry not found".write(to: tmp.appendingPathComponent(ModelFetcher.vad.file), atomically: true, encoding: .utf8)
        XCTAssertFalse(ModelFetcher.isPresent(ModelFetcher.vad, in: tmp))
        XCTAssertFalse(ModelFetcher.allPresent(in: tmp))
    }

    func testSRTParse() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,500
        Hello there,
        second line.

        2
        00:01:02.300 --> 00:01:04,000
        Next cue.

        """
        let s = Transcript.parseSRT(srt)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].text, "Hello there, second line.")
        XCTAssertEqual(s[0].end, 2.5)
        XCTAssertEqual(s[1].start, 62.3, accuracy: 0.001)
    }

    func testParagraphingBreaksOnPauseAndCaps() {
        let sentence = String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces)  // 99 chars
        var segs: [Transcript.Segment] = []
        var t = 0.0
        // 3 sentences back to back (~300 chars), then a 3 s pause, then more
        for _ in 0..<3 { segs.append(.init(start: t, end: t + 4, text: sentence)); t += 4 }
        t += 3
        for _ in 0..<2 { segs.append(.init(start: t, end: t + 4, text: sentence)); t += 4 }
        let paras = Transcript.paragraphs(segs)
        XCTAssertEqual(paras.count, 2, "long pause after minLen splits")
        XCTAssertEqual(paras[0].count, 299)
        // a short pause before minLen never splits
        let early = Transcript.paragraphs([.init(start: 0, end: 1, text: "a"), .init(start: 5, end: 6, text: "b")])
        XCTAssertEqual(early, ["a b"])
        // no pauses at all: hard cap still breaks
        let wall = (0..<12).map { i in Transcript.Segment(start: Double(i), end: Double(i + 1), text: sentence) }
        let capped = Transcript.paragraphs(wall)
        XCTAssertGreaterThan(capped.count, 1)
        XCTAssertTrue(capped.allSatisfy { $0.count < Transcript.hardCap + 100 })
        XCTAssertFalse(capped.joined().contains("\n"), "one paragraph per line, no hard wraps")
    }

    func testOptionsDecodeTolerantOfMissingKeys() throws {
        let old = #"{"mode":"audio","audioFormat":"mp3","destination":"/x"}"#
        let o = try JSONDecoder().decode(GrabOptions.self, from: Data(old.utf8))
        XCTAssertEqual(o.mode, .audio); XCTAssertEqual(o.audioFormat, .mp3); XCTAssertEqual(o.destination, "/x")
        XCTAssertFalse(o.transcript); XCTAssertTrue(o.chapters)
        var t = GrabOptions(); t.transcript = true
        XCTAssertTrue(t.targetLabel.hasSuffix("+ TXT"))
    }
}
