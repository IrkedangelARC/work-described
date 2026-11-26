#
#  Copyright (c) 2025-2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""
Wireless Microphone Frequency Coordinator

Analyzes occupied RF spectrum and finds open frequencies for wireless microphones,
with support for both 10mW and 20mW transmitters and IMD prediction.
"""

import pandas as pd
import numpy as np
from pathlib import Path
from typing import List, Tuple, Optional
import sys
import argparse

try:
    from ..config import config
except ImportError:
    # Fallback for standalone execution
    config = None


class WirelessMicFinder:
    """Find open frequencies for wireless microphones"""

    def __init__(
        self,
        input_file: str,
        output_file: str = None,
        power: int = 20,
        min_spacing: float = 0.6,
    ):
        """
        Initialize the wireless mic finder

        Args:
            input_file: Path to Excel file with occupied frequencies
            output_file: Path for output Excel file (optional)
            power: Transmitter power in mW (10 or 20)
            min_spacing: Minimum spacing between frequencies in MHz
        """
        self.input_file = Path(input_file)
        self.output_file = Path(output_file) if output_file else None
        self.power = power
        self.min_spacing = min_spacing

        self.df = None
        self.occupied_freq = []
        self.open_freq_10mw = []
        self.open_freq_20mw = []
        self.empty_spaces = []
        self.imd_predictions = []

    def load_frequencies(self):
        """Load and sort occupied frequencies from Excel file"""
        if not self.input_file.exists():
            raise FileNotFoundError(f"Input file not found: {self.input_file}")

        # Read the spreadsheet
        self.df = pd.read_excel(
            self.input_file, dtype={'Frequency (MHz)': float}
        )

        # Ensure 'Frequency (MHz)' column exists
        if 'Frequency (MHz)' not in self.df.columns:
            raise ValueError("Excel file must have a 'Frequency (MHz)' column")

        # Sort frequencies
        self.df = self.df.sort_values(by='Frequency (MHz)')
        self.occupied_freq = self.df['Frequency (MHz)'].tolist()

        print(f"Loaded {len(self.occupied_freq)} occupied frequencies")
        print(f"Range: {min(self.occupied_freq):.3f} - {max(self.occupied_freq):.3f} MHz")

    def check_frequency_spacing(self):
        """Check if frequencies are evenly spaced"""
        if len(self.occupied_freq) < 2:
            return

        freq_diffs = np.diff(self.occupied_freq)
        if np.allclose(freq_diffs, np.mean(freq_diffs), rtol=0.05):
            print("Frequencies are evenly spaced")
        else:
            print("Frequencies are NOT evenly spaced")

    def calculate_empty_spaces(self):
        """Calculate empty space between occupied frequencies"""
        self.empty_spaces = []

        for i in range(1, len(self.occupied_freq)):
            space_size = self.occupied_freq[i] - self.occupied_freq[i - 1]
            center_freq = self.occupied_freq[i - 1] + space_size / 2

            if space_size > self.min_spacing:
                self.empty_spaces.append((space_size, center_freq))

        # Sort by space size (largest first)
        self.empty_spaces.sort(reverse=True)

    def find_open_frequencies_10mw(self):
        """Find open frequencies for 10mW transmitters"""
        min_freq = int(min(self.occupied_freq))
        max_freq = int(max(self.occupied_freq))

        # Create list of potentially open frequencies
        potential_freq = []
        for space_size, center_freq in self.empty_spaces:
            if space_size >= 1.0:  # At least 1 MHz space
                potential_freq.append(center_freq)

        # Sort by largest empty space
        self.open_freq_10mw = potential_freq

    def find_open_frequencies_20mw(self):
        """Find open frequencies for 20mW transmitters"""
        # 20mW requires more spacing (check adjacent frequencies)
        self.open_freq_20mw = []

        for freq in self.open_freq_10mw:
            # Check if freq±1 and freq±2 are also clear
            if all(
                abs(freq - occ) > 2.0 for occ in self.occupied_freq
            ):
                self.open_freq_20mw.append(freq)

    def predict_imd(self):
        """
        Predict Intermodulation Distortion (IMD) for 20mW frequencies

        IMD occurs when two transmitters create interference at:
        f3 = f2 + (f2 - f1)
        """
        self.imd_predictions = []

        for i in range(len(self.open_freq_20mw) - 1):
            for j in range(i + 1, len(self.open_freq_20mw)):
                f1 = self.open_freq_20mw[i]
                f2 = self.open_freq_20mw[j]
                imd_freq = f2 + (f2 - f1)

                # Check if IMD frequency conflicts with open or occupied frequencies
                if imd_freq in self.open_freq_20mw or any(
                    abs(imd_freq - occ) < 0.5 for occ in self.occupied_freq
                ):
                    self.imd_predictions.append((f1, f2, imd_freq))

    def generate_report(self) -> str:
        """Generate text report of findings"""
        report = []
        report.append("=" * 70)
        report.append("WIRELESS MICROPHONE FREQUENCY COORDINATION REPORT")
        report.append("=" * 70)
        report.append("")

        # Occupied frequencies
        report.append(f"Occupied Frequencies: {len(self.occupied_freq)}")
        report.append(f"Range: {min(self.occupied_freq):.3f} - {max(self.occupied_freq):.3f} MHz")
        report.append("")

        # Empty spaces
        report.append("LARGEST EMPTY SPACES:")
        report.append("-" * 70)
        for i, (space, freq) in enumerate(self.empty_spaces[:10], 1):
            report.append(f"{i:2d}. {freq:7.3f} MHz - {space:.3f} MHz empty space")
        report.append("")

        # 10mW frequencies
        report.append(f"OPEN FREQUENCIES FOR 10mW TRANSMITTERS: {len(self.open_freq_10mw)}")
        report.append("-" * 70)
        for i, freq in enumerate(self.open_freq_10mw[:20], 1):
            report.append(f"{i:2d}. {freq:.3f} MHz")
        report.append("")

        # 20mW frequencies
        report.append(f"OPEN FREQUENCIES FOR 20mW TRANSMITTERS: {len(self.open_freq_20mw)}")
        report.append("-" * 70)
        for i, freq in enumerate(self.open_freq_20mw[:20], 1):
            report.append(f"{i:2d}. {freq:.3f} MHz")
        report.append("")

        # IMD predictions
        if self.imd_predictions:
            report.append("INTERMODULATION DISTORTION WARNINGS:")
            report.append("-" * 70)
            for f1, f2, imd in self.imd_predictions[:10]:
                report.append(f"{f1:.3f} MHz + {f2:.3f} MHz = {imd:.3f} MHz (IMD)")
            report.append("")
            report.append(f"Total IMD conflicts: {len(self.imd_predictions)}")
            report.append("Consider using frequencies with no IMD conflicts")
        else:
            report.append("No Intermodulation Distortion detected!")

        report.append("")
        report.append("=" * 70)

        return "\n".join(report)

    def export_to_excel(self):
        """Export results to Excel file"""
        if not self.output_file:
            self.output_file = self.input_file.parent / "open_frequencies.xlsx"

        # Create DataFrames for each result set
        data = {
            'Empty Spaces': pd.DataFrame({
                'Center Frequency (MHz)': [freq for _, freq in self.empty_spaces],
                'Space Size (MHz)': [space for space, _ in self.empty_spaces],
            }),
            '10mW Open Frequencies': pd.DataFrame({
                'Frequency (MHz)': self.open_freq_10mw,
            }),
            '20mW Open Frequencies': pd.DataFrame({
                'Frequency (MHz)': self.open_freq_20mw,
            }),
        }

        if self.imd_predictions:
            data['IMD Predictions'] = pd.DataFrame(
                self.imd_predictions,
                columns=['Frequency 1 (MHz)', 'Frequency 2 (MHz)', 'IMD Frequency (MHz)']
            )

        # Write to Excel with multiple sheets
        with pd.ExcelWriter(self.output_file, engine='openpyxl') as writer:
            for sheet_name, df in data.items():
                df.to_excel(writer, sheet_name=sheet_name, index=False)

        print(f"\nResults exported to: {self.output_file}")

    def run(self):
        """Run the complete analysis"""
        print("Loading frequencies...")
        self.load_frequencies()

        print("\nAnalyzing frequency spacing...")
        self.check_frequency_spacing()

        print("\nCalculating empty spaces...")
        self.calculate_empty_spaces()

        print("\nFinding open frequencies for 10mW transmitters...")
        self.find_open_frequencies_10mw()

        print(f"Finding open frequencies for 20mW transmitters...")
        self.find_open_frequencies_20mw()

        print("\nPredicting Intermodulation Distortion...")
        self.predict_imd()

        # Generate and print report
        print("\n" + self.generate_report())

        # Export to Excel
        self.export_to_excel()


def main():
    """Command-line interface"""
    parser = argparse.ArgumentParser(
        description="Wireless Microphone Frequency Coordinator"
    )
    parser.add_argument(
        "input_file",
        help="Excel file with occupied frequencies (must have 'Frequency (MHz)' column)",
    )
    parser.add_argument(
        "-o", "--output",
        help="Output Excel file (default: open_frequencies.xlsx in same directory)",
    )
    parser.add_argument(
        "-p", "--power",
        type=int,
        choices=[10, 20],
        default=20,
        help="Transmitter power in mW (default: 20)",
    )
    parser.add_argument(
        "-s", "--spacing",
        type=float,
        default=0.6,
        help="Minimum frequency spacing in MHz (default: 0.6)",
    )

    args = parser.parse_args()

    try:
        finder = WirelessMicFinder(
            input_file=args.input_file,
            output_file=args.output,
            power=args.power,
            min_spacing=args.spacing,
        )
        finder.run()
        return 0

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
