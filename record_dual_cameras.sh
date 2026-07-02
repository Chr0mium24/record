#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./record_dual_cameras.sh [--preview|--no-preview] [--soft-sync|--no-soft-sync] [--parallel|--single-process] [output_root]

Records two V4L2 MJPEG cameras at full resolution. By default preview is
disabled, parallel capture is enabled, and soft sync is enabled. Parallel
capture starts one ffmpeg process per camera from a shared barrier so V4L2
device opening does not serialize the first frames. Soft sync uses V4L2 absolute
timestamps, then normalizes recorded MKV timestamps against the recording start
time so container durations remain usable; it is not hardware sync. Press q in
the terminal to stop when preview is disabled; press q in the preview window
when preview is enabled.

Defaults:
  CAM_A=/dev/video2
  CAM_B=/dev/video0
  VIDEO_SIZE=3840x2160
  FRAMERATE=30
  INPUT_FORMAT=mjpeg
  OUT_ROOT=recordings
  PREVIEW=0
  SOFT_SYNC=1
  PARALLEL_CAPTURE=1
  PREVIEW_WIDTH=640
  PREVIEW_FPS=15
  PREVIEW_PORT=23456
  V4L2_CTRLS=
  V4L2_CTRL_SETTLE=1

Examples:
  ./record_dual_cameras.sh
  ./record_dual_cameras.sh --preview
  ./record_dual_cameras.sh /data/camera-recordings
  SOFT_SYNC=0 ./record_dual_cameras.sh
  ./record_dual_cameras.sh --single-process
  V4L2_CTRLS=auto_exposure=1,exposure_time_absolute=166 ./record_dual_cameras.sh
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

  interrupt_parallel_ffmpeg

  local pid
  for pid in "${FFMPEG_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

interrupt_parallel_ffmpeg() {
  local pid

  for pid in "${FFMPEG_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill -INT "$pid" 2>/dev/null || true
    fi
  done
}

start_parallel_ffmpeg() {
  local camera="$1"
  local output="$2"
  local log_file="$3"
  local start_fifo="$4"

  (
    read -r _ < "$start_fifo"
    exec ffmpeg -hide_banner -loglevel info -n "${FFMPEG_GLOBAL_ARGS[@]}" \
      -thread_queue_size "$THREAD_QUEUE_SIZE" \
      "${FFMPEG_INPUT_SYNC_ARGS[@]}" -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -i "$camera" \
      -map 0:v:0 -c:v copy -an "${FFMPEG_OUTPUT_SYNC_ARGS[@]}" -f matroska "$output" \
      < /dev/null
  ) >"$log_file" 2>&1 &
  FFMPEG_PIDS+=("$!")
}

release_parallel_ffmpeg() {
  local release_a release_b

  printf 'go\n' > "$START_FIFO_A" &
  release_a=$!
  printf 'go\n' > "$START_FIFO_B" &
  release_b=$!
  wait "$release_a"
  wait "$release_b"
}

any_parallel_ffmpeg_running() {
  local pid

  for pid in "${FFMPEG_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

all_parallel_ffmpeg_running() {
  local pid

  for pid in "${FFMPEG_PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
  done
  return 0
}

wait_parallel_ffmpeg() {
  local status=0
  local pid pid_status

  for pid in "${FFMPEG_PIDS[@]}"; do
    if wait "$pid"; then
      pid_status=0
    else
      pid_status=$?
    fi

    if [[ "$STOP_REQUESTED" -eq 1 && "$pid_status" -eq 255 ]]; then
      pid_status=0
    fi
    if [[ "$pid_status" -ne 0 ]]; then
      status="$pid_status"
    fi
  done

  return "$status"
}

monitor_parallel_ffmpeg() {
  local line

  while any_parallel_ffmpeg_running; do
    if ! all_parallel_ffmpeg_running; then
      STOP_REQUESTED=1
      interrupt_parallel_ffmpeg
      break
    fi

    if IFS= read -r -t 0.5 line; then
      if [[ "$line" == "q" || "$line" == "Q" ]]; then
        STOP_REQUESTED=1
        interrupt_parallel_ffmpeg
        break
      fi
    else
      sleep 0.1
    fi
  done

  wait_parallel_ffmpeg
}

print_parallel_logs() {
  local log_file

  for log_file in "$LOG_A" "$LOG_B"; do
    if [[ -f "$log_file" ]]; then
      echo
      echo "Last ffmpeg log lines from ${log_file}:"
      tail -80 "$log_file"
    fi
  done
}

apply_camera_controls() {
  local camera

  if [[ -z "$V4L2_CTRLS" ]]; then
    return 0
  fi

  require_cmd v4l2-ctl
  for camera in "$CAM_A" "$CAM_B"; do
    echo "Applying V4L2 controls to ${camera}: ${V4L2_CTRLS}"
    v4l2-ctl --device="$camera" --set-ctrl="$V4L2_CTRLS"
  done
  echo "Waiting ${V4L2_CTRL_SETTLE}s for camera controls to settle."
  sleep "$V4L2_CTRL_SETTLE"
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
PREVIEW="${PREVIEW:-0}"
SOFT_SYNC="${SOFT_SYNC:-1}"
PARALLEL_CAPTURE="${PARALLEL_CAPTURE:-1}"

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
    --soft-sync)
      SOFT_SYNC=1
      ;;
    --no-soft-sync)
      SOFT_SYNC=0
      ;;
    --parallel)
      PARALLEL_CAPTURE=1
      ;;
    --single-process)
      PARALLEL_CAPTURE=0
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

case "$SOFT_SYNC" in
  1|true|yes|on)
    SOFT_SYNC=1
    ;;
  0|false|no|off)
    SOFT_SYNC=0
    ;;
  *)
    echo "SOFT_SYNC must be 1 or 0." >&2
    exit 2
    ;;
esac

case "$PARALLEL_CAPTURE" in
  1|true|yes|on)
    PARALLEL_CAPTURE=1
    ;;
  0|false|no|off)
    PARALLEL_CAPTURE=0
    ;;
  *)
    echo "PARALLEL_CAPTURE must be 1 or 0." >&2
    exit 2
    ;;
esac

if [[ "$PREVIEW" -eq 1 && "$PARALLEL_CAPTURE" -eq 1 ]]; then
  PARALLEL_CAPTURE=0
fi

if [[ "$PREVIEW" -eq 1 || "$PARALLEL_CAPTURE" -eq 1 ]]; then
  require_cmd mkfifo
  require_cmd mktemp
fi

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
V4L2_CTRLS="${V4L2_CTRLS:-}"
V4L2_CTRL_SETTLE="${V4L2_CTRL_SETTLE:-1}"

FFMPEG_GLOBAL_ARGS=()
FFMPEG_INPUT_SYNC_ARGS=()
FFMPEG_OUTPUT_SYNC_ARGS=()
apply_camera_controls
if [[ "$SOFT_SYNC" -eq 1 ]]; then
  FFMPEG_GLOBAL_ARGS=(-copyts)
  FFMPEG_INPUT_SYNC_ARGS=(-timestamps abs)
  SOFT_SYNC_BASE_EPOCH="$(date '+%s.%N')"
  SOFT_SYNC_BASE_TIME_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  FFMPEG_OUTPUT_SYNC_ARGS=(
    -output_ts_offset "-${SOFT_SYNC_BASE_EPOCH}"
    -metadata "soft_sync_base_epoch=${SOFT_SYNC_BASE_EPOCH}"
    -metadata "soft_sync_base_time_utc=${SOFT_SYNC_BASE_TIME_UTC}"
  )
fi

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
CAM_A_LABEL="$(sanitize_label "$(basename "$CAM_A")")"
CAM_B_LABEL="$(sanitize_label "$(basename "$CAM_B")")"

mkdir -p "$OUT_ROOT"
OUT_DIR="$(make_unique_dir "${OUT_ROOT%/}/${TIMESTAMP}")"
OUT_A="${OUT_DIR}/${TIMESTAMP}_${CAM_A_LABEL}.mkv"
OUT_B="${OUT_DIR}/${TIMESTAMP}_${CAM_B_LABEL}.mkv"

TMP_DIR=""
CONTROL_FIFO=""
START_FIFO_A=""
START_FIFO_B=""
CONTROL_FD_OPEN=0
FFMPEG_PID=""
FFMPEG_PIDS=()
STOP_REQUESTED=0
LOG_A="${OUT_A%.mkv}.ffmpeg.log"
LOG_B="${OUT_B%.mkv}.ffmpeg.log"

trap cleanup EXIT INT TERM

echo "Saving full-resolution recordings:"
echo "  ${CAM_A} -> ${OUT_A}"
echo "  ${CAM_B} -> ${OUT_B}"
if [[ "$SOFT_SYNC" -eq 1 ]]; then
  echo "Soft sync enabled: using V4L2 absolute timestamps normalized from ${SOFT_SYNC_BASE_TIME_UTC}."
else
  echo "Soft sync disabled."
fi
if [[ "$PREVIEW" -eq 0 ]]; then
  if [[ "$PARALLEL_CAPTURE" -eq 1 ]]; then
    TMP_DIR="$(mktemp -d)"
    START_FIFO_A="${TMP_DIR}/start-a"
    START_FIFO_B="${TMP_DIR}/start-b"
    mkfifo "$START_FIFO_A" "$START_FIFO_B"

    echo "Preview disabled. Parallel capture enabled. Press q then Enter or Ctrl+C to stop."
    echo "ffmpeg logs:"
    echo "  ${LOG_A}"
    echo "  ${LOG_B}"

    start_parallel_ffmpeg "$CAM_A" "$OUT_A" "$LOG_A" "$START_FIFO_A"
    start_parallel_ffmpeg "$CAM_B" "$OUT_B" "$LOG_B" "$START_FIFO_B"
    release_parallel_ffmpeg

    set +e
    monitor_parallel_ffmpeg
    FFMPEG_STATUS=$?
    set -e

    rm -rf "$TMP_DIR"
    TMP_DIR=""
  else
    echo "Preview disabled. Single-process capture enabled. Press q in this terminal or Ctrl+C to stop."
    set +e
    ffmpeg -hide_banner -loglevel info -n "${FFMPEG_GLOBAL_ARGS[@]}" \
      -thread_queue_size "$THREAD_QUEUE_SIZE" \
      "${FFMPEG_INPUT_SYNC_ARGS[@]}" -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -i "$CAM_A" \
      -thread_queue_size "$THREAD_QUEUE_SIZE" \
      "${FFMPEG_INPUT_SYNC_ARGS[@]}" -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -i "$CAM_B" \
      -map 0:v:0 -c:v copy -an "${FFMPEG_OUTPUT_SYNC_ARGS[@]}" -f matroska "$OUT_A" \
      -map 1:v:0 -c:v copy -an "${FFMPEG_OUTPUT_SYNC_ARGS[@]}" -f matroska "$OUT_B"
    FFMPEG_STATUS=$?
    set -e
  fi
  FFPLAY_STATUS=0
else
  TMP_DIR="$(mktemp -d)"
  CONTROL_FIFO="${TMP_DIR}/ffmpeg-control"
  mkfifo "$CONTROL_FIFO"

  echo "Opening preview on udp://127.0.0.1:${PREVIEW_PORT}"
  echo "Press q in the preview window to stop."

  ffmpeg -hide_banner -loglevel info -n "${FFMPEG_GLOBAL_ARGS[@]}" \
    -thread_queue_size "$THREAD_QUEUE_SIZE" \
    "${FFMPEG_INPUT_SYNC_ARGS[@]}" -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -i "$CAM_A" \
    -thread_queue_size "$THREAD_QUEUE_SIZE" \
    "${FFMPEG_INPUT_SYNC_ARGS[@]}" -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -i "$CAM_B" \
    -filter_complex "[0:v]fps=${PREVIEW_FPS},scale=${PREVIEW_WIDTH}:-2,setpts=PTS-STARTPTS[p0];[1:v]fps=${PREVIEW_FPS},scale=${PREVIEW_WIDTH}:-2,setpts=PTS-STARTPTS[p1];[p0][p1]hstack=inputs=2,format=yuv420p[preview]" \
    -map 0:v:0 -c:v copy -an "${FFMPEG_OUTPUT_SYNC_ARGS[@]}" -f matroska "$OUT_A" \
    -map 1:v:0 -c:v copy -an "${FFMPEG_OUTPUT_SYNC_ARGS[@]}" -f matroska "$OUT_B" \
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
  if [[ "$PARALLEL_CAPTURE" -eq 1 ]]; then
    print_parallel_logs >&2
  fi
  echo "ffmpeg exited with status ${FFMPEG_STATUS}" >&2
  exit "$FFMPEG_STATUS"
fi

if [[ "$FFPLAY_STATUS" -ne 0 ]]; then
  echo "ffplay exited with status ${FFPLAY_STATUS}; recordings were stopped." >&2
fi

echo "Done:"
echo "  ${OUT_A}"
echo "  ${OUT_B}"
