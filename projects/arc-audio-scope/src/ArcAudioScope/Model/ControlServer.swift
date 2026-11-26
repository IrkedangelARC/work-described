//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Network

/// Control API on 127.0.0.1:8767 (the port docs/REUSE_karaoke.md reserved for the scope).
/// Everything the screen shows is readable here, so a test never depends on someone's eyes.
///
///   GET /state                         every reading, input status, device list, consent, scope settings
///   GET /spectrum                      the RTA bars as drawn: band centres, levels, peaks, ring time trace
///   GET /rings                         rings sounding now and the ring-out log
///   GET /set?weighting=A|C|Z           also response=FAST|SLOW, mic=1|2, device=<name>, layout=RINGOUT|ALIGN|SPL,
///                                      bands=3|6|12|24, avg=NONE|FAST|SLOW|INF, peakhold=0|1, floor=<dBFS>,
///                                      ceiling=<dBFS>, span=5|10|20|40, map=SMAART|INFERNO|GREY, ring=0|1,
///                                      test=0|1 (TEST SIGNAL in place of the mic), freeze=0|1, scrub=<seconds>,
///                                      harmonic=0|1 (skip played notes), fmin=<Hz> fmax=<Hz> or zoom=reset (frequency axis),
///                                      cursor=<Hz>|off (the readout card)
///   GET /reset                         restart Leq, Lmax, LCpeak, peaks, clip counts and the RTA traces
///   GET /capture                       keep the bars as a trace (?slot=1...8, default the first free)
///   GET /traces                        the captured traces as drawn
///   GET /trace?slot=N                  with visible=0|1, reference=1 or delete=1; /set?diff=1 shows live minus reference,
///                                      /set?style=BARS|LINE
///   GET /miccorrection?path=<file>     load the mic response file (or ?clear=1)
///   GET /tf                            the transfer function as drawn (magnitude, phase, coherence per 1/24 octave)
///                                      and the delay and generator state; needs /set?layout=ALIGN. Also /set?ref=GEN|INPUT,
///                                      tfavg=1|2|4|8|0 (seconds, 0 = infinite), coh=<0...1 blanking threshold>, temp=<deg C>
///   GET /delay                         ?find=1 measures and applies it, ?ms= or ?samples= sets it, ?track=0|1
///   GET /generator                     ?on=0|1, signal=PINK|WHITE|SINE|SWEEP, level=<dBFS RMS>, hz=<sine>, out=1|2|both
///   GET /tfcapture                     keep the transfer function as a trace (?slot=1...8); /tftrace?slot=N with visible=0|1
///                                      or delete=1. Also /set?tfsmooth=24|12|6|3 (24 = off), unwrap=0|1
///   GET /show                          the show in use and the list; ?new=NAME, saveas=NAME, open=NAME, notes=<text>, panel=0|1
///   GET /export                        write the CSVs, show.txt, screen.png and screen.pdf; answers with the folder
///   GET /events                        the show's event list (clips, distortion warnings, show changes)
///   GET /clearlog                      empty the ring-out log
///   GET /mark                          "I hear a ring": analyse the last 4 seconds (same as spacebar); result in /rings lastMark
///   GET /playmark                      play the 4 seconds the last mark analysed on the computer's own output
///       ?back=12&hz=2400               what a click on the frozen waterfall does: 4 seconds centred 12 s back, a line near 2400 Hz first
///   GET /restart                       stop and start the audio engine
///   GET /waterfall.png                 the waterfall exactly as drawn (also ?w=&h= in pixels)
///   GET /screen.png                    the whole window as drawn (Mac)
///
/// Loopback only: nothing off this machine can reach it.
final class ControlServer {
    static let port: UInt16 = 8767
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.example.arc.ArcAudioScope.control")
    enum Reply {
        case json([String: Any])
        case data(Data, type: String)
    }

    /// Runs on the main queue. Path and query in, reply out (nil = 404).
    private let handler: (String, [String: String]) -> Reply?

    init(handler: @escaping (String, [String: String]) -> Reply?) { self.handler = handler }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: queue)
        listener = l
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let line = String(data: data, encoding: .utf8)?.split(separator: "\r\n").first else { c.cancel(); return }
            let parts = line.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            let comps = URLComponents(string: target)
            var query: [String: String] = [:]
            for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
            let path = comps?.path ?? "/"
            DispatchQueue.main.async {
                let result = self.handler(path, query)
                var body = Data(), type = "application/json"
                switch result {
                case .json(let object):
                    body = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                case .data(let data, let t):
                    body = data; type = t
                case nil:
                    body = (try? JSONSerialization.data(withJSONObject: ["error": "unknown path \(path)"])) ?? Data()
                }
                let head = "HTTP/1.1 \(result == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                c.send(content: head.data(using: .utf8)! + body, completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }
}
