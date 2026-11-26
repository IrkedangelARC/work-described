#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Canvas dimensions and broadcast safe zones."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class SafeZone:
    """Pixel offsets from canvas edge."""
    left: int
    top: int
    right: int
    bottom: int

    @property
    def width(self) -> int:
        return self.right - self.left

    @property
    def height(self) -> int:
        return self.bottom - self.top

    @property
    def box(self) -> tuple[int, int, int, int]:
        return (self.left, self.top, self.right, self.bottom)


@dataclass
class Canvas:
    width: int = 1920
    height: int = 1080

    @property
    def size(self) -> tuple[int, int]:
        return (self.width, self.height)

    @property
    def aspect_ratio(self) -> float:
        return self.width / self.height

    def safe_zone(self, margin: float = 0.10) -> SafeZone:
        """Return safe zone with given margin fraction."""
        mx = int(self.width * margin)
        my = int(self.height * margin)
        return SafeZone(
            left=mx, top=my,
            right=self.width - mx, bottom=self.height - my,
        )

    @property
    def action_safe(self) -> SafeZone:
        return self.safe_zone(0.035)

    @property
    def title_safe(self) -> SafeZone:
        return self.safe_zone(0.10)

    @classmethod
    def hd(cls) -> Canvas:
        return cls(1920, 1080)

    @classmethod
    def uhd(cls) -> Canvas:
        return cls(3840, 2160)

    @classmethod
    def square(cls, size: int = 1080) -> Canvas:
        return cls(size, size)
