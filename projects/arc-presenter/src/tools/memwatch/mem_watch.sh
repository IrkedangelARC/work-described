#!/bin/bash
# mem_watch.sh: 1 Hz memory sampler for ARC Presenter / ARC Capture on a machine with no Instruments.
# 2026-09-18: the first version recorded phys_footprint_PEAK (its awk took the last match of
# /phys_footprint/, which also matches phys_footprint_peak:) and its /state columns were empty.
# This version (from the step-0 executor's mem_watch2.sh) anchors /phys_footprint:/, records the
# peak in its own column, and fills the /state columns. Column map: 3 cols per process
# (rss, fp, fppeak), then sys_free_pct, swap, compressor, pageins, live_deck, slide, total, decks,
# lag_ms, max_lag_ms. With the 3 default processes lag_ms is column 20.
# A sampler that outlives its test records the NEXT test's process: size the seconds to the run.
# Usage: mem_watch2.sh <label> <seconds> [process ...]
set -u
label=${1:?label}; secs=${2:-60}; shift 2 2>/dev/null || shift $#
procs=("$@"); [ ${#procs[@]} -eq 0 ] && procs=("ARC Presenter" "ARC Capture" "Microsoft PowerPoint")
out="${MEMWATCH_OUT:-$(cd "$(dirname "$0")" && pwd)}/$label.csv"
hdr="t,elapsed_s"
for p in "${procs[@]}"; do n=$(echo "$p" | tr ' ' '_'); hdr="$hdr,${n}_rss_mb,${n}_fp_mb,${n}_fppeak_mb"; done
hdr="$hdr,sys_free_pct,swap_used_mb,compressor_pages,pageins,live_deck,slide,total,decks,lag_ms,max_lag_ms"
echo "$hdr" > "$out"
t0=$(date +%s)
while :; do
  now=$(date +%s); el=$((now - t0)); [ $el -gt "$secs" ] && break
  row="$(date +%H:%M:%S),$el"
  for p in "${procs[@]}"; do
    pid=$(pgrep -x "$p" 2>/dev/null | head -1)
    if [ -n "$pid" ]; then
      rss=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0f",$1/1024}')
      read fp pk < <(footprint -p "$pid" 2>/dev/null | awk '
        /phys_footprint:/      {gsub(/[^0-9.]/,"",$2); cur=$2; cu=$3}
        /phys_footprint_peak:/ {gsub(/[^0-9.]/,"",$2); pk=$2;  pu=$3}
        END {f=(cu~/GB/)?cur*1024:cur; q=(pu~/GB/)?pk*1024:pk; printf "%.0f %.0f", f, q}')
      row="$row,${rss:-},${fp:-},${pk:-}"
    else row="$row,,,"; fi
  done
  free=$(memory_pressure 2>/dev/null | awk '/free percentage/ {gsub(/%/,"",$NF); print $NF}')
  swap=$(sysctl -n vm.swapusage | awk '{gsub(/M/,"",$6); print $6}')
  comp=$(vm_stat | awk '/occupied by compressor/ {gsub(/\./,"",$NF); print $NF}')
  pin=$(vm_stat | awk '/^Pageins/ {gsub(/\./,"",$NF); print $NF}')
  st=$(curl -s -m 1 localhost:8760/state 2>/dev/null)
  if [ -n "$st" ]; then
    summ=$(printf '%s' "$st" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); h=d.get("health") or {}
    print("%s,%s,%s,%s,%s,%s" % (str(d.get("liveDeck") or "").replace(",",";")[:28],
        d.get("slide",""), d.get("totalSlides",""), d.get("deckCount",""),
        h.get("mainThreadLagMs",""), h.get("maxLagMs","")))
except Exception: print(",,,,,")' 2>/dev/null)
    [ -z "$summ" ] && summ=",,,,,"
  else summ=",,,,,"; fi
  echo "$row,${free:-},${swap:-},${comp:-},${pin:-},$summ" >> "$out"
  sleep 1
done
