#!/bin/zsh
#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

# Rebuild the A/V reference movie and the PowerPoint deck that autoplays it.
# Needs ffmpeg, python3 with Pillow + python-pptx.
set -e
cd "$(dirname "$0")"
OUT="${1:-reference}"; mkdir -p "$OUT/frames"
FF=$(ls /opt/homebrew/bin/ffmpeg "/Applications/ARC Grab.app/Contents/MacOS/ffmpeg" 2>/dev/null | head -1)
python3 - "$OUT" <<'PY'
from PIL import Image, ImageDraw, ImageFont
import sys, os
OUT=sys.argv[1]; W,H,FPS,SECS=1920,1080,30,40
big=ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc",380); mid=ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc",64); small=ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc",40)
for i in range(FPS*SECS):
    t=i/FPS
    if (t%5)<0.1:
        im=Image.new("RGB",(W,H),(235,235,235)); d=ImageDraw.Draw(im); d.text((W/2,H/2),"FLASH",font=mid,fill=(0,0,0),anchor="mm")
    else:
        im=Image.new("RGB",(W,H),(16,16,16)); d=ImageDraw.Draw(im)
        d.text((W/2,H/2-60),f"{t:05.2f}",font=big,fill=(230,230,230),anchor="mm")
        d.text((W/2,120),"ARC A/V REFERENCE  ·  white flash + click every 5 s  ·  30 fps",font=small,fill=(140,140,140),anchor="mm")
        d.text((W/2,H-200),f"frame {i}   next flash in {5-(t%5):.1f} s",font=mid,fill=(160,160,160),anchor="mm")
        x=int((t%5)/5*(W-200))+100
        d.rectangle((100,H-120,W-100,H-90),outline=(90,90,90),width=3); d.rectangle((x-10,H-125,x+10,H-85),fill=(200,16,46))
    im.save(f"{OUT}/frames/f{i:05d}.png","PNG",compress_level=1)
PY
"$FF" -v error -y -framerate 30 -i "$OUT/frames/f%05d.png" -f lavfi -i "aevalsrc='if(lt(mod(t\,5)\,0.1)\,0.9*sin(2*PI*1000*t)\,0)':s=48000:c=stereo:d=40" -map 0:v -map 1:a -c:v libx264 -pix_fmt yuv420p -profile:v high -g 30 -crf 18 -c:a aac -b:a 192k -ar 48000 -shortest -movflags +faststart "$OUT/ARC AV Reference.mp4"
rm -rf "$OUT/frames"
python3 make-reference-pptx.py "$OUT"
echo "built $OUT/ARC AV Reference.mp4 and .pptx"
