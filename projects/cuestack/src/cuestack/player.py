#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Fullscreen presentation player with operator controls."""

import sys
from pathlib import Path
from typing import Optional

try:
    import pygame
except ImportError:
    print("pygame not installed. Run: pip install pygame")
    sys.exit(1)

from PIL import Image

from .models import Show


class Player:
    """
    CueStack Player — plays rendered slides fullscreen.

    Controls:
        Right/Space/PageDown  — Next slide
        Left/PageUp           — Previous slide
        Up                    — Next cue (jump to next presentation)
        Down                  — Previous cue
        Home                  — First slide of current cue
        End                   — Last slide of current cue
        G                     — Go to cue by number (type number + Enter)
        B                     — Black screen toggle
        W                     — White screen toggle
        F                     — Toggle fullscreen
        Escape/Q              — Quit
    """

    def __init__(self, show: Show, display: int = 0):
        self.show = show
        self.display_index = display

        # State
        self.current_cue_idx: int = 0
        self.current_slide_idx: int = 0
        self.blanked: Optional[str] = None  # None, "black", or "white"
        self.running: bool = False

        # Image cache (cue_id -> list of pygame surfaces)
        self._cache: dict[str, list[pygame.Surface]] = {}
        self._cache_limit = 5  # max cues to cache

        # Display
        self._screen: Optional[pygame.Surface] = None
        self._clock: Optional[pygame.time.Clock] = None
        self._fullscreen: bool = True
        self._screen_size: tuple[int, int] = show.resolution

    @property
    def current_cue(self):
        if 0 <= self.current_cue_idx < len(self.show.cues):
            return self.show.cues[self.current_cue_idx]
        return None

    @property
    def total_cues(self) -> int:
        return len(self.show.cues)

    def run(self):
        """Main player loop."""
        pygame.init()
        pygame.display.set_caption(f"CueStack — {self.show.name}")

        self._setup_display()
        self._clock = pygame.time.Clock()
        self.running = True

        # Load first cue
        self._ensure_cached(self.current_cue_idx)
        self._render_current()

        print("\nCueStack Player running. Controls:")
        print("  Right/Space/PgDn = next slide")
        print("  Left/PgUp        = prev slide")
        print("  Up/Down           = next/prev cue")
        print("  B = black | W = white | F = fullscreen")
        print("  Q/Esc = quit\n")

        while self.running:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    self.running = False
                elif event.type == pygame.KEYDOWN:
                    self._handle_key(event.key)

            self._clock.tick(30)

        pygame.quit()

    def _setup_display(self):
        """Initialize the display."""
        flags = pygame.FULLSCREEN | pygame.HWSURFACE | pygame.DOUBLEBUF
        if not self._fullscreen:
            flags = pygame.RESIZABLE

        info = pygame.display.Info()
        if self._fullscreen:
            self._screen_size = (info.current_w, info.current_h)
        self._screen = pygame.display.set_mode(self._screen_size, flags)

    def _handle_key(self, key):
        """Handle keyboard input."""
        if key in (pygame.K_RIGHT, pygame.K_SPACE, pygame.K_PAGEDOWN):
            self._next_slide()
        elif key in (pygame.K_LEFT, pygame.K_PAGEUP):
            self._prev_slide()
        elif key == pygame.K_UP:
            self._next_cue()
        elif key == pygame.K_DOWN:
            self._prev_cue()
        elif key == pygame.K_HOME:
            self.current_slide_idx = 0
            self._render_current()
        elif key == pygame.K_END:
            cue = self.current_cue
            if cue:
                self.current_slide_idx = max(0, cue.slide_count - 1)
                self._render_current()
        elif key == pygame.K_b:
            self.blanked = None if self.blanked == "black" else "black"
            self._render_current()
        elif key == pygame.K_w:
            self.blanked = None if self.blanked == "white" else "white"
            self._render_current()
        elif key == pygame.K_f:
            self._fullscreen = not self._fullscreen
            self._setup_display()
            self._render_current()
        elif key in (pygame.K_ESCAPE, pygame.K_q):
            self.running = False

    def _next_slide(self):
        """Advance to next slide, crossing cue boundaries."""
        cue = self.current_cue
        if not cue:
            return

        if self.current_slide_idx < cue.slide_count - 1:
            self.current_slide_idx += 1
        elif self.current_cue_idx < self.total_cues - 1:
            # Auto-advance to next cue
            self.current_cue_idx += 1
            self.current_slide_idx = 0
            self._ensure_cached(self.current_cue_idx)
            self._print_cue_change()
        self._render_current()

    def _prev_slide(self):
        """Go to previous slide, crossing cue boundaries."""
        if self.current_slide_idx > 0:
            self.current_slide_idx -= 1
        elif self.current_cue_idx > 0:
            self.current_cue_idx -= 1
            cue = self.current_cue
            self.current_slide_idx = max(0, cue.slide_count - 1) if cue else 0
            self._ensure_cached(self.current_cue_idx)
            self._print_cue_change()
        self._render_current()

    def _next_cue(self):
        """Jump to first slide of next cue."""
        if self.current_cue_idx < self.total_cues - 1:
            self.current_cue_idx += 1
            self.current_slide_idx = 0
            self._ensure_cached(self.current_cue_idx)
            self._print_cue_change()
            self._render_current()

    def _prev_cue(self):
        """Jump to first slide of previous cue."""
        if self.current_cue_idx > 0:
            self.current_cue_idx -= 1
            self.current_slide_idx = 0
            self._ensure_cached(self.current_cue_idx)
            self._print_cue_change()
            self._render_current()

    def _print_cue_change(self):
        """Log cue change to console (operator feedback)."""
        cue = self.current_cue
        if cue:
            print(
                f"  CUE {self.current_cue_idx + 1}/{self.total_cues}: "
                f"{cue.name} [{cue.session}] ({cue.slide_count} slides)"
            )

    def _ensure_cached(self, cue_idx: int):
        """Load slide images for a cue into the cache."""
        if cue_idx < 0 or cue_idx >= self.total_cues:
            return

        cue = self.show.cues[cue_idx]
        if cue.id in self._cache:
            return

        # Evict oldest if cache full
        while len(self._cache) >= self._cache_limit:
            oldest_key = next(iter(self._cache))
            del self._cache[oldest_key]

        # Load images
        surfaces = []
        for slide in cue.slides:
            img_path = Path(slide.image_path)
            if img_path.exists():
                surf = pygame.image.load(str(img_path))
                surfaces.append(surf)
        self._cache[cue.id] = surfaces

        # Pre-cache next cue
        if cue_idx + 1 < self.total_cues:
            next_cue = self.show.cues[cue_idx + 1]
            if next_cue.id not in self._cache:
                next_surfaces = []
                for slide in next_cue.slides:
                    img_path = Path(slide.image_path)
                    if img_path.exists():
                        surf = pygame.image.load(str(img_path))
                        next_surfaces.append(surf)
                self._cache[next_cue.id] = next_surfaces

    def _render_current(self):
        """Render the current state to screen."""
        if not self._screen:
            return

        # Handle blanking
        if self.blanked == "black":
            self._screen.fill((0, 0, 0))
            pygame.display.flip()
            return
        elif self.blanked == "white":
            self._screen.fill((255, 255, 255))
            pygame.display.flip()
            return

        # Black background
        self._screen.fill((0, 0, 0))

        cue = self.current_cue
        if not cue or cue.id not in self._cache:
            pygame.display.flip()
            return

        surfaces = self._cache[cue.id]
        if not surfaces or self.current_slide_idx >= len(surfaces):
            pygame.display.flip()
            return

        # Scale slide to fit screen while maintaining aspect ratio
        slide_surf = surfaces[self.current_slide_idx]
        slide_rect = slide_surf.get_rect()
        screen_w, screen_h = self._screen_size

        scale = min(screen_w / slide_rect.width, screen_h / slide_rect.height)
        new_w = int(slide_rect.width * scale)
        new_h = int(slide_rect.height * scale)

        scaled = pygame.transform.smoothscale(slide_surf, (new_w, new_h))
        x = (screen_w - new_w) // 2
        y = (screen_h - new_h) // 2

        self._screen.blit(scaled, (x, y))
        pygame.display.flip()
