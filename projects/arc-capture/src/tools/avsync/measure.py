#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

import subprocess, sys, numpy as np
FF="/opt/homebrew/bin/ffmpeg"
f=sys.argv[1]; crop=sys.argv[2] if len(sys.argv)>2 else "crop=iw*0.6:ih*0.6:iw*0.2:ih*0.3"
v=subprocess.run([FF,"-v","error","-i",f,"-vf",f"{crop},scale=8:8,format=gray","-f","rawvideo","-"],capture_output=True).stdout
fr=np.frombuffer(v,np.uint8).reshape(-1,64).mean(axis=1)
# frame timestamps from the container (variable rate capture): use ffprobe pts
pts=[float(x) for x in subprocess.run(["/opt/homebrew/bin/ffprobe","-v","error","-select_streams","v:0","-show_entries","frame=pts_time","-of","csv=p=0",f],capture_output=True,text=True).stdout.replace(",","\n").split() if x.strip()]
pts=sorted(pts)[:len(fr)]
thr=(fr.max()+fr.min())/2
flash=[i for i in range(1,len(fr)) if fr[i]>thr and fr[i-1]<=thr]
a=np.frombuffer(subprocess.run([FF,"-v","error","-i",f,"-ac","1","-ar","48000","-f","f32le","-"],capture_output=True).stdout,np.float32)
astart=float(subprocess.run(["/opt/homebrew/bin/ffprobe","-v","error","-select_streams","a:0","-show_entries","stream=start_time","-of","csv=p=0",f],capture_output=True,text=True).stdout.strip() or 0)
env=np.abs(a); on=np.where(env>0.2)[0]
clicks=[on[0]]+[s for i,s in enumerate(on[1:],1) if on[i-1]<s-2400]
ft=[pts[i] for i in flash]; ct=[astart+s/48000 for s in clicks]
print(f"frames {len(fr)}  luma {fr.min():.0f}..{fr.max():.0f}  flashes {len(ft)}  clicks {len(ct)}  audio start {astart:+.4f}")
pairs=[]
for t in ft:
    c=min(ct,key=lambda x:abs(x-t)) if ct else None
    if c is not None and abs(c-t)<2.5: pairs.append((t,c,c-t))
for t,c,d in pairs: print(f"  flash {t:8.3f}  click {c:8.3f}   audio - video = {d*1000:+7.1f} ms")
if pairs:
    ds=[d for _,_,d in pairs]; print(f"MEAN {np.mean(ds)*1000:+.1f} ms   SPREAD {np.std(ds)*1000:.1f} ms   (positive = audio LATE)")
if len(pairs) > 3:
    # Residual drift: the slope of the offset over time. A lost buffer shows as a step; a clock-rate
    # mismatch between the playing app's audio device and the host shows as a steady slope.
    t=np.array([p[0] for p in pairs]); d=np.array([p[2]*1000 for p in pairs])
    k,b=np.polyfit(t,d,1)
    print(f"DRIFT {k*60:+.1f} ms/min (offset {b:+.0f} ms at t=0; over a 280 s movie {k*280:+.0f} ms)")
