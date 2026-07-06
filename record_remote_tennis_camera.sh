#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./record_remote_tennis_camera.sh [options]

Configure and record the remote 4K tennis camera over SSH. The recording uses
camera defaults except for manual exposure time. It stays on the remote machine;
nothing is copied back automatically. Press Ctrl+C to stop when no duration is
set.

Defaults:
  SSH_TARGET=nvidia3@192.168.251.107
  DEVICE=/dev/video0
  REMOTE_OUT_ROOT=~/recordings/tennis
  VIDEO_SIZE=3840x2160
  FRAMERATE=30
  INPUT_FORMAT=mjpeg
  CONTAINER=mkv
  EXPOSURE_ABSOLUTE=200      # UVC units, usually 100us => about 20ms
  WHITE_BALANCE_AUTOMATIC=1
  WHITE_BALANCE_TEMPERATURE=4600
  BRIGHTNESS=-5
  CONTRAST=1
  SATURATION=64
  GAMMA=100
  GAIN=32
  POWER_LINE_FREQUENCY=1     # 1=50Hz, 2=60Hz
  SHARPNESS=2
  BACKLIGHT_COMPENSATION=4
  FOCUS_AUTOMATIC_CONTINUOUS=0
  FOCUS_ABSOLUTE=0
  DURATION=                  # seconds; empty records until Ctrl+C

Options:
  --target USER@HOST       SSH target. Default: nvidia3@192.168.251.107
  --device DEV             Remote V4L2 device. Default: /dev/video0
  --out-root DIR           Remote output root. Default: ~/recordings/tennis
  --duration SECONDS       Stop automatically after SECONDS.
  --exposure VALUE         exposure_time_absolute value. Default: 200
  --manual-wb VALUE        Disable auto white balance and set temperature.
                           Default behavior keeps auto white balance on.
  --brightness VALUE       Default: -5
  --contrast VALUE         Default: 1
  --saturation VALUE       Default: 64
  --sharpness VALUE        Default: 2
  --container mkv|mjpg     Default: mkv. mkv uses ffmpeg copy; mjpg uses v4l2-ctl.
  --dry-run                Print the remote command without running it.
  -h, --help               Show this help.

Examples:
  ./record_remote_tennis_camera.sh
  ./record_remote_tennis_camera.sh --duration 60
  ./record_remote_tennis_camera.sh --exposure 100 --duration 30
  ./record_remote_tennis_camera.sh --out-root /data/tennis-recordings
USAGE
}

quote() {
  printf '%q' "$1"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 127
  fi
}

SSH_TARGET="${SSH_TARGET:-nvidia3@192.168.251.107}"
DEVICE="${DEVICE:-/dev/video0}"
REMOTE_OUT_ROOT="${REMOTE_OUT_ROOT:-~/recordings/tennis}"
VIDEO_SIZE="${VIDEO_SIZE:-3840x2160}"
FRAMERATE="${FRAMERATE:-30}"
INPUT_FORMAT="${INPUT_FORMAT:-mjpeg}"
CONTAINER="${CONTAINER:-mkv}"
DURATION="${DURATION:-}"

EXPOSURE_ABSOLUTE="${EXPOSURE_ABSOLUTE:-200}"
WHITE_BALANCE_AUTOMATIC="${WHITE_BALANCE_AUTOMATIC:-1}"
WHITE_BALANCE_TEMPERATURE="${WHITE_BALANCE_TEMPERATURE:-4600}"
BRIGHTNESS="${BRIGHTNESS:--5}"
CONTRAST="${CONTRAST:-1}"
SATURATION="${SATURATION:-64}"
GAMMA="${GAMMA:-100}"
GAIN="${GAIN:-32}"
POWER_LINE_FREQUENCY="${POWER_LINE_FREQUENCY:-1}"
SHARPNESS="${SHARPNESS:-2}"
BACKLIGHT_COMPENSATION="${BACKLIGHT_COMPENSATION:-4}"
FOCUS_AUTOMATIC_CONTINUOUS="${FOCUS_AUTOMATIC_CONTINUOUS:-0}"
FOCUS_ABSOLUTE="${FOCUS_ABSOLUTE:-0}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --target)
      SSH_TARGET="$2"
      shift
      ;;
    --device)
      DEVICE="$2"
      shift
      ;;
    --out-root)
      REMOTE_OUT_ROOT="$2"
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
    --manual-wb)
      WHITE_BALANCE_AUTOMATIC=0
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

require_cmd ssh

V4L2_CTRLS="auto_exposure=1,exposure_time_absolute=${EXPOSURE_ABSOLUTE},white_balance_automatic=${WHITE_BALANCE_AUTOMATIC},brightness=${BRIGHTNESS},contrast=${CONTRAST},saturation=${SATURATION},gamma=${GAMMA},gain=${GAIN},power_line_frequency=${POWER_LINE_FREQUENCY},sharpness=${SHARPNESS},backlight_compensation=${BACKLIGHT_COMPENSATION},focus_automatic_continuous=${FOCUS_AUTOMATIC_CONTINUOUS},focus_absolute=${FOCUS_ABSOLUTE}"
if [[ "$WHITE_BALANCE_AUTOMATIC" == "0" ]]; then
  V4L2_CTRLS="${V4L2_CTRLS},white_balance_temperature=${WHITE_BALANCE_TEMPERATURE}"
fi

remote_script='
set -Eeuo pipefail

require_remote_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing remote command: $1" >&2
    exit 127
  fi
}

require_remote_cmd v4l2-ctl
if [[ "$CONTAINER" == "mkv" ]]; then
  require_remote_cmd ffmpeg
fi

timestamp="$(date "+%Y%m%d_%H%M%S")"
out_root="${REMOTE_OUT_ROOT/#\~/$HOME}"
out_dir="${out_root%/}/${timestamp}"
mkdir -p "$out_dir"

echo "Configuring ${DEVICE}"
v4l2-ctl -d "$DEVICE" --set-fmt-video="width=${WIDTH},height=${HEIGHT},pixelformat=MJPG" --set-parm="$FRAMERATE"
v4l2-ctl -d "$DEVICE" --set-ctrl="$V4L2_CTRLS"
sleep 1

v4l2-ctl -d "$DEVICE" --get-fmt-video --get-parm
v4l2-ctl -d "$DEVICE" --get-ctrl=brightness,contrast,saturation,white_balance_automatic,white_balance_temperature,gamma,gain,power_line_frequency,sharpness,backlight_compensation,auto_exposure,exposure_time_absolute,focus_automatic_continuous,focus_absolute

if [[ "$CONTAINER" == "mkv" ]]; then
  output="${out_dir}/${timestamp}_video0.mkv"
  echo "Recording MKV to ${output}"
  echo "Codec is copied from the camera MJPEG stream; no re-encoding."
  ffmpeg_args=(
    -hide_banner -loglevel info -n
    -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -i "$DEVICE"
    -map 0:v:0 -c:v copy -an -f matroska "$output"
  )
  if [[ -n "$DURATION" ]]; then
    ffmpeg_args=(
      -hide_banner -loglevel info -n
      -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -i "$DEVICE"
      -t "$DURATION" -map 0:v:0 -c:v copy -an -f matroska "$output"
    )
  fi
  exec ffmpeg "${ffmpeg_args[@]}"
else
  output="${out_dir}/${timestamp}_video0.mjpg"
  echo "Recording raw MJPEG stream to ${output}"
  if [[ -n "$DURATION" ]]; then
    frame_count="$(awk -v fps="$FRAMERATE" -v seconds="$DURATION" "BEGIN { printf \"%d\", fps * seconds }")"
    exec v4l2-ctl -d "$DEVICE" --stream-mmap=4 --stream-count="$frame_count" --stream-to="$output"
  fi
  exec v4l2-ctl -d "$DEVICE" --stream-mmap=4 --stream-to="$output"
fi
'

WIDTH="${VIDEO_SIZE%x*}"
HEIGHT="${VIDEO_SIZE#*x}"

remote_command="$(
  printf 'DEVICE=%s ' "$(quote "$DEVICE")"
  printf 'REMOTE_OUT_ROOT=%s ' "$(quote "$REMOTE_OUT_ROOT")"
  printf 'VIDEO_SIZE=%s ' "$(quote "$VIDEO_SIZE")"
  printf 'WIDTH=%s ' "$(quote "$WIDTH")"
  printf 'HEIGHT=%s ' "$(quote "$HEIGHT")"
  printf 'FRAMERATE=%s ' "$(quote "$FRAMERATE")"
  printf 'INPUT_FORMAT=%s ' "$(quote "$INPUT_FORMAT")"
  printf 'CONTAINER=%s ' "$(quote "$CONTAINER")"
  printf 'DURATION=%s ' "$(quote "$DURATION")"
  printf 'V4L2_CTRLS=%s ' "$(quote "$V4L2_CTRLS")"
  printf 'bash -s <<%s\n%s\n%s\n' "'REMOTE_RECORD_SCRIPT'" "$remote_script" 'REMOTE_RECORD_SCRIPT'
)"

echo "Remote target: ${SSH_TARGET}"
echo "Remote output root: ${REMOTE_OUT_ROOT}"
echo "Container: ${CONTAINER}"
echo "Controls: ${V4L2_CTRLS}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "Remote command:"
  printf '%s\n' "$remote_command"
  exit 0
fi

ssh "$SSH_TARGET" "$remote_command"
