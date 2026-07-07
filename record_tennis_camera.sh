#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./record_tennis_camera.sh [options]

Configure and record the local 4K tennis camera. Run this script on the camera
computer itself. Press Ctrl+C to stop when no duration is set.

Defaults:
  DEVICE=/dev/video0
  OUT_ROOT=~/recordings/tennis
  VIDEO_SIZE=3840x2160
  FRAMERATE=30
  INPUT_FORMAT=mjpeg
  CONTAINER=mkv
  SAMPLE_FPS=                # empty keeps all frames; e.g. 3 keeps 3 fps
  EXPOSURE_ABSOLUTE=200      # UVC units, usually 100us => about 20ms
  WHITE_BALANCE_TEMPERATURE=4600
  BRIGHTNESS=-5
  CONTRAST=1
  SATURATION=64
  GAMMA=100
  GAIN=32
  POWER_LINE_FREQUENCY=1     # 1=50Hz, 2=60Hz
  SHARPNESS=1
  BACKLIGHT_COMPENSATION=0
  FOCUS_AUTOMATIC_CONTINUOUS=0
  DURATION=                  # seconds; empty records until Ctrl+C

Options:
  --device DEV             V4L2 device. Default: /dev/video0
  --out-root DIR           Output root. Default: ~/recordings/tennis
  --duration SECONDS       Stop automatically after SECONDS.
  --exposure VALUE         exposure_time_absolute value. Default: 200
  --wb VALUE               Fixed white_balance_temperature. Default: 4600
  --brightness VALUE       Default: -5
  --contrast VALUE         Default: 1
  --saturation VALUE       Default: 64
  --sharpness VALUE        Default: 1
  --container mkv|mjpg     Default: mkv. mkv uses ffmpeg copy; mjpg uses v4l2-ctl.
  --sample-fps VALUE        Keep only VALUE frames per second in MKV output.
                           Example: --sample-fps 3. This re-encodes MJPEG.
  --dry-run                Print commands without running them.
  -h, --help               Show this help.

Examples:
  ./record_tennis_camera.sh
  ./record_tennis_camera.sh --duration 60
  ./record_tennis_camera.sh --duration 60 --sample-fps 3
  ./record_tennis_camera.sh --exposure 100 --duration 30
  ./record_tennis_camera.sh --out-root /data/tennis-recordings
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 127
  fi
}

print_command() {
  local arg

  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
}

write_metadata() {
  local metadata="$1"

  {
    echo "timestamp=${TIMESTAMP}"
    echo "device=${DEVICE}"
    echo "output=${OUTPUT}"
    echo "container=${CONTAINER}"
    echo "video_size=${VIDEO_SIZE}"
    echo "framerate=${FRAMERATE}"
    echo "input_format=${INPUT_FORMAT}"
    echo "sample_fps=${SAMPLE_FPS}"
    echo "duration=${DURATION}"
    echo "v4l2_ctrls=${V4L2_CTRLS}"
    echo
    echo "[set_format_command]"
    print_command "${SET_FORMAT_CMD[@]}"
    echo
    echo "[set_controls_command]"
    print_command "${SET_CTRLS_CMD[@]}"
    echo
    echo "[record_command]"
    if [[ "$CONTAINER" == "mkv" ]]; then
      print_command "${FFMPEG_CMD[@]}"
    else
      print_command "${V4L2_RECORD_CMD[@]}"
    fi
    echo
    echo "[current_format]"
    v4l2-ctl -d "$DEVICE" --get-fmt-video --get-parm 2>&1 || true
    echo
    echo "[current_controls]"
    v4l2-ctl -d "$DEVICE" --get-ctrl=brightness,contrast,saturation,white_balance_automatic,white_balance_temperature,gamma,gain,power_line_frequency,sharpness,backlight_compensation,auto_exposure,exposure_time_absolute,focus_automatic_continuous,focus_absolute 2>&1 || true
    echo
    echo "[all_controls]"
    v4l2-ctl -d "$DEVICE" --list-ctrls-menus 2>&1 || true
  } > "$metadata"
}

DEVICE="${DEVICE:-/dev/video0}"
OUT_ROOT="${OUT_ROOT:-~/recordings/tennis}"
VIDEO_SIZE="${VIDEO_SIZE:-3840x2160}"
FRAMERATE="${FRAMERATE:-30}"
INPUT_FORMAT="${INPUT_FORMAT:-mjpeg}"
CONTAINER="${CONTAINER:-mkv}"
SAMPLE_FPS="${SAMPLE_FPS:-}"
DURATION="${DURATION:-}"

EXPOSURE_ABSOLUTE="${EXPOSURE_ABSOLUTE:-200}"
WHITE_BALANCE_TEMPERATURE="${WHITE_BALANCE_TEMPERATURE:-4600}"
BRIGHTNESS="${BRIGHTNESS:--5}"
CONTRAST="${CONTRAST:-1}"
SATURATION="${SATURATION:-64}"
GAMMA="${GAMMA:-100}"
GAIN="${GAIN:-32}"
POWER_LINE_FREQUENCY="${POWER_LINE_FREQUENCY:-1}"
SHARPNESS="${SHARPNESS:-1}"
BACKLIGHT_COMPENSATION="${BACKLIGHT_COMPENSATION:-0}"
FOCUS_AUTOMATIC_CONTINUOUS="${FOCUS_AUTOMATIC_CONTINUOUS:-0}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --device)
      DEVICE="$2"
      shift
      ;;
    --out-root)
      OUT_ROOT="$2"
      shift
      ;;
    --duration)
      DURATION="$2"
      shift
      ;;
    --exposure)
      EXPOSURE_ABSOLUTE="$2"
      shift
      ;;
    --wb|--manual-wb)
      WHITE_BALANCE_TEMPERATURE="$2"
      shift
      ;;
    --brightness)
      BRIGHTNESS="$2"
      shift
      ;;
    --contrast)
      CONTRAST="$2"
      shift
      ;;
    --saturation)
      SATURATION="$2"
      shift
      ;;
    --sharpness)
      SHARPNESS="$2"
      shift
      ;;
    --container)
      CONTAINER="$2"
      shift
      ;;
    --sample-fps)
      SAMPLE_FPS="$2"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      echo "Unexpected argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case "$CONTAINER" in
  mkv|mjpg)
    ;;
  *)
    echo "--container must be mkv or mjpg." >&2
    exit 2
    ;;
esac

if [[ -n "$DURATION" && ! "$DURATION" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "--duration must be a positive number of seconds." >&2
  exit 2
fi
if [[ -n "$SAMPLE_FPS" && ! "$SAMPLE_FPS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "--sample-fps must be a positive number." >&2
  exit 2
fi
if [[ "$CONTAINER" != "mkv" && -n "$SAMPLE_FPS" ]]; then
  echo "--sample-fps is only supported with --container mkv." >&2
  exit 2
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  require_cmd v4l2-ctl
  if [[ "$CONTAINER" == "mkv" ]]; then
    require_cmd ffmpeg
  fi
fi

WIDTH="${VIDEO_SIZE%x*}"
HEIGHT="${VIDEO_SIZE#*x}"
OUT_ROOT="${OUT_ROOT/#\~/$HOME}"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
OUT_DIR="${OUT_ROOT%/}/${TIMESTAMP}"
V4L2_CTRLS="auto_exposure=1,exposure_time_absolute=${EXPOSURE_ABSOLUTE},white_balance_automatic=0,white_balance_temperature=${WHITE_BALANCE_TEMPERATURE},brightness=${BRIGHTNESS},contrast=${CONTRAST},saturation=${SATURATION},gamma=${GAMMA},gain=${GAIN},power_line_frequency=${POWER_LINE_FREQUENCY},sharpness=${SHARPNESS},backlight_compensation=${BACKLIGHT_COMPENSATION},focus_automatic_continuous=${FOCUS_AUTOMATIC_CONTINUOUS}"

if [[ "$CONTAINER" == "mkv" ]]; then
  OUTPUT="${OUT_DIR}/${TIMESTAMP}_video0.mkv"
else
  OUTPUT="${OUT_DIR}/${TIMESTAMP}_video0.mjpg"
fi
METADATA="${OUTPUT%.*}.controls.txt"

SET_FORMAT_CMD=(v4l2-ctl -d "$DEVICE" --set-fmt-video="width=${WIDTH},height=${HEIGHT},pixelformat=MJPG" --set-parm="$FRAMERATE")
SET_CTRLS_CMD=(v4l2-ctl -d "$DEVICE" --set-ctrl="$V4L2_CTRLS")

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Output: ${OUTPUT}"
  echo "Metadata: ${METADATA}"
  echo "Controls: ${V4L2_CTRLS}"
  print_command "${SET_FORMAT_CMD[@]}"
  print_command "${SET_CTRLS_CMD[@]}"
else
  mkdir -p "$OUT_DIR"
  echo "Configuring ${DEVICE}"
  "${SET_FORMAT_CMD[@]}"
  "${SET_CTRLS_CMD[@]}"
  sleep 1
  v4l2-ctl -d "$DEVICE" --get-fmt-video --get-parm
  v4l2-ctl -d "$DEVICE" --get-ctrl=brightness,contrast,saturation,white_balance_automatic,white_balance_temperature,gamma,gain,power_line_frequency,sharpness,backlight_compensation,auto_exposure,exposure_time_absolute,focus_automatic_continuous,focus_absolute
fi

if [[ "$CONTAINER" == "mkv" ]]; then
  FFMPEG_CMD=(
    ffmpeg -hide_banner -loglevel info -n
    -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -i "$DEVICE"
  )
  if [[ -n "$DURATION" ]]; then
    FFMPEG_CMD+=(-t "$DURATION")
  fi
  if [[ -n "$SAMPLE_FPS" ]]; then
    FFMPEG_CMD+=(-vf "fps=${SAMPLE_FPS}" -map 0:v:0 -c:v mjpeg -q:v 3 -an -f matroska "$OUTPUT")
  else
    FFMPEG_CMD+=(-map 0:v:0 -c:v copy -an -f matroska "$OUTPUT")
  fi

  echo "Recording MKV to ${OUTPUT}"
  echo "Saving camera settings to ${METADATA}"
  if [[ -n "$SAMPLE_FPS" ]]; then
    echo "Keeping ${SAMPLE_FPS} fps and re-encoding as MJPEG."
  else
    echo "Codec is copied from the camera MJPEG stream; no re-encoding."
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_command "${FFMPEG_CMD[@]}"
  else
    write_metadata "$METADATA"
    exec "${FFMPEG_CMD[@]}"
  fi
else
  V4L2_RECORD_CMD=(v4l2-ctl -d "$DEVICE" --stream-mmap=4)
  if [[ -n "$DURATION" ]]; then
    FRAME_COUNT="$(awk -v fps="$FRAMERATE" -v seconds="$DURATION" 'BEGIN { printf "%d", fps * seconds }')"
    V4L2_RECORD_CMD+=(--stream-count="$FRAME_COUNT")
  fi
  V4L2_RECORD_CMD+=(--stream-to="$OUTPUT")

  echo "Recording raw MJPEG stream to ${OUTPUT}"
  echo "Saving camera settings to ${METADATA}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_command "${V4L2_RECORD_CMD[@]}"
  else
    write_metadata "$METADATA"
    exec "${V4L2_RECORD_CMD[@]}"
  fi
fi
