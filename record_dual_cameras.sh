#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./record_dual_cameras.sh [--no-preview] [output_root]

Records two V4L2 MJPEG cameras at full resolution. By default it also opens one
low-res side-by-side ffplay preview. Press q in the preview window to stop when
preview is enabled; press q in the terminal or Ctrl+C when preview is disabled.

Defaults:
  CAM_A=/dev/video2
  CAM_B=/dev/video0
  VIDEO_SIZE=3840x2160
  FRAMERATE=30
  INPUT_FORMAT=mjpeg
  OUT_ROOT=recordings
  PREVIEW=1
  PREVIEW_WIDTH=640
  PREVIEW_FPS=15
  PREVIEW_PORT=23456

Examples:
  ./record_dual_cameras.sh
  ./record_dual_cameras.sh --no-preview
  ./record_dual_cameras.sh /data/camera-recordings
  PREVIEW=0 ./record_dual_cameras.sh
  PREVIEW_WIDTH=480 PREVIEW_FPS=10 ./record_dual_cameras.sh
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 127
  fi
}

sanitize_label() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

make_unique_dir() {
  local base="$1"
  local candidate="$base"
  local suffix=1

  while ! mkdir "$candidate" 2>/dev/null; do
    candidate="${base}_${suffix}"
    suffix=$((suffix + 1))
  done

  printf '%s\n' "$candidate"
}

stop_ffmpeg() {
  if [[ -n "${FFMPEG_PID:-}" ]] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
    if [[ "${CONTROL_FD_OPEN:-0}" -eq 1 ]]; then
      printf 'q\n' >&3 2>/dev/null || true
    else
      kill -INT "$FFMPEG_PID" 2>/dev/null || true
    fi
    wait "$FFMPEG_PID" 2>/dev/null || true
  fi
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  stop_ffmpeg
  if [[ "${CONTROL_FD_OPEN:-0}" -eq 1 ]]; then
    exec 3>&- || true
  fi
  rm -rf "${TMP_DIR:-}"
  exit "$status"
}

require_cmd ffmpeg
require_cmd tr

OUT_ROOT_ARG=""
PREVIEW="${PREVIEW:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --no-preview)
      PREVIEW=0
      ;;
    --preview)
      PREVIEW=1
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$OUT_ROOT_ARG" ]]; then
        echo "Only one output_root argument is allowed." >&2
        usage >&2
        exit 2
      fi
      OUT_ROOT_ARG="$1"
      ;;
  esac
  shift
done

case "$PREVIEW" in
  1|true|yes|on)
    PREVIEW=1
    require_cmd ffplay
    require_cmd mkfifo
    require_cmd mktemp
    ;;
  0|false|no|off)
    PREVIEW=0
    ;;
  *)
    echo "PREVIEW must be 1 or 0." >&2
    exit 2
    ;;
esac

CAM_A="${CAM_A:-/dev/video2}"
CAM_B="${CAM_B:-/dev/video0}"
INPUT_FORMAT="${INPUT_FORMAT:-mjpeg}"
VIDEO_SIZE="${VIDEO_SIZE:-3840x2160}"
FRAMERATE="${FRAMERATE:-30}"
OUT_ROOT="${OUT_ROOT_ARG:-${OUT_ROOT:-recordings}}"
PREVIEW_WIDTH="${PREVIEW_WIDTH:-640}"
PREVIEW_FPS="${PREVIEW_FPS:-15}"
PREVIEW_PORT="${PREVIEW_PORT:-23456}"
THREAD_QUEUE_SIZE="${THREAD_QUEUE_SIZE:-1024}"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
CAM_A_LABEL="$(sanitize_label "$(basename "$CAM_A")")"
CAM_B_LABEL="$(sanitize_label "$(basename "$CAM_B")")"

mkdir -p "$OUT_ROOT"
OUT_DIR="$(make_unique_dir "${OUT_ROOT%/}/${TIMESTAMP}")"
OUT_A="${OUT_DIR}/${TIMESTAMP}_${CAM_A_LABEL}.mkv"
OUT_B="${OUT_DIR}/${TIMESTAMP}_${CAM_B_LABEL}.mkv"

TMP_DIR=""
CONTROL_FIFO=""
CONTROL_FD_OPEN=0
FFMPEG_PID=""

trap cleanup EXIT INT TERM

echo "Saving full-resolution recordings:"
echo "  ${CAM_A} -> ${OUT_A}"
echo "  ${CAM_B} -> ${OUT_B}"
if [[ "$PREVIEW" -eq 0 ]]; then
  echo "Preview disabled. Press q in this terminal or Ctrl+C to stop."
  set +e
  ffmpeg -hide_banner -loglevel info -n \
    -thread_queue_size "$THREAD_QUEUE_SIZE" \
    -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -i "$CAM_A" \
    -thread_queue_size "$THREAD_QUEUE_SIZE" \
    -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -i "$CAM_B" \
    -map 0:v:0 -c:v copy -an -f matroska "$OUT_A" \
    -map 1:v:0 -c:v copy -an -f matroska "$OUT_B"
  FFMPEG_STATUS=$?
  set -e
  FFPLAY_STATUS=0
else
  TMP_DIR="$(mktemp -d)"
  CONTROL_FIFO="${TMP_DIR}/ffmpeg-control"
  mkfifo "$CONTROL_FIFO"

  echo "Opening preview on udp://127.0.0.1:${PREVIEW_PORT}"
  echo "Press q in the preview window to stop."

  ffmpeg -hide_banner -loglevel info -n \
    -thread_queue_size "$THREAD_QUEUE_SIZE" \
    -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -i "$CAM_A" \
    -thread_queue_size "$THREAD_QUEUE_SIZE" \
    -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -i "$CAM_B" \
    -filter_complex "[0:v]fps=${PREVIEW_FPS},scale=${PREVIEW_WIDTH}:-2,setpts=PTS-STARTPTS[p0];[1:v]fps=${PREVIEW_FPS},scale=${PREVIEW_WIDTH}:-2,setpts=PTS-STARTPTS[p1];[p0][p1]hstack=inputs=2,format=yuv420p[preview]" \
    -map 0:v:0 -c:v copy -an -f matroska "$OUT_A" \
    -map 1:v:0 -c:v copy -an -f matroska "$OUT_B" \
    -map "[preview]" -an -c:v mpeg2video -q:v 5 -f mpegts "udp://127.0.0.1:${PREVIEW_PORT}?pkt_size=1316" \
    < "$CONTROL_FIFO" &
  FFMPEG_PID=$!

  exec 3>"$CONTROL_FIFO"
  CONTROL_FD_OPEN=1

  sleep 1
  if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
    set +e
    wait "$FFMPEG_PID"
    FFMPEG_STATUS=$?
    set -e
    exit "$FFMPEG_STATUS"
  fi

  set +e
  ffplay -hide_banner -loglevel warning \
    -fflags nobuffer -flags low_delay -framedrop \
    -window_title "Dual camera preview - press q to stop" \
    "udp://127.0.0.1:${PREVIEW_PORT}?fifo_size=1000000&overrun_nonfatal=1"
  FFPLAY_STATUS=$?

  printf 'q\n' >&3 2>/dev/null || true
  wait "$FFMPEG_PID"
  FFMPEG_STATUS=$?
  set -e

  exec 3>&-
  CONTROL_FD_OPEN=0
  rm -rf "$TMP_DIR"
  TMP_DIR=""
fi

trap - EXIT INT TERM

if [[ "$FFMPEG_STATUS" -ne 0 ]]; then
  echo "ffmpeg exited with status ${FFMPEG_STATUS}" >&2
  exit "$FFMPEG_STATUS"
fi

if [[ "$FFPLAY_STATUS" -ne 0 ]]; then
  echo "ffplay exited with status ${FFPLAY_STATUS}; recordings were stopped." >&2
fi

echo "Done:"
echo "  ${OUT_A}"
echo "  ${OUT_B}"
