 #!/usr/bin/env bash
# =============================================================================
#  ipodvideo-convert.sh  —  YouTube → iPod Video (5th/5.5th gen) converter
#
#  Deps: yt-dlp, ffmpeg, ffprobe, bc
#
#  iPod Video hardware limits:
#    Screen      : 320×240 (4:3), but TV-out supports up to 640×480 / 640×360
#    Video codec : H.264 Baseline L3.0, max 2500 kbps OR MPEG-4 SP
#    Frame rate  : max 30fps
#    Audio codec : AAC stereo, max 160 kbps @ 48 kHz
#    Container   : .m4v / .mp4
#
#  Resolution logic (measured AFTER black-bar crop):
#    16:9  (AR 1.70–1.85)  →  640×360  @ 30fps   (widescreen TV-out quality)
#    4:3   (AR 1.20–1.45)  →  640×480  @ 30fps   (fills the screen perfectly)
#    Other (2.35:1 etc.)   →  fit inside 640×480, preserve AR
#
#  Audio: AAC stereo @ 160 kbps, 48 kHz — absolute ceiling of the hardware
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; RST='\033[0m'; BLD='\033[1m'

info()  { echo -e "${BLU}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[OK]${RST}    $*"; }
warn()  { echo -e "${YLW}[WARN]${RST}  $*"; }
die()   { echo -e "${RED}[ERR]${RST}   $*" >&2; exit 1; }
step()  { echo -e "\n${BLD}${CYN}▶  $*${RST}"; }

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in yt-dlp ffmpeg ffprobe bc; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required tools: ${missing[*]}

  Install hints:
    macOS (Homebrew):  brew install yt-dlp ffmpeg bc
    Debian/Ubuntu:     sudo apt install ffmpeg bc && pip install yt-dlp
    Arch:              sudo pacman -S yt-dlp ffmpeg bc
    Fedora:            sudo dnf install ffmpeg bc && pip install yt-dlp"
    fi
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BLD}Usage:${RST}
  $(basename "$0") <YouTube-URL> [output-basename]

${BLD}Examples:${RST}
  $(basename "$0") https://youtu.be/dQw4w9WgXcQ
  $(basename "$0") https://youtu.be/dQw4w9WgXcQ "my-video"

${BLD}Output:${RST}
  <output-basename>.m4v — drag into iTunes, sync to iPod Video

${BLD}Resolution logic (measured after black-bar crop):${RST}
  16:9  (AR 1.70–1.85)  →  640×360 @ 30fps   widescreen TV-out
  4:3   (AR 1.20–1.45)  →  640×480 @ 30fps   fills iPod screen
  Other (2.35:1 etc.)   →  fit inside 640×480, AR preserved

${BLD}Audio:${RST}
  AAC stereo @ 160 kbps, 48 kHz — hardware ceiling of iPod Video

${BLD}Options:${RST}
  -h, --help    Show this help
  --no-crop     Skip automatic black-bar crop detection
  --crf N       Override video CRF (default: 22)
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
URL=""
OUTPUT_BASE=""
DO_CROP=true
CRF_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)    usage ;;
        --no-crop)    DO_CROP=false; shift ;;
        --crf)        CRF_OVERRIDE="$2"; shift 2 ;;
        http*|youtu*) URL="$1"; shift ;;
        *)            [[ -z "$OUTPUT_BASE" ]] && OUTPUT_BASE="$1"; shift ;;
    esac
done

[[ -z "$URL" ]] && usage

check_deps

# ── Temp workspace ────────────────────────────────────────────────────────────
TMPDIR_WORK="$(mktemp -d /tmp/ipodvideo.XXXXXX)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# ── Step 1: Download ──────────────────────────────────────────────────────────
step "Downloading from YouTube…"

VIDEO_TITLE="$(yt-dlp --get-title "$URL" 2>/dev/null | head -1 \
    | tr -dc '[:alnum:] _-' | sed 's/  */ /g' | cut -c1-60)" || VIDEO_TITLE="video"

[[ -z "$OUTPUT_BASE" ]] && OUTPUT_BASE="$VIDEO_TITLE"
[[ -z "$OUTPUT_BASE" ]] && OUTPUT_BASE="ipod_output"

DOWNLOAD_PATH="$TMPDIR_WORK/source"

yt-dlp \
    --format "bestvideo+bestaudio/best" \
    --merge-output-format mkv \
    --output "$DOWNLOAD_PATH.%(ext)s" \
    --no-playlist \
    "$URL"

SOURCE_FILE="$(ls "$DOWNLOAD_PATH".* 2>/dev/null | head -1)"
[[ -z "$SOURCE_FILE" ]] && die "Download failed — no file found in $TMPDIR_WORK"
ok "Downloaded: $(basename "$SOURCE_FILE")"

# ── Step 2: Probe source ──────────────────────────────────────────────────────
step "Probing source file…"

SRC_W=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width -of csv=p=0 "$SOURCE_FILE" | head -1)
SRC_H=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=height -of csv=p=0 "$SOURCE_FILE" | head -1)
SRC_FPS=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate -of csv=p=0 "$SOURCE_FILE" | head -1)

info "Source: ${SRC_W}×${SRC_H} @ ${SRC_FPS} fps"

# ── Step 3: Crop detection ────────────────────────────────────────────────────
CROP_FILTER=""
EFF_W=$SRC_W
EFF_H=$SRC_H

if $DO_CROP; then
    step "Detecting black bars (pillarbox / letterbox)…"
    info "Sampling ~3 minutes of footage — this may take a moment…"

    CROPDETECT=$(ffmpeg -ss 30 -t 180 -i "$SOURCE_FILE" \
        -vf "cropdetect=limit=24:round=16:reset=0" \
        -an -f null - 2>&1 \
        | grep -o "crop=[0-9:]*" | sort | uniq -c | sort -rn | head -1)

    if [[ -n "$CROPDETECT" ]]; then
        CROP_PARAMS="${CROPDETECT#*=}"
        CROP_W=$(echo "$CROP_PARAMS" | cut -d: -f1)
        CROP_H=$(echo "$CROP_PARAMS" | cut -d: -f2)
        W_DIFF=$(( SRC_W - CROP_W ))
        H_DIFF=$(( SRC_H - CROP_H ))

        if [[ $W_DIFF -gt 16 || $H_DIFF -gt 16 ]]; then
            CROP_FILTER="crop=${CROP_PARAMS},"
            EFF_W=$CROP_W
            EFF_H=$CROP_H
            info "Crop applied: ${SRC_W}×${SRC_H} → ${CROP_W}×${CROP_H}"
            info "  (removed ${W_DIFF}px horizontal / ${H_DIFF}px vertical bars)"
        else
            ok "No significant bars detected — skipping crop"
        fi
    else
        warn "Crop detection returned no result — skipping"
    fi
else
    info "Crop detection disabled (--no-crop)"
fi

# ── Step 4: Aspect ratio → output profile ─────────────────────────────────────
step "Determining output profile from cropped dimensions (${EFF_W}×${EFF_H})…"

AR=$(echo "scale=4; $EFF_W / $EFF_H" | bc)

IS_16x9=$(echo "$AR >= 1.70 && $AR <= 1.85" | bc -l)
IS_4x3=$(echo  "$AR >= 1.20 && $AR <= 1.45" | bc -l)

CRF="${CRF_OVERRIDE:-22}"   # iPod screen is small — CRF 22 is visually lossless at this res

if [[ "$IS_16x9" == "1" ]]; then
    TARGET_LABEL="640×360 widescreen (16:9)"
    SCALE_FILTER="scale=640:360:flags=lanczos"

elif [[ "$IS_4x3" == "1" ]]; then
    TARGET_LABEL="640×480 fullscreen (4:3)"
    SCALE_FILTER="scale=640:480:flags=lanczos"

else
    # Unusual AR (2.35:1 ultrawide, 1.66:1, vertical, etc.)
    # Fit inside 640×480 preserving AR, pad remainder with black
    TARGET_LABEL="640×480 letterboxed (AR=${AR})"
    # Scale to fit within box, then pad to exactly 640×480
    SCALE_FILTER="scale=640:480:force_original_aspect_ratio=decrease:flags=lanczos,pad=640:480:(ow-iw)/2:(oh-ih)/2:black,scale=trunc(iw/2)*2:trunc(ih/2)*2"
fi

info "→ ${TARGET_LABEL}"

VF_CHAIN="${CROP_FILTER}${SCALE_FILTER}"

# ── Step 5: Encode ────────────────────────────────────────────────────────────
step "Encoding for iPod Video…"

OUTPUT_FILE="${OUTPUT_BASE}.m4v"

info "Output  : ${OUTPUT_FILE}"
info "Video   : H.264 Baseline L3.0, CRF ${CRF}, ≤2500kbps, 30fps"
info "Audio   : AAC stereo, 160 kbps, 48 kHz"

ffmpeg -y \
    -i "$SOURCE_FILE" \
    -vf "${VF_CHAIN}" \
    -r 30 \
    -c:v libx264 \
    -profile:v baseline \
    -level:v 3.0 \
    -crf "$CRF" \
    -maxrate 2500k \
    -bufsize 5000k \
    -movflags +faststart \
    -c:a aac \
    -b:a 160k \
    -ac 2 \
    -ar 48000 \
    -map 0:v:0 \
    -map 0:a:0 \
    "$OUTPUT_FILE"

# ── Step 6: Summary ───────────────────────────────────────────────────────────
echo ""
ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "  Done!  →  ${BLD}${OUTPUT_FILE}${RST}"

FILE_SIZE=$(du -sh "$OUTPUT_FILE" 2>/dev/null | cut -f1)
PROBE_W=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width -of csv=p=0 "$OUTPUT_FILE" 2>/dev/null | head -1)
PROBE_H=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=height -of csv=p=0 "$OUTPUT_FILE" 2>/dev/null | head -1)
PROBE_FPS=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate -of csv=p=0 "$OUTPUT_FILE" 2>/dev/null | head -1)
PROBE_VBR=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=bit_rate -of csv=p=0 "$OUTPUT_FILE" 2>/dev/null | head -1)
PROBE_ABR=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=bit_rate -of csv=p=0 "$OUTPUT_FILE" 2>/dev/null | head -1)

info "  Profile    : ${TARGET_LABEL}"
info "  Resolution : ${PROBE_W}×${PROBE_H}"
info "  Frame rate : ${PROBE_FPS} fps"
info "  Video kbps : $(( ${PROBE_VBR:-0} / 1000 )) kbps"
info "  Audio kbps : $(( ${PROBE_ABR:-0} / 1000 )) kbps"
info "  File size  : ${FILE_SIZE}"
ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Drag the .m4v into iTunes / Music, then sync to your iPod."
