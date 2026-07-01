#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./extract_yolo_frames.sh [options] <session>
  ./extract_yolo_frames.sh [options] <session_dir>
  ./extract_yolo_frames.sh [options] <video...>

Extract recording videos into the image layout used by the YOLO annotation
service. By default video0 is written as cam1 and video2 is written as cam2.

Defaults:
  RECORDINGS_ROOT=recordings
  DATASET_ROOT=tools/yolo/yolo/dataset
  FPS=2
  IMAGE_FORMAT=jpg
  JPEG_QUALITY=2
  PNG_COMPRESSION=3
  CAM_MAP=video0:cam1,video2:cam2

Options:
  --fps VALUE             Frames per second to extract. Default: 2
  --dataset-root DIR      Dataset root containing images/ and labels/.
                          Default: tools/yolo/yolo/dataset
  --images-dir DIR        Output image directory. Overrides --dataset-root.
  --labels-dir DIR        Label directory to create. Overrides --dataset-root.
  --recordings-root DIR   Root used when <session> is not a path. Default: recordings
  --session NAME          Output session prefix. Default: inferred from input.
  --format jpg|png        Output image format. Default: jpg
  --jpeg-quality VALUE    JPEG quality for ffmpeg -q:v. Lower is better. Default: 2
  --png-compression VALUE PNG compression level. Default: 3
  --cam-map MAP           Comma-separated source:target camera map.
                          Default: video0:cam1,video2:cam2
  --overwrite             Remove existing matching output frames before extracting.
  --dry-run               Print ffmpeg commands without writing files.
  -h, --help              Show this help.

Examples:
  ./extract_yolo_frames.sh 20260701_154812
  ./extract_yolo_frames.sh --fps 5 recordings/20260701_154812
  ./extract_yolo_frames.sh --dataset-root ../TennisBot/tools/yolo/yolo/dataset 20260701_154812
  ./extract_yolo_frames.sh recordings/20260701_154812/*video0*.mkv recordings/20260701_154812/*video2*.mkv

Output files:
  <session>_<cam>_frame_000001.jpg
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

validate_cam_map() {
  local entry key value
  local entries=()

  IFS=',' read -r -a entries <<< "$CAM_MAP"
  if [[ "${#entries[@]}" -eq 0 ]]; then
    echo "CAM_MAP cannot be empty." >&2
    exit 2
  fi

  for entry in "${entries[@]}"; do
    key="${entry%%:*}"
    value="${entry#*:}"
    if [[ "$entry" != *:* || -z "$key" || -z "$value" ]]; then
      echo "Invalid camera map entry: ${entry}" >&2
      echo "Expected format like video0:cam1,video2:cam2." >&2
      exit 2
    fi
  done
}

camera_label_for_file() {
  local file="$1"
  local base entry key value stem
  local entries=()

  base="$(basename "$file")"
  IFS=',' read -r -a entries <<< "$CAM_MAP"
  for entry in "${entries[@]}"; do
    key="${entry%%:*}"
    value="${entry#*:}"
    if [[ "$base" == *"$key"* ]]; then
      sanitize_label "$value"
      return 0
    fi
  done

  stem="${base%.*}"
  if [[ "$stem" =~ (cam[0-9A-Za-z_.-]+) ]]; then
    sanitize_label "${BASH_REMATCH[1]}"
  else
    sanitize_label "$stem"
  fi
}

seen_label() {
  local candidate="$1"
  local existing

  for existing in "${CAM_LABELS[@]-}"; do
    if [[ "$existing" == "$candidate" ]]; then
      return 0
    fi
  done

  return 1
}

print_command() {
  local arg

  printf 'ffmpeg'
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

collect_existing_frames() {
  local camera="$1"
  local restore_nullglob

  restore_nullglob="$(shopt -p nullglob || true)"
  shopt -s nullglob
  MATCHING_FRAMES=( "${IMAGES_DIR%/}/${SESSION}_${camera}_frame_"*".${IMAGE_FORMAT}" )
  eval "$restore_nullglob"
}

FPS="${FPS:-2}"
DATASET_ROOT="${DATASET_ROOT:-tools/yolo/yolo/dataset}"
IMAGES_DIR="${IMAGES_DIR:-}"
LABELS_DIR="${LABELS_DIR:-}"
RECORDINGS_ROOT="${RECORDINGS_ROOT:-recordings}"
SESSION="${SESSION:-}"
IMAGE_FORMAT="${IMAGE_FORMAT:-jpg}"
JPEG_QUALITY="${JPEG_QUALITY:-2}"
PNG_COMPRESSION="${PNG_COMPRESSION:-3}"
CAM_MAP="${CAM_MAP:-video0:cam1,video2:cam2}"
OVERWRITE=0
DRY_RUN=0

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --fps)
      if [[ $# -lt 2 ]]; then
        echo "--fps requires a value." >&2
        exit 2
      fi
      FPS="$2"
      shift
      ;;
    --dataset-root)
      if [[ $# -lt 2 ]]; then
        echo "--dataset-root requires a directory." >&2
        exit 2
      fi
      DATASET_ROOT="$2"
      shift
      ;;
    --images-dir)
      if [[ $# -lt 2 ]]; then
        echo "--images-dir requires a directory." >&2
        exit 2
      fi
      IMAGES_DIR="$2"
      shift
      ;;
    --labels-dir)
      if [[ $# -lt 2 ]]; then
        echo "--labels-dir requires a directory." >&2
        exit 2
      fi
      LABELS_DIR="$2"
      shift
      ;;
    --recordings-root)
      if [[ $# -lt 2 ]]; then
        echo "--recordings-root requires a directory." >&2
        exit 2
      fi
      RECORDINGS_ROOT="$2"
      shift
      ;;
    --session)
      if [[ $# -lt 2 ]]; then
        echo "--session requires a name." >&2
        exit 2
      fi
      SESSION="$2"
      shift
      ;;
    --format|--image-format)
      if [[ $# -lt 2 ]]; then
        echo "$1 requires a value." >&2
        exit 2
      fi
      IMAGE_FORMAT="$2"
      shift
      ;;
    --jpeg-quality)
      if [[ $# -lt 2 ]]; then
        echo "--jpeg-quality requires a value." >&2
        exit 2
      fi
      JPEG_QUALITY="$2"
      shift
      ;;
    --png-compression)
      if [[ $# -lt 2 ]]; then
        echo "--png-compression requires a value." >&2
        exit 2
      fi
      PNG_COMPRESSION="$2"
      shift
      ;;
    --cam-map)
      if [[ $# -lt 2 ]]; then
        echo "--cam-map requires a value." >&2
        exit 2
      fi
      CAM_MAP="$2"
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

case "$IMAGE_FORMAT" in
  jpg|jpeg)
    IMAGE_FORMAT="jpg"
    ;;
  png)
    IMAGE_FORMAT="png"
    ;;
  *)
    echo "--format must be jpg or png." >&2
    exit 2
    ;;
esac

if ! [[ "$FPS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "--fps must be a positive number." >&2
  exit 2
fi

if ! [[ "$JPEG_QUALITY" =~ ^[0-9]+$ ]]; then
  echo "--jpeg-quality must be an integer." >&2
  exit 2
fi

if ! [[ "$PNG_COMPRESSION" =~ ^[0-9]+$ ]]; then
  echo "--png-compression must be an integer." >&2
  exit 2
fi

require_cmd ffmpeg
require_cmd find
require_cmd sort
require_cmd tr

validate_cam_map

if [[ -z "$IMAGES_DIR" ]]; then
  IMAGES_DIR="${DATASET_ROOT%/}/images"
fi

if [[ -z "$LABELS_DIR" ]]; then
  LABELS_DIR="${DATASET_ROOT%/}/labels"
fi

VIDEO_FILES=()
for input in "${POSITIONAL[@]}"; do
  if [[ -d "$input" ]]; then
    add_videos_from_dir "$input"
    if [[ -z "$SESSION" ]]; then
      SESSION="$(basename "$input")"
    fi
  elif [[ -f "$input" ]]; then
    if ! is_video_file "$input"; then
      echo "Not a supported video file: $input" >&2
      exit 2
    fi
    VIDEO_FILES+=("$input")
  elif [[ "${#POSITIONAL[@]}" -eq 1 && -d "${RECORDINGS_ROOT%/}/$input" ]]; then
    add_videos_from_dir "${RECORDINGS_ROOT%/}/$input"
    if [[ -z "$SESSION" ]]; then
      SESSION="$input"
    fi
  else
    echo "Input not found: $input" >&2
    exit 2
  fi
done

if [[ "${#VIDEO_FILES[@]}" -eq 0 ]]; then
  echo "No video files found." >&2
  exit 1
fi

if [[ -z "$SESSION" ]]; then
  first_base="$(basename "${VIDEO_FILES[0]}")"
  if [[ "$first_base" =~ ^([0-9]{8}_[0-9]{6}) ]]; then
    SESSION="${BASH_REMATCH[1]}"
  else
    SESSION="$(basename "$(dirname "${VIDEO_FILES[0]}")")"
  fi
fi
SESSION="$(sanitize_label "$SESSION")"

CAM_LABELS=()
CAMERA_BY_FILE=()
for video in "${VIDEO_FILES[@]}"; do
  cam="$(camera_label_for_file "$video")"
  if seen_label "$cam"; then
    echo "Multiple videos map to camera '${cam}'. Adjust --cam-map or pass one file per camera." >&2
    exit 2
  fi
  CAM_LABELS+=("$cam")
  CAMERA_BY_FILE+=("$cam")
done

if [[ "$DRY_RUN" -eq 0 ]]; then
  mkdir -p "$IMAGES_DIR" "$LABELS_DIR"
fi

echo "Session: ${SESSION}"
echo "FPS: ${FPS}"
echo "Images: ${IMAGES_DIR}"
echo "Labels: ${LABELS_DIR}"

for index in "${!VIDEO_FILES[@]}"; do
  video="${VIDEO_FILES[$index]}"
  cam="${CAMERA_BY_FILE[$index]}"
  output_pattern="${IMAGES_DIR%/}/${SESSION}_${cam}_frame_%06d.${IMAGE_FORMAT}"
  ffmpeg_args=(-hide_banner -loglevel info)

  if [[ "$OVERWRITE" -eq 1 ]]; then
    ffmpeg_args+=(-y)
  else
    ffmpeg_args+=(-n)
  fi

  ffmpeg_args+=(-i "$video" -vf "fps=${FPS}" -start_number 1)
  case "$IMAGE_FORMAT" in
    jpg)
      ffmpeg_args+=(-q:v "$JPEG_QUALITY" "$output_pattern")
      ;;
    png)
      ffmpeg_args+=(-compression_level "$PNG_COMPRESSION" "$output_pattern")
      ;;
  esac

  echo
  echo "Extracting ${video} -> ${output_pattern}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    print_command "${ffmpeg_args[@]}"
    continue
  fi

  if [[ "$OVERWRITE" -eq 1 ]]; then
    collect_existing_frames "$cam"
    for old_frame in "${MATCHING_FRAMES[@]-}"; do
      rm -f "$old_frame"
    done
  else
    collect_existing_frames "$cam"
    if [[ "${#MATCHING_FRAMES[@]}" -gt 0 ]]; then
      echo "Output already exists for ${SESSION}/${cam}: ${MATCHING_FRAMES[0]}" >&2
      echo "Use --overwrite to replace matching frames." >&2
      exit 1
    fi
  fi

  ffmpeg "${ffmpeg_args[@]}"
done

echo
echo "Done. Start the annotation service and open http://127.0.0.1:8765"
