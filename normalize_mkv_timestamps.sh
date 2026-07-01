#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./normalize_mkv_timestamps.sh [options] <session_dir|video...>

Remux MKV/MP4/AVI/MOV files whose packet timestamps were recorded as absolute
Unix times. The script subtracts one common base timestamp from all inputs so
container durations become normal while relative camera timing is preserved.

By default outputs are written beside each input as:
  <name>_normalized.mkv

Options:
  --output-dir DIR     Write normalized files into DIR.
  --suffix SUFFIX      Output suffix before .mkv. Default: _normalized
  --base-epoch VALUE   Timestamp offset to subtract. Default: earliest first
                       video packet PTS across all inputs.
  --overwrite          Allow replacing existing output files.
  --dry-run            Print ffmpeg commands without writing files.
  -h, --help           Show this help.

Examples:
  ./normalize_mkv_timestamps.sh recordings/20260701_154812
  ./normalize_mkv_timestamps.sh --output-dir fixed recordings/20260701_154812/*.mkv
  ./normalize_mkv_timestamps.sh --base-epoch 1782893181 recordings/20260701_154812/*.mkv
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 127
  fi
}

is_video_file() {
  local lower

  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.mkv|*.mp4|*.avi|*.mov)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

add_videos_from_dir() {
  local dir="$1"
  local path

  while IFS= read -r path; do
    VIDEO_FILES+=("$path")
  done < <(find "$dir" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' -o -iname '*.mov' \) | sort)
}

first_video_pts() {
  local file="$1"

  ffprobe -v error \
    -select_streams v:0 \
    -show_entries packet=pts_time \
    -of csv=p=0 \
    -read_intervals '%+#1' \
    "$file" | sed -n '1p'
}

is_number() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

number_less_than() {
  awk -v left="$1" -v right="$2" 'BEGIN { exit !(left < right) }'
}

print_command() {
  local arg

  printf 'ffmpeg'
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

OUTPUT_DIR=""
SUFFIX="_normalized"
BASE_EPOCH=""
OVERWRITE=0
DRY_RUN=0

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --output-dir)
      if [[ $# -lt 2 ]]; then
        echo "--output-dir requires a directory." >&2
        exit 2
      fi
      OUTPUT_DIR="$2"
      shift
      ;;
    --suffix)
      if [[ $# -lt 2 ]]; then
        echo "--suffix requires a value." >&2
        exit 2
      fi
      SUFFIX="$2"
      shift
      ;;
    --base-epoch)
      if [[ $# -lt 2 ]]; then
        echo "--base-epoch requires a value." >&2
        exit 2
      fi
      BASE_EPOCH="$2"
      shift
      ;;
    --overwrite)
      OVERWRITE=1
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
      POSITIONAL+=("$1")
      ;;
  esac
  shift
done

if [[ "${#POSITIONAL[@]}" -eq 0 ]]; then
  usage >&2
  exit 2
fi

if [[ -n "$BASE_EPOCH" ]] && ! is_number "$BASE_EPOCH"; then
  echo "--base-epoch must be a number." >&2
  exit 2
fi

require_cmd awk
require_cmd ffmpeg
require_cmd ffprobe
require_cmd find
require_cmd sed
require_cmd sort
require_cmd tr

VIDEO_FILES=()
for input in "${POSITIONAL[@]}"; do
  if [[ -d "$input" ]]; then
    add_videos_from_dir "$input"
  elif [[ -f "$input" ]]; then
    if ! is_video_file "$input"; then
      echo "Not a supported video file: $input" >&2
      exit 2
    fi
    VIDEO_FILES+=("$input")
  else
    echo "Input not found: $input" >&2
    exit 2
  fi
done

if [[ "${#VIDEO_FILES[@]}" -eq 0 ]]; then
  echo "No video files found." >&2
  exit 1
fi

if [[ -z "$BASE_EPOCH" ]]; then
  for video in "${VIDEO_FILES[@]}"; do
    pts="$(first_video_pts "$video")"
    if ! is_number "$pts"; then
      echo "Could not read first video PTS from: $video" >&2
      exit 1
    fi
    if [[ -z "$BASE_EPOCH" ]] || number_less_than "$pts" "$BASE_EPOCH"; then
      BASE_EPOCH="$pts"
    fi
  done
fi

if [[ "$DRY_RUN" -eq 0 && -n "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

echo "Subtracting timestamp base: ${BASE_EPOCH}"

for video in "${VIDEO_FILES[@]}"; do
  dir="$(dirname "$video")"
  base="$(basename "$video")"
  stem="${base%.*}"

  if [[ -n "$OUTPUT_DIR" ]]; then
    output="${OUTPUT_DIR%/}/${stem}${SUFFIX}.mkv"
  else
    output="${dir}/${stem}${SUFFIX}.mkv"
  fi

  if [[ "$output" == "$video" ]]; then
    echo "Output path would overwrite input: $video" >&2
    echo "Use a non-empty --suffix or --output-dir." >&2
    exit 2
  fi

  ffmpeg_args=(-hide_banner -loglevel info)
  if [[ "$OVERWRITE" -eq 1 ]]; then
    ffmpeg_args+=(-y)
  else
    ffmpeg_args+=(-n)
  fi
  ffmpeg_args+=(
    -copyts
    -i "$video"
    -map 0
    -c copy
    -output_ts_offset "-${BASE_EPOCH}"
    -metadata "soft_sync_base_epoch=${BASE_EPOCH}"
    -metadata "normalized_from=$(basename "$video")"
    -f matroska
    "$output"
  )

  echo
  echo "Normalizing ${video} -> ${output}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_command "${ffmpeg_args[@]}"
  else
    if [[ -e "$output" && "$OVERWRITE" -eq 0 ]]; then
      echo "Output already exists: $output" >&2
      echo "Use --overwrite to replace it." >&2
      exit 1
    fi
    ffmpeg "${ffmpeg_args[@]}"
  fi
done

echo
echo "Done."
