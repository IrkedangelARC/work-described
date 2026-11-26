import Foundation
import Accelerate

/// High-performance FFT processor using vDSP (Accelerate framework)
/// Converts time-domain audio samples to frequency-domain magnitudes
final class FFTProcessor {

    // MARK: - Configuration

    /// FFT size (4096 samples = ~85ms at 48kHz, good frequency resolution)
    let fftSize: Int

    /// Half the FFT size (number of unique frequency bins)
    let halfFFTSize: Int

    /// Sample rate in Hz
    let sampleRate: Double

    /// Frequency resolution (Hz per bin)
    var frequencyResolution: Double {
        sampleRate / Double(fftSize)
    }

    // MARK: - vDSP Setup

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    /// Hann window for reducing spectral leakage
    private var window: [Float]

    /// Split complex buffer for FFT
    private var splitComplex: DSPSplitComplex
    private var realBuffer: [Float]
    private var imagBuffer: [Float]

    /// Temporary buffers
    private var windowedSamples: [Float]

    // MARK: - Initialization

    init(fftSize: Int = 4096, sampleRate: Double = 48000) {
        self.fftSize = fftSize
        self.halfFFTSize = fftSize / 2
        self.sampleRate = sampleRate

        // Calculate log2 of FFT size
        self.log2n = vDSP_Length(log2(Double(fftSize)))

        // Create FFT setup
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create FFT setup")
        }
        self.fftSetup = setup

        // Initialize buffers
        self.realBuffer = [Float](repeating: 0, count: halfFFTSize)
        self.imagBuffer = [Float](repeating: 0, count: halfFFTSize)
        self.splitComplex = DSPSplitComplex(realp: &realBuffer, imagp: &imagBuffer)
        self.windowedSamples = [Float](repeating: 0, count: fftSize)

        // Create Hann window
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Processing

    /// Process audio samples and return magnitude spectrum in dB
    /// - Parameter samples: Time-domain audio samples (should be fftSize samples)
    /// - Returns: Array of magnitudes in dB for each frequency bin (halfFFTSize values)
    func process(_ samples: [Float]) -> [Float] {
        guard samples.count >= fftSize else {
            return [Float](repeating: Theme.dbMin, count: halfFFTSize)
        }

        // Apply window function
        vDSP_vmul(samples, 1, window, 1, &windowedSamples, 1, vDSP_Length(fftSize))

        // Convert to split complex format
        windowedSamples.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfFFTSize) { complexPtr in
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfFFTSize))
            }
        }

        // Perform forward FFT
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

        // Calculate magnitudes
        var magnitudes = [Float](repeating: 0, count: halfFFTSize)
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfFFTSize))

        // Scale and convert to dB
        // Scale factor: 1/(fftSize^2) for power, then 10*log10 for dB
        var scaleFactor = Float(1.0 / Double(fftSize * fftSize))
        vDSP_vsmul(magnitudes, 1, &scaleFactor, &magnitudes, 1, vDSP_Length(halfFFTSize))

        // Convert to dB (10 * log10)
        var minValue: Float = 1e-10 // Avoid log(0)
        vDSP_vthr(magnitudes, 1, &minValue, &magnitudes, 1, vDSP_Length(halfFFTSize))

        var one: Float = 1.0
        var count = Int32(halfFFTSize)
        vvlog10f(&magnitudes, magnitudes, &count)
        var ten: Float = 10.0
        vDSP_vsmul(magnitudes, 1, &ten, &magnitudes, 1, vDSP_Length(halfFFTSize))

        return magnitudes
    }

    /// Get the frequency for a given bin index
    func frequency(for binIndex: Int) -> Double {
        return Double(binIndex) * frequencyResolution
    }

    /// Get the bin index for a given frequency
    func binIndex(for frequency: Double) -> Int {
        return Int(frequency / frequencyResolution)
    }

    /// Get bin indices that fall within a frequency range
    func binIndices(from lowerFreq: Double, to upperFreq: Double) -> Range<Int> {
        let lowerBin = max(0, binIndex(for: lowerFreq))
        let upperBin = min(halfFFTSize, binIndex(for: upperFreq) + 1)
        return lowerBin..<upperBin
    }
}
