//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation

/// Output keying mode for ATEM integration.
///
/// - `lumaKey`: Single output on black. ATEM DSK uses luma/self key.
///   Simple setup, but semi-transparent panels key out since they're dark.
///
/// - `fillAndKey`: Two outputs — Fill (normal graphic) + Key (white matte).
///   ATEM DSK linear key uses Fill for color, Key for transparency.
///   Cleanest results. Requires two HDMI outputs into two ATEM inputs.
enum KeyMode: String, Codable, CaseIterable, Identifiable {
    case lumaKey
    case fillAndKey

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lumaKey:    return "Luma Key"
        case .fillAndKey: return "Fill + Key"
        }
    }

    var description: String {
        switch self {
        case .lumaKey:
            return "Single HDMI output. Black = transparent. Use ATEM DSK luma/self key."
        case .fillAndKey:
            return "Two HDMI outputs. Fill (color) + Key (matte). Use ATEM DSK linear key."
        }
    }

    var sfSymbol: String {
        switch self {
        case .lumaKey:    return "tv"
        case .fillAndKey: return "rectangle.on.rectangle"
        }
    }
}
