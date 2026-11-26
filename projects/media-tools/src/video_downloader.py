#!/usr/bin/env python3
"""
YouTube/Vimeo/Reddit Video Downloader
Download videos in MP4 format for embedding in presentations
"""

import os
import sys
import shutil
from tkinter import *
from tkinter import filedialog, messagebox
import yt_dlp

# Common ffmpeg install locations when launching from Finder (PATH is limited)
COMMON_FFMPEG_PATHS = [
    "/opt/homebrew/bin/ffmpeg",   # Apple Silicon Homebrew default
    "/usr/local/bin/ffmpeg",     # Intel Homebrew default
    "/opt/local/bin/ffmpeg",     # MacPorts
    "/usr/bin/ffmpeg",           # System provided
]

def find_ffmpeg():
    """
    Attempt to locate the ffmpeg binary.
    Finder-launched apps often do not inherit a PATH that includes Homebrew locations,
    so we check explicit install paths and optional environment overrides.
    """
    # Allow users to override via environment variables
    env_candidates = [
        os.environ.get("FFMPEG_BINARY"),
        os.environ.get("FFMPEG_PATH"),
    ]
    for candidate in env_candidates:
        if not candidate:
            continue
        candidate = candidate.strip('"')
        if os.path.isdir(candidate):
            candidate = os.path.join(candidate, "ffmpeg")
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate

    # Respect PATH if it is populated
    which_result = shutil.which("ffmpeg")
    if which_result:
        return which_result

    # Finally, probe common installation paths
    for path in COMMON_FFMPEG_PATHS:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None

def check_ffmpeg():
    """Check if ffmpeg is installed and accessible"""
    return find_ffmpeg() is not None

def get_ffmpeg_install_instructions():
    """Get platform-specific ffmpeg installation instructions"""
    if sys.platform == 'darwin':  # macOS
        return """ffmpeg is not installed. To install it:

1. Using Homebrew (recommended):
   • Open Terminal and run: brew install ffmpeg

2. Using MacPorts:
   • Open Terminal and run: sudo port install ffmpeg

After installation, restart this application."""
    elif sys.platform == 'win32':  # Windows
        return """ffmpeg is not installed. To install it:

1. Using Chocolatey:
   • Open Command Prompt as Administrator
   • Run: choco install ffmpeg

2. Using Scoop:
   • Open PowerShell
   • Run: scoop install ffmpeg

3. Manual installation:
   • Download from: https://ffmpeg.org/download.html
   • Add ffmpeg to your PATH

After installation, restart this application."""
    else:  # Linux
        return """ffmpeg is not installed. To install it:

Ubuntu/Debian:
   • sudo apt update && sudo apt install ffmpeg

Fedora:
   • sudo dnf install ffmpeg

Arch Linux:
   • sudo pacman -S ffmpeg

After installation, restart this application."""

def show_ffmpeg_warning():
    """Show a warning dialog about missing ffmpeg"""
    instructions = get_ffmpeg_install_instructions()
    messagebox.showwarning(
        "ffmpeg Not Found",
        f"{instructions}\n\nNote: Some downloads may still work with lower quality formats, but high-quality downloads require ffmpeg."
    )

def download_video():
    """Download video from URL"""
    url = url_entry.get().strip()
    save_path = save_path_var.get()
    quality = quality_var.get()

    if not url:
        messagebox.showerror("Error", "Please enter a video URL")
        return

    if not save_path:
        messagebox.showerror("Error", "Please select a save location")
        return

    # Check if ffmpeg is available (also capture resolved path)
    ffmpeg_path = find_ffmpeg()
    ffmpeg_available = ffmpeg_path is not None

    if not ffmpeg_available:
        # Show warning and ask if user wants to continue
        response = messagebox.askyesno(
            "ffmpeg Not Found",
            f"{get_ffmpeg_install_instructions()}\n\n"
            "Do you want to try downloading anyway?\n\n"
            "Note: The download may fail or only download lower quality videos without ffmpeg.",
            icon='warning'
        )
        if not response:
            return

    # Disable button during download
    download_button.config(state=DISABLED)
    status_label.config(text="Downloading... (check terminal for progress)")
    root.update()

    try:
        print(f"\n{'='*60}")
        print(f"Downloading: {url}")
        print(f"Quality: {quality}")
        print(f"Save to: {save_path}")
        print(f"ffmpeg available: {ffmpeg_available} (path: {ffmpeg_path or 'not found'})")
        print(f"{'='*60}\n")

        # Build format string based on quality selection
        # If ffmpeg is not available, use simpler formats that don't require merging
        if not ffmpeg_available:
            # Fallback to single-stream formats when ffmpeg is not available
            if quality == "Best (largest file)":
                format_string = "best[ext=mp4]/best"
            elif quality == "1080p":
                format_string = "best[height<=1080][ext=mp4]/best[height<=1080]"
            elif quality == "720p":
                format_string = "best[height<=720][ext=mp4]/best[height<=720]"
            else:  # 480p
                format_string = "best[height<=480][ext=mp4]/best[height<=480]"
        else:
            # Use high-quality formats with merging when ffmpeg is available
            if quality == "Best (largest file)":
                format_string = "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"
            elif quality == "1080p":
                format_string = "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080][ext=mp4]/best"
            elif quality == "720p":
                format_string = "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/best[height<=720][ext=mp4]/best"
            else:  # 480p
                format_string = "bestvideo[height<=480][ext=mp4]+bestaudio[ext=m4a]/best[height<=480][ext=mp4]/best"

        # Configure yt-dlp options
        ydl_opts = {
            'format': format_string,
            'outtmpl': os.path.join(save_path, '%(title)s.%(ext)s'),
            'merge_output_format': 'mp4',
            'quiet': False,
            'no_warnings': False,
            'noplaylist': not download_playlist_var.get(),  # Download playlist if checkbox is checked
        }

        if ffmpeg_path:
            # yt-dlp will directly invoke this binary, bypassing PATH lookups
            ydl_opts['ffmpeg_location'] = ffmpeg_path

        # Download using yt-dlp Python API
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([url])

        print(f"\n{'='*60}")
        print("✓ Download complete!")
        print(f"{'='*60}\n")

        status_label.config(text="Download complete! Check your save folder.")
        messagebox.showinfo("Success", "Video downloaded successfully!")

    except Exception as e:
        error_message = str(e)
        print(f"\n✗ Error downloading video: {e}")

        # Provide more helpful error messages based on error type
        if 'ffmpeg' in error_message.lower() or 'avconv' in error_message.lower():
            status_label.config(text="Download failed - ffmpeg required")
            messagebox.showerror(
                "ffmpeg Required",
                f"Download failed because ffmpeg is not installed or not working properly.\n\n"
                f"{get_ffmpeg_install_instructions()}\n\n"
                f"Original error:\n{error_message}"
            )
        elif 'url' in error_message.lower() or 'video' in error_message.lower() and 'not' in error_message.lower():
            status_label.config(text="Download failed - invalid URL or video unavailable")
            messagebox.showerror(
                "Invalid URL or Unavailable Video",
                f"The URL may be invalid, or the video may not be available.\n\n"
                f"Please check:\n"
                f"• The URL is correct and complete\n"
                f"• The video is not private or restricted\n"
                f"• You have internet connectivity\n\n"
                f"Error details:\n{error_message}"
            )
        elif 'network' in error_message.lower() or 'connection' in error_message.lower() or 'timeout' in error_message.lower():
            status_label.config(text="Download failed - network error")
            messagebox.showerror(
                "Network Error",
                f"Could not connect to the video source.\n\n"
                f"Please check your internet connection and try again.\n\n"
                f"Error details:\n{error_message}"
            )
        else:
            status_label.config(text="Download failed - check terminal for details")
            messagebox.showerror("Download Failed", f"An error occurred:\n\n{error_message}")

    finally:
        # Re-enable button
        download_button.config(state=NORMAL)


def browse_save_path():
    """Open folder browser dialog"""
    folder = filedialog.askdirectory()
    if folder:
        save_path_var.set(folder)


# Create main window
root = Tk()
root.title("ARC Video Grabber")
root.geometry("600x280")

# URL input
url_label = Label(root, text="Video URL:")
url_label.grid(row=0, column=0, sticky=E, padx=10, pady=10)
url_entry = Entry(root, width=50)
url_entry.grid(row=0, column=1, columnspan=2, padx=10, pady=10)

# Quality selection
quality_label = Label(root, text="Quality:")
quality_label.grid(row=1, column=0, sticky=E, padx=10, pady=10)
quality_var = StringVar(value="1080p")
quality_dropdown = OptionMenu(root, quality_var,
                               "Best (largest file)",
                               "1080p",
                               "720p",
                               "480p (smaller file)")
quality_dropdown.grid(row=1, column=1, sticky=W, padx=10, pady=10)

# Playlist option
download_playlist_var = BooleanVar(value=False)  # Default: single video only
playlist_checkbox = Checkbutton(root, text="Download entire playlist (if URL is a playlist)",
                                variable=download_playlist_var)
playlist_checkbox.grid(row=1, column=1, columnspan=2, sticky=E, padx=10, pady=10)

# Save path
save_path_label = Label(root, text="Save to:")
save_path_label.grid(row=2, column=0, sticky=E, padx=10, pady=10)
save_path_var = StringVar()
save_path_var.set(os.path.expanduser("~/Desktop"))  # Default to Desktop
save_path_entry = Entry(root, width=40, textvariable=save_path_var)
save_path_entry.grid(row=2, column=1, padx=10, pady=10)
browse_button = Button(root, text="Browse", command=browse_save_path)
browse_button.grid(row=2, column=2, padx=10, pady=10)

# Download button
download_button = Button(root, text="Download Video", command=download_video,
                         bg="#4CAF50", fg="white", padx=20, pady=10)
download_button.grid(row=3, column=1, pady=20)

# Status label
status_label = Label(root, text="Ready to download", fg="gray")
status_label.grid(row=4, column=0, columnspan=3, pady=10)

# Instructions
instructions = Label(root, text="Supports: YouTube, Vimeo, Reddit, and many other sites | Downloads as MP4 for PowerPoint",
                    fg="blue", font=("Arial", 9))
instructions.grid(row=5, column=0, columnspan=3, pady=5)

# Check for ffmpeg on startup and show warning if not found
if not check_ffmpeg():
    root.after(500, show_ffmpeg_warning)  # Show warning after window is displayed

root.mainloop()
