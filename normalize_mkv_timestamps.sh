#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./normalize_mkv_timestamps.sh [options] <session_dir|video...>

Remux MKV/MP4/AVI/MOV files whose packet timestamps were recorded as absolute
Unix times. Directory inputs are normalized independently, so shell globs like
recordings/* are safe for batch repair. Explicit video file inputs are treated
as one group so relative camera timing is preserved.

By default outputs are written beside each input as:
  <name>_normalized.mkv
Directory scans skip files already ending in the selected suffix.

Options:
  --output-dir DIR     Write normalized files into DIR.
                       With multiple directory inputs, writes one subdirectory
                       per input directory to avoid filename collisions.
  --suffix SUFFIX      Output suffix before .mkv. Default: _normalized
  --base-epoch VALUE   Timestamp offset to subtract. Default: earliest first
                       video packet PTS across all inputs.
  --overwrite          Allow replacing existing output files.
  --dry-run            Print ffmpeg commands without writing files.
  -h, --help           Show this help.

Examples:
  ./normalize_mkv_timestamps.sh recordings/20260701_154812
  ./normalize_mkv_timestamps.sh recordings/*
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
    if [[ "$path" == *"${SUFFIX}.mkv" ]]; then
      continue
    fi
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

process_group() {
  local group_label="$1"
  local group_output_dir="$2"
  local group_base_epoch="$BASE_EPOCH"
  local pts video dir base stem output
  local ffmpeg_args

  if [[ "${#VIDEO_FILES[@]}" -eq 0 ]]; then
    echo "No video files found in ${group_label}." >&2
    return 0
  fi

  if [[ -z "$group_base_epoch" ]]; then
    for video in "${VIDEO_FILES[@]}"; do
      pts="$(first_video_pts "$video")"
      if ! is_number "$pts"; then
        echo "Could not read first video PTS from: $video" >&2
        exit 1
      fi
      if [[ -z "$group_base_epoch" ]] || number_less_than "$pts" "$group_base_epoch"; then
        group_base_epoch="$pts"
      fi
    done
  fi

  if [[ "$DRY_RUN" -eq 0 && -n "$group_output_dir" ]]; then
    mkdir -p "$group_output_dir"
  fi

  echo
  echo "Group: ${group_label}"
  echo "Subtracting timestamp base: ${group_base_epoch}"

  for video in "${VIDEO_FILES[@]}"; do
    dir="$(dirname "$video")"
    base="$(basename "$video")"
    stem="${base%.*}"

    if [[ -n "$group_output_dir" ]]; then
      output="${group_output_dir%/}/${stem}${SUFFIX}.mkv"
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
      -output_ts_offset "-${group_base_epoch}"
      -metadata "soft_sync_base_epoch=${group_base_epoch}"
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

DIR_INPUTS=()
FILE_INPUTS=()
for input in "${POSITIONAL[@]}"; do
  if [[ -d "$input" ]]; then
    DIR_INPUTS+=("$input")
  elif [[ -f "$input" ]]; then
    if ! is_video_file "$input"; then
      echo "Not a supported video file: $input" >&2
      exit 2
    fi
    FILE_INPUTS+=("$input")
  else
    echo "Input not found: $input" >&2
    exit 2
  fi
done

GROUP_COUNT="${#DIR_INPUTS[@]}"
if [[ "${#FILE_INPUTS[@]}" -gt 0 ]]; then
  GROUP_COUNT=$((GROUP_COUNT + 1))
fi

if [[ "$GROUP_COUNT" -eq 0 ]]; then
  echo "No video files found." >&2
  exit 1
fi

PROCESSED_GROUPS=0
for input_dir in "${DIR_INPUTS[@]-}"; do
  VIDEO_FILES=()
  add_videos_from_dir "$input_dir"

  group_output_dir=""
  if [[ -n "$OUTPUT_DIR" ]]; then
    if [[ "$GROUP_COUNT" -gt 1 ]]; then
      group_output_dir="${OUTPUT_DIR%/}/$(basename "$input_dir")"
    else
      group_output_dir="$OUTPUT_DIR"
    fi
  fi

  process_group "$input_dir" "$group_output_dir"
  PROCESSED_GROUPS=$((PROCESSED_GROUPS + 1))
done

if [[ "${#FILE_INPUTS[@]}" -gt 0 ]]; then
  VIDEO_FILES=()
  for input_file in "${FILE_INPUTS[@]}"; do
    VIDEO_FILES+=("$input_file")
  done

  group_output_dir="$OUTPUT_DIR"
  if [[ "$GROUP_COUNT" -gt 1 && -n "$OUTPUT_DIR" ]]; then
    group_output_dir="${OUTPUT_DIR%/}/files"
  fi

  process_group "explicit files" "$group_output_dir"
  PROCESSED_GROUPS=$((PROCESSED_GROUPS + 1))
fi

if [[ "$PROCESSED_GROUPS" -eq 0 ]]; then
  echo "No video files found." >&2
  exit 1
fi

echo
echo "Done."
