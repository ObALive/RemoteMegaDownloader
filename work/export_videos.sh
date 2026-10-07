#!/bin/bash
# Export every video in videos.tsv as its own individual public file link.
# Input : videos.tsv  ->  <remote path>TAB<handle>
# Output: links.tsv   ->  <handle>TAB<size>TAB<link>TAB<path>
set -uo pipefail

WORK="$(cd "$(dirname "$0")" && pwd)"
IN="$WORK/videos.tsv"
OUT="$WORK/links.tsv"
RAW="$WORK/export_raw.log"
export PATH="$HOME/.local/bin:$PATH"

: > "$OUT"
: > "$RAW"

extract_link() { grep -oE 'https://mega\.nz/(file|folder)/[A-Za-z0-9_-]+#[A-Za-z0-9_-]+' | head -1; }

n=0
total=$(wc -l < "$IN")

while IFS=$'\t' read -r path handle; do
    [ -z "${path:-}" ] && continue
    n=$((n + 1))
    printf '[%2d/%d] %s\n' "$n" "$total" "$path"

    # Try to create the export; if it already exists, just read the existing link back.
    resp="$(timeout 180 mega-export -a "$path" 2>&1)"
    echo "--- $path [add] ---" >> "$RAW"; echo "$resp" >> "$RAW"

    link="$(printf '%s\n' "$resp" | extract_link)"

    if [ -z "$link" ]; then
        resp2="$(timeout 180 mega-export "$path" 2>&1)"
        echo "--- $path [query] ---" >> "$RAW"; echo "$resp2" >> "$RAW"
        link="$(printf '%s\n' "$resp2" | extract_link)"
    fi

    if [ -z "$link" ]; then
        printf '  !! FAILED: %s\n' "$(printf '%s' "$resp" | tr '\n' ' ' | cut -c1-160)"
        printf '%s\t%s\t%s\t%s\n' "$handle" "?" "EXPORT_FAILED" "$path" >> "$OUT"
    else
        size="$(timeout 60 mega-ls -l "$path" 2>/dev/null | awk 'NR==2{print $3}')"
        printf '  -> %s  (%s bytes)\n' "$link" "${size:-?}"
        printf '%s\t%s\t%s\t%s\n' "$handle" "${size:-?}" "$link" "$path" >> "$OUT"
    fi

    sleep 2   # be gentle with the API rate limiter
done < "$IN"

echo
echo "完成: $(wc -l < "$OUT") / $total"
