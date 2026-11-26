#!/usr/bin/env python3
"""1920x1080 LED wall evaluation pattern: gray steps, near-black and near-white
steps, 75% bars, skin tones. sRGB-tagged so ColorSync treats it like video."""
from PIL import Image, ImageDraw, ImageFont, ImageCms
W, H = 1920, 1080
im = Image.new("RGB", (W, H), (0, 0, 0)); d = ImageDraw.Draw(im)
try: f = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
except OSError: f = ImageFont.load_default()
def row(y, h, vals, label_fmt):
    w = W / len(vals)
    for i, v in enumerate(vals):
        c = v if isinstance(v, tuple) else (v, v, v)
        d.rectangle([int(i*w), y, int((i+1)*w)-1, y+h], fill=c)
        lum = sum(c)/3
        d.text((int(i*w)+10, y+h-30), label_fmt(i, v), fill=(255,255,255) if lum < 128 else (0,0,0), font=f)
row(0, 270, [round(255*i/10) for i in range(11)], lambda i, v: f"{i*10}%")
row(270, 200, [round(255*p/100) for p in (0,1,2,3,4,5,6,8,10,12)], lambda i, v: f"{(0,1,2,3,4,5,6,8,10,12)[i]}%")
row(470, 200, [round(255*p/100) for p in (88,90,92,94,95,96,97,98,99,100)], lambda i, v: f"{(88,90,92,94,95,96,97,98,99,100)[i]}%")
bars = [(191,191,191),(191,191,0),(0,191,191),(0,191,0),(191,0,191),(191,0,0),(0,0,191)]
row(670, 220, bars, lambda i, v: ["75W","Y","C","G","M","R","B"][i])
skin = [(255,224,196),(234,192,160),(198,150,118),(161,110,80),(120,78,54),(84,54,38),(58,38,28)]
row(890, 190, skin, lambda i, v: f"skin {i+1}")
srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
im.save("ARC LED Test Pattern.png", icc_profile=srgb); print("ARC LED Test Pattern.png")
