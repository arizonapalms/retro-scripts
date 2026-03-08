#!/usr/bin/env bash
# =============================================================================
#  appletv1-convert.sh  —  YouTube → 1st-Gen Apple TV converter
#
#  Deps: yt-dlp, ffmpeg, bc  (all must be on your PATH)
#  Usage: ./appletv1-convert.sh <YouTube-URL> [output-name]
#
#  Resolution logic (measured AFTER crop detection):
#    16:9 content  →  1280×720 @ 24 fps  (Apple TV 1 HD ceiling)
#    All other AR  →   640×480 @ 30 fps  (4:3, 2.35:1, 1.85:1, etc.)
#
#  Audio: AAC stereo @ 256 kbps — maximum quality Apple TV 1 supports
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
  $(basename "$0") https://youtu.be/dQw4w9WgXcQ "my-movie"

${BLD}Output:${RST}
  <output-basename>.m4v — ready to add to iTunes / Apple TV 1st gen

${BLD}Resolution logic (after crop detection):${RST}
  16:9 content  →  1280×720 @ 24 fps  (Apple TV 1 HD ceiling)
  All other AR  →   640×480 @ 30 fps  (4:3, 2.35:1, etc.)

${BLD}Audio:${RST}
  AAC stereo @ 256 kbps — maximum quality the Apple TV 1 supports

${BLD}Options:${RST}
  -h, --help    Show this help
  --no-crop     Skip automatic pillarbox/letterbox crop detection
  --crf N       Override video CRF (default: 18 for 720p, 20 for 480p)
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
TMPDIR_WORK="$(mktemp -d /tmp/appletv1.XXXXXX)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# ── Step 1: Download ──────────────────────────────────────────────────────────
step "Downloading from YouTube…"

VIDEO_TITLE="$(yt-dlp --get-title "$URL" 2>/dev/null | head -1 \
    | tr -dc '[:alnum:] _-' | sed 's/  */ /g' | cut -c1-60)" || VIDEO_TITLE="video"

[[ -z "$OUTPUT_BASE" ]] && OUTPUT_BASE="$VIDEO_TITLE"
[[ -z "$OUTPUT_BASE" ]] && OUTPUT_BASE="appletv_output"

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

# ── Step 4: Aspect ratio decision (on POST-CROP dimensions) ───────────────────
step "Determining output profile from cropped dimensions (${EFF_W}×${EFF_H})…"

# 16:9 = 1.7778 — accept 1.70–1.85 to handle slight variations
AR=$(echo "scale=4; $EFF_W / $EFF_H" | bc)
IS_16x9=$(echo "$AR >= 1.70 && $AR <= 1.85" | bc -l)

if [[ "$IS_16x9" == "1" ]]; then
    # 16:9 → 720p @ 24fps (Apple TV 1 H.264 HD ceiling)
    TARGET_LABEL="720p HD (16:9)"
    TARGET_FPS=24
    MAX_RATE="5000k"
    BUF_SIZE="10000k"
    H264_PROFILE="main"
    H264_LEVEL="3.1"
    CRF="${CRF_OVERRIDE:-18}"
    # Scale width to 1280, derive height from AR, ensure even dims
    SCALE_FILTER="scale=1280:-2:flags=lanczos,scale=trunc(iw/2)*2:trunc(ih/2)*2"
    info "→ ${TARGET_LABEL} @ ${TARGET_FPS}fps  (AR=${AR})"
else
    # Non-16:9 → 480p @ 30fps, fit inside 640×480 box
    TARGET_LABEL="480p SD"
    TARGET_FPS=30
    MAX_RATE="2500k"
    BUF_SIZE="5000k"
    H264_PROFILE="baseline"
    H264_LEVEL="3.0"
    CRF="${CRF_OVERRIDE:-20}"
    # Fit within 640×480, preserve AR, even dims
    SCALE_FILTER="scale='if(gt(iw/ih,640/480),640,-2)':'if(gt(iw/ih,640/480),-2,480)':flags=lanczos,scale=trunc(iw/2)*2:trunc(ih/2)*2"
    info "→ ${TARGET_LABEL} @ ${TARGET_FPS}fps  (AR=${AR})"
fi

VF_CHAIN="${CROP_FILTER}${SCALE_FILTER}"

# ── Step 5: Encode ────────────────────────────────────────────────────────────
step "Encoding for 1st-gen Apple TV…"

OUTPUT_FILE="${OUTPUT_BASE}.m4v"

info "Output  : ${OUTPUT_FILE}"
info "Video   : H.264 ${H264_PROFILE} L${H264_LEVEL}, CRF ${CRF}, ≤${MAX_RATE}, ${TARGET_FPS}fps"
info "Audio   : AAC stereo, 256 kbps, 44.1 kHz"

ffmpeg -y \
    -i "$SOURCE_FILE" \
    -vf "${VF_CHAIN}" \
    -r "$TARGET_FPS" \
    -c:v libx264 \
    -profile:v "$H264_PROFILE" \
    -level:v "$H264_LEVEL" \
    -crf "$CRF" \
    -maxrate "$MAX_RATE" \
    -bufsize "$BUF_SIZE" \
    -movflags +faststart \
    -c:a aac \
    -b:a 256k \
    -ac 2 \
    -ar 44100 \
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
info "Add to iTunes / Music app, then sync to your Apple TV."
