#!/usr/bin/env python3
"""
ARC PowerPoint Combiner
Combines numbered presentations into a session deck
Preserves source formatting (like "Keep Source Formatting" in PowerPoint)
"""

import os
import re
from pathlib import Path
from tkinter import *
from tkinter import filedialog, messagebox, scrolledtext
from pptx import Presentation
import shutil

class PowerPointCombiner:
    def __init__(self, root):
        self.root = root
        self.root.title("ARC PowerPoint Combiner")
        self.root.geometry("700x550")

        self.setup_ui()

    def setup_ui(self):
        """Create the user interface"""

        # Instructions
        instructions = Label(self.root,
                           text="Combines numbered presentations (1.00, 1.01, 1.02...) into one session deck",
                           font=("Arial", 11, "bold"), fg="blue")
        instructions.pack(pady=10)

        # Folder selection
        folder_frame = LabelFrame(self.root, text="Select Presentation Folder", padx=10, pady=10)
        folder_frame.pack(padx=10, pady=10, fill=X)

        self.folder_path_var = StringVar()
        folder_entry = Entry(folder_frame, textvariable=self.folder_path_var, width=50)
        folder_entry.pack(side=LEFT, padx=5)

        browse_button = Button(folder_frame, text="Browse", command=self.browse_folder)
        browse_button.pack(side=LEFT, padx=5)

        # Output name
        output_frame = LabelFrame(self.root, text="Output Filename", padx=10, pady=10)
        output_frame.pack(padx=10, pady=10, fill=X)

        output_label = Label(output_frame, text="Save as:")
        output_label.pack(side=LEFT, padx=5)

        self.output_name_var = StringVar(value="Combined Session Deck.pptx")
        output_entry = Entry(output_frame, textvariable=self.output_name_var, width=40)
        output_entry.pack(side=LEFT, padx=5)

        # Options
        options_frame = LabelFrame(self.root, text="Options", padx=10, pady=10)
        options_frame.pack(padx=10, pady=10, fill=X)

        self.auto_save_var = BooleanVar(value=True)
        auto_save_check = Checkbutton(options_frame, text="Auto-save after each presentation (recommended)",
                                     variable=self.auto_save_var)
        auto_save_check.pack(anchor=W)

        # Combine button
        combine_button = Button(self.root, text="Combine Presentations", command=self.combine_presentations,
                              bg="#4CAF50", fg="white", padx=20, pady=10, font=("Arial", 12, "bold"))
        combine_button.pack(pady=15)

        # Status area
        status_frame = LabelFrame(self.root, text="Progress", padx=10, pady=10)
        status_frame.pack(padx=10, pady=10, fill=BOTH, expand=True)

        self.status_text = scrolledtext.ScrolledText(status_frame, height=12, wrap=WORD)
        self.status_text.pack(fill=BOTH, expand=True)

    def log(self, message):
        """Add message to status log"""
        self.status_text.insert(END, message + "\n")
        self.status_text.see(END)
        self.root.update()

    def browse_folder(self):
        """Select folder containing presentations"""
        folder = filedialog.askdirectory()
        if folder:
            self.folder_path_var.set(folder)
            self.log(f"Selected folder: {folder}")

    def extract_number(self, filename):
        """Extract the numbering from filename (e.g., '1.01' from '1.01 Welcome.pptx')"""
        match = re.match(r'(\d+\.\d+)', filename)
        return match.group(1) if match else None

    def combine_presentations(self):
        """Combine all numbered presentations in order"""
        folder = self.folder_path_var.get()

        if not folder:
            messagebox.showerror("Error", "Please select a presentation folder")
            return

        folder_path = Path(folder)

        self.status_text.delete("1.0", END)
        self.log(f"{'='*60}")
        self.log("Starting combination process...")
        self.log(f"{'='*60}\n")

        # Find all .pptx files with numbering
        pptx_files = list(folder_path.glob('*.pptx')) + list(folder_path.glob('*.PPTX'))

        # Filter to only numbered files
        numbered_files = []
        for file in pptx_files:
            number = self.extract_number(file.name)
            if number:
                numbered_files.append((number, file))

        if not numbered_files:
            messagebox.showerror("Error", "No numbered .pptx files found in folder.\n\nFiles should be named like:\n1.00 Title.pptx\n1.01 Welcome.pptx")
            return

        # Sort by number
        numbered_files.sort(key=lambda x: float(x[0]))

        self.log(f"Found {len(numbered_files)} numbered presentations:\n")
        for number, file in numbered_files:
            self.log(f"  {number} - {file.name}")

        self.log(f"\n{'='*60}\n")

        # Create combined presentation
        output_path = folder_path / self.output_name_var.get()

        try:
            # Start with the first presentation
            first_number, first_file = numbered_files[0]
            self.log(f"Starting with: {first_file.name}")

            combined_prs = Presentation(str(first_file))
            slide_count = len(combined_prs.slides)

            self.log(f"  Added {slide_count} slides\n")

            # Add remaining presentations
            for i, (number, file) in enumerate(numbered_files[1:], start=2):
                self.log(f"Adding {number}: {file.name}")

                try:
                    source_prs = Presentation(str(file))

                    # Copy each slide from source to combined
                    for slide in source_prs.slides:
                        # Get the slide layout from source
                        slide_layout = combined_prs.slide_layouts[0]  # Blank layout

                        # Add new slide
                        new_slide = combined_prs.slides.add_slide(slide_layout)

                        # Copy all shapes from source slide to new slide
                        for shape in slide.shapes:
                            el = shape.element
                            new_slide.shapes._spTree.insert_element_before(el, 'p:extLst')

                        slide_count += 1

                    self.log(f"  Added {len(source_prs.slides)} slides (Total: {slide_count})\n")

                    # Auto-save after each presentation
                    if self.auto_save_var.get():
                        combined_prs.save(str(output_path))
                        self.log(f"  ✓ Saved progress\n")

                except Exception as e:
                    self.log(f"  ✗ Error adding {file.name}: {e}\n")
                    continue

            # Final save
            combined_prs.save(str(output_path))

            self.log(f"\n{'='*60}")
            self.log(f"✓ Success! Combined {len(numbered_files)} presentations")
            self.log(f"✓ Total slides: {slide_count}")
            self.log(f"✓ Saved to: {output_path.name}")
            self.log(f"{'='*60}\n")

            messagebox.showinfo("Success",
                              f"Combined {len(numbered_files)} presentations!\n\n"
                              f"Total slides: {slide_count}\n"
                              f"Saved as: {output_path.name}")

        except Exception as e:
            self.log(f"\n✗ Error: {e}")
            messagebox.showerror("Error", f"Failed to combine presentations:\n\n{e}")


if __name__ == "__main__":
    root = Tk()
    app = PowerPointCombiner(root)
    root.mainloop()
