#!/usr/bin/env bash

set -euo pipefail

image="${IMAGE:-askl-golang-indexer:latest}"

usage() {
  echo "Usage: $0 [--image IMAGE] <source-dir> <output-index-file> [indexer-args...]" >&2
  echo "Example: $0 --image askl-golang-indexer:latest ./repo ./out/index.pb --include-git-files" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image|-i)
      image="${2:-}"
      if [[ -z "$image" ]]; then
        echo "error: --image requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unrecognized option: $1" >&2
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

src_dir="${1:-}"
out_file="${2:-}"
if [[ -z "$src_dir" || -z "$out_file" ]]; then
  usage
  exit 1
fi
shift 2

if [[ ! -d "$src_dir" ]]; then
  echo "error: source directory does not exist or is not a directory: $src_dir" >&2
  exit 1
fi

if [[ -d "$out_file" ]]; then
  echo "error: output index must be a file path, not a directory: $out_file" >&2
  exit 1
fi

out_dir="$(dirname "$out_file")"
out_base="$(basename "$out_file")"
mkdir -p "$out_dir"

src_dir_abs="$(cd "$src_dir" && pwd)"
out_dir_abs="$(cd "$out_dir" && pwd)"

index_arg_present=0
path_arg_present=0
for arg in "$@"; do
  case "$arg" in
    --index|--index=*)
      index_arg_present=1
      ;;
    --path|--path=*)
      path_arg_present=1
      ;;
  esac
done

if [[ $index_arg_present -eq 1 ]]; then
  echo "error: omit --index; pass the output file as the second argument instead" >&2
  exit 1
fi

extra_args=("$@")
if [[ $path_arg_present -eq 0 ]]; then
  extra_args+=(--path /workspace)
fi
extra_args+=(--index "/out/${out_base}")

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${src_dir_abs}:/workspace:ro" \
  -v "${out_dir_abs}:/out" \
  -e "CGO_ENABLED=0" \
  "${image}" \
  "${extra_args[@]}"
