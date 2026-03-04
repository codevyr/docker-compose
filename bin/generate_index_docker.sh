#!/usr/bin/env bash

set -euo pipefail

image="${IMAGE:-ghcr.io/codevyr/askl-golang-indexer:latest}"
project_name="project"
src_path_rel="."

usage() {
  echo "Usage: $0 [--image IMAGE] [--project NAME] [--src-path REL] <source-dir> <output-index-file> [indexer-args...]" >&2
  echo "  --src-path REL   Relative path inside /<project> where indexing starts (default: .)" >&2
  echo "Example: $0 --image askl-golang-indexer:latest --project kubernetes --src-path cmd/kubelet ./repo ./out/index.pb --include-git-files" >&2
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
    --project)
      project_name="${2:-}"
      if [[ -z "$project_name" ]]; then
        echo "error: --project requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --project=*)
      project_name="${1#*=}"
      if [[ -z "$project_name" ]]; then
        echo "error: --project requires a value" >&2
        exit 1
      fi
      shift 1
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
project_arg_present=0
extra_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --index|--index=*)
      index_arg_present=1
      shift 1
      ;;
    --src-path)
      src_path_rel="${2:-}"
      if [[ -z "$src_path_rel" ]]; then
        echo "error: --src-path requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --src-path=*)
      src_path_rel="${1#*=}"
      if [[ -z "$src_path_rel" ]]; then
        echo "error: --src-path requires a value" >&2
        exit 1
      fi
      shift 1
      ;;
    --project)
      project_arg_present=1
      project_name="${2:-}"
      if [[ -z "$project_name" ]]; then
        echo "error: --project requires a value" >&2
        exit 1
      fi
      extra_args+=("$1" "$2")
      shift 2
      ;;
    --project=*)
      project_arg_present=1
      project_name="${1#*=}"
      if [[ -z "$project_name" ]]; then
        echo "error: --project requires a value" >&2
        exit 1
      fi
      extra_args+=("$1")
      shift 1
      ;;
    *)
      extra_args+=("$1")
      shift 1
      ;;
  esac
done

if [[ $index_arg_present -eq 1 ]]; then
  echo "error: omit --index; pass the output file as the second argument instead" >&2
  exit 1
fi

if [[ "${src_path_rel}" = /* ]]; then
  echo "error: --src-path must be a relative path (got ${src_path_rel})" >&2
  exit 1
fi

src_path_rel="${src_path_rel#./}"
if [[ -z "$src_path_rel" || "$src_path_rel" == "." ]]; then
  src_path_rel=""
fi

index_root="/${project_name}"
if [[ -n "$src_path_rel" ]]; then
  index_root="${index_root}/${src_path_rel}"
fi

extra_args+=(--path "${index_root}")
if [[ $project_arg_present -eq 0 ]]; then
  extra_args+=(--project "${project_name}")
fi
extra_args+=(--index "/out/${out_base}")

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${src_dir_abs}:/${project_name}:ro" \
  -v "${out_dir_abs}:/out" \
  -e "CGO_ENABLED=0" \
  "${image}" \
  "${extra_args[@]}"
