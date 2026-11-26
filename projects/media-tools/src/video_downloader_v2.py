#!/usr/bin/env python3
"""
ARC Video Grabber v2
Enhanced YouTube/Vimeo/Reddit video downloader with threading and progress tracking
"""

import os
import sys
import shutil
import threading
from tkinter import *
from tkinter import filedialog, messagebox
from tkinter.ttk import Progressbar
import yt_dlp

# Common ffmpeg install locations
COMMON_FFMPEG_PATHS = [
    "/opt/homebrew/bin/ffmpeg",
    "/usr/local/bin/ffmpeg",
    "/opt/local/bin/ffmpeg",
    "/usr/bin/ffmpeg",
]

def find_ffmpeg():
    """Locate ffmpeg binary"""
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

    which_result = shutil.which("ffmpeg")
    if which_result:
        return which_result

    for path in COMMON_FFMPEG_PATHS:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None

def check_ffmpeg():
    """Check if ffmpeg is installed"""
    return find_ffmpeg() is not None

def get_ffmpeg_install_instructions():
    """Platform-specific ffmpeg installation instructions"""
    if sys.platform == 'darwin':
        return """ffmpeg not installed. Install via Homebrew:
• brew install ffmpeg"""
    elif sys.platform == 'win32':
        return """ffmpeg not installed. Install via Chocolatey:
• choco install ffmpeg"""
    else:
        return """ffmpeg not installed. Install via package manager:
• sudo apt install ffmpeg (Ubuntu/Debian)
• sudo dnf install ffmpeg (Fedora)"""

class VideoDownloaderApp:
    def __init__(self, root):
        self.root = root
        self.root.title("ARC Video Grabber v2")
        self.root.geometry("700x400")
        self.downloading = False
        self.download_thread = None

        # Prevent window close during download
        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)

        self.setup_ui()
        self.check_ffmpeg_on_startup()

    def setup_ui(self):
        """Setup the user interface"""
        # Header
        header_frame = Frame(self.root, bg="#2c3e50", height=60)
        header_frame.pack(fill=X)
        header_frame.pack_propagate(False)

        title_label = Label(header_frame, text="ARC Video Grabber",
                           font=("Arial", 18, "bold"), fg="white", bg="#2c3e50")
        title_label.pack(pady=15)

        # Main content area
        main_frame = Frame(self.root, padx=20, pady=20)
        main_frame.pack(fill=BOTH, expand=True)

        # URL input
        url_frame = Frame(main_frame)
        url_frame.pack(fill=X, pady=(0, 15))

        Label(url_frame, text="Video URL:", font=("Arial", 10)).pack(anchor=W)
        self.url_entry = Entry(url_frame, font=("Arial", 10))
        self.url_entry.pack(fill=X, pady=(5, 0))

        # Options frame
        options_frame = Frame(main_frame)
        options_frame.pack(fill=X, pady=(0, 15))

        # Quality selection
        quality_frame = Frame(options_frame)
        quality_frame.pack(side=LEFT, padx=(0, 20))

        Label(quality_frame, text="Quality:", font=("Arial", 10)).pack(anchor=W)
        self.quality_var = StringVar(value="1080p")
        quality_menu = OptionMenu(quality_frame, self.quality_var,
                                  "Best (largest)", "1080p", "720p", "480p (smaller)")
        quality_menu.config(width=15)
        quality_menu.pack(pady=(5, 0))

        # Playlist checkbox
        self.download_playlist_var = BooleanVar(value=False)
        playlist_check = Checkbutton(options_frame,
                                     text="Download entire playlist",
                                     variable=self.download_playlist_var,
                                     font=("Arial", 10))
        playlist_check.pack(side=LEFT, pady=(20, 0))

        # Save location
        save_frame = Frame(main_frame)
        save_frame.pack(fill=X, pady=(0, 15))

        Label(save_frame, text="Save to:", font=("Arial", 10)).pack(anchor=W)

        path_frame = Frame(save_frame)
        path_frame.pack(fill=X, pady=(5, 0))

        self.save_path_var = StringVar(value=os.path.expanduser("~/Desktop"))
        self.save_path_entry = Entry(path_frame, textvariable=self.save_path_var,
                                     font=("Arial", 10), state='readonly')
        self.save_path_entry.pack(side=LEFT, fill=X, expand=True)

        browse_btn = Button(path_frame, text="Browse", command=self.browse_folder,
                           font=("Arial", 9))
        browse_btn.pack(side=LEFT, padx=(10, 0))

        # Progress bar
        self.progress = Progressbar(main_frame, mode='indeterminate')
        self.progress.pack(fill=X, pady=(0, 10))

        # Status label
        self.status_label = Label(main_frame, text="Ready to download",
                                 font=("Arial", 9), fg="#7f8c8d")
        self.status_label.pack(pady=(0, 15))

        # Download button
        self.download_button = Button(main_frame, text="Download Video",
                                     command=self.start_download,
                                     bg="#27ae60", fg="white",
                                     font=("Arial", 12, "bold"),
                                     padx=30, pady=10,
                                     cursor="hand2")
        self.download_button.pack(pady=(0, 10))

        # Footer info
        info_label = Label(main_frame,
                          text="Supports: YouTube, Vimeo, Reddit, and 1000+ other sites",
                          font=("Arial", 8), fg="#3498db")
        info_label.pack()

    def browse_folder(self):
        """Open folder browser"""
        folder = filedialog.askdirectory()
        if folder:
            self.save_path_var.set(folder)

    def check_ffmpeg_on_startup(self):
        """Check for ffmpeg on startup"""
        if not check_ffmpeg():
            self.root.after(500, self.show_ffmpeg_warning)

    def show_ffmpeg_warning(self):
        """Show ffmpeg warning dialog"""
        messagebox.showwarning(
            "ffmpeg Not Found",
            f"{get_ffmpeg_install_instructions()}\n\n"
            "High-quality downloads require ffmpeg.\n"
            "Some downloads may still work with lower quality."
        )

    def update_status(self, message, color="#7f8c8d"):
        """Thread-safe status update"""
        try:
            if self.status_label.winfo_exists():
                self.status_label.config(text=message, fg=color)
                self.root.update_idletasks()
        except:
            pass

    def update_button_state(self, enabled):
        """Thread-safe button state update"""
        try:
            if self.download_button.winfo_exists():
                self.download_button.config(state=NORMAL if enabled else DISABLED)
        except:
            pass

    def start_download(self):
        """Start download in background thread"""
        url = self.url_entry.get().strip()
        save_path = self.save_path_var.get()

        if not url:
            messagebox.showerror("Error", "Please enter a video URL")
            return

        if not save_path:
            messagebox.showerror("Error", "Please select a save location")
            return

        # Check ffmpeg
        ffmpeg_path = find_ffmpeg()
        if not ffmpeg_path:
            response = messagebox.askyesno(
                "ffmpeg Not Found",
                f"{get_ffmpeg_install_instructions()}\n\n"
                "Continue anyway? (May only download lower quality)",
                icon='warning'
            )
            if not response:
                return

        # Start download thread
        self.downloading = True
        self.update_button_state(False)
        self.progress.start(10)
        self.update_status("Downloading...", "#3498db")

        self.download_thread = threading.Thread(
            target=self.download_worker,
            args=(url, save_path, self.quality_var.get(),
                  self.download_playlist_var.get(), ffmpeg_path),
            daemon=True
        )
        self.download_thread.start()

    def download_worker(self, url, save_path, quality, download_playlist, ffmpeg_path):
        """Background download worker"""
        try:
            print(f"\n{'='*60}")
            print(f"Downloading: {url}")
            print(f"Quality: {quality}")
            print(f"Save to: {save_path}")
            print(f"ffmpeg: {ffmpeg_path or 'not found'}")
            print(f"{'='*60}\n")

            # Build format string
            if not ffmpeg_path:
                format_map = {
                    "Best (largest)": "best[ext=mp4]/best",
                    "1080p": "best[height<=1080][ext=mp4]/best[height<=1080]",
                    "720p": "best[height<=720][ext=mp4]/best[height<=720]",
                    "480p (smaller)": "best[height<=480][ext=mp4]/best[height<=480]"
                }
            else:
                format_map = {
                    "Best (largest)": "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
                    "1080p": "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080][ext=mp4]/best",
                    "720p": "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/best[height<=720][ext=mp4]/best",
                    "480p (smaller)": "bestvideo[height<=480][ext=mp4]+bestaudio[ext=m4a]/best[height<=480][ext=mp4]/best"
                }

            format_string = format_map.get(quality, format_map["1080p"])

            # Configure yt-dlp
            ydl_opts = {
                'format': format_string,
                'outtmpl': os.path.join(save_path, '%(title)s.%(ext)s'),
                'merge_output_format': 'mp4',
                'quiet': False,
                'no_warnings': False,
                'noplaylist': not download_playlist,
                'socket_timeout': 30,  # 30 second timeout for network operations
                'retries': 3,  # Retry failed downloads 3 times
                'fragment_retries': 3,  # Retry failed fragments 3 times
                'extractor_retries': 3,  # Retry failed extractor operations 3 times
                'file_access_retries': 3,  # Retry failed file access 3 times
            }

            if ffmpeg_path:
                ydl_opts['ffmpeg_location'] = ffmpeg_path

            # Download with validation
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                # First, extract info to validate it's a video
                info = ydl.extract_info(url, download=False)

                # Check if it's actually a video
                if info.get('_type') == 'playlist' and not download_playlist:
                    raise Exception("This is a playlist. Enable 'Download entire playlist' to download all videos.")

                # Check for entries (galleries, playlists, etc.)
                if 'entries' in info and not download_playlist:
                    # Check if any entries are videos
                    has_video = any(e.get('ext') in ['mp4', 'webm', 'mkv', 'flv', 'avi', 'mov'] for e in info['entries'] if e)
                    if not has_video:
                        raise Exception("This URL contains images or non-video content. Videos only.")

                # Check if single entry is a video
                if 'entries' not in info:
                    if info.get('ext') not in ['mp4', 'webm', 'mkv', 'flv', 'avi', 'mov', None]:
                        raise Exception(f"This appears to be a {info.get('ext', 'non-video')} file, not a video.")

                # Proceed with download
                ydl.download([url])

            print(f"\n{'='*60}")
            print("✓ Download complete!")
            print(f"{'='*60}\n")

            # Update UI on main thread
            self.root.after(0, self.download_complete_success)

        except Exception as e:
            print(f"\n✗ Error: {e}\n")
            error_msg = str(e)

            # Update UI on main thread
            self.root.after(0, lambda: self.download_complete_error(error_msg))

    def download_complete_success(self):
        """Handle successful download completion"""
        self.progress.stop()
        self.update_status("Download complete!", "#27ae60")
        self.update_button_state(True)
        self.downloading = False
        messagebox.showinfo("Success", "Video downloaded successfully!")

    def download_complete_error(self, error_msg):
        """Handle download error"""
        self.progress.stop()
        self.update_status("Download failed", "#e74c3c")
        self.update_button_state(True)
        self.downloading = False

        # Provide helpful error messages
        if 'ffmpeg' in error_msg.lower():
            messagebox.showerror(
                "ffmpeg Required",
                f"Download failed - ffmpeg is required.\n\n"
                f"{get_ffmpeg_install_instructions()}\n\n"
                f"Error: {error_msg}"
            )
        elif 'url' in error_msg.lower() or 'unavailable' in error_msg.lower():
            messagebox.showerror(
                "Invalid URL",
                f"URL may be invalid or video unavailable.\n\n"
                f"Error: {error_msg}"
            )
        else:
            messagebox.showerror("Download Failed", f"Error: {error_msg}")

    def on_closing(self):
        """Handle window close event"""
        if self.downloading:
            response = messagebox.askyesno(
                "Download in Progress",
                "A download is in progress. Close anyway?\n"
                "(Download will continue in background)"
            )
            if not response:
                return

        self.root.destroy()

# Run application
if __name__ == "__main__":
    root = Tk()
    app = VideoDownloaderApp(root)
    root.mainloop()
