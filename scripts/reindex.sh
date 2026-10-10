#!/usr/bin/env bash
#
# Regenerate the indices this deployment serves and upload them to the local dev
# stack, replacing what is there.
#
# Each project's indexer image is self-contained: it configures the source,
# builds it, and runs askl-clang-indexer with that project's own flags.  So this
# script only has to know where the source lives and where the image expects it
# mounted -- not how any project builds.
#
# NOTE: generation WRITES INTO THE SOURCE TREE.  The linux image runs
# `make mrproper` before `allmodconfig`; rdma-core runs `rm -rf build`; ucx and
# ompi run `autogen.sh`.  That is those entrypoints' existing behaviour, and it
# is why `linux` needs naming explicitly.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose_dir="$(dirname "$here")"
ask_root="$(dirname "$compose_dir")"

indexer_repo="${REINDEX_INDEXER_REPO:-$ask_root/askl-clang-indexer}"
index_root="${REINDEX_INDEX_ROOT:-$ask_root/index}"
src_root="${REINDEX_SRC_ROOT:-$HOME/src/linux}"
askld_url="${REINDEX_ASKLD_URL:-127.0.0.1:8080}"

compose=(docker compose -f "$compose_dir/compose.yaml" -f "$compose_dir/compose.dev.yaml")

# The manifest: project, source directory under $src_root, and the path the
# image mounts it at (its Dockerfile's WORKDIR).  `linux` lives in `kernel`, so
# the mapping is not mechanical.
#
# docker/hip and docker/rocr exist in the indexer repo but are not in the
# deployment; indexing them here would create projects it does not have.
manifest_src() {
    case "$1" in
    ucx) echo "$src_root/ucx" ;;
    ompi) echo "$src_root/ompi" ;;
    rdma-core) echo "$src_root/rdma-core" ;;
    open-gpu-kernel-modules) echo "$src_root/open-gpu-kernel-modules" ;;
    linux) echo "$src_root/kernel" ;;
    *) return 1 ;;
    esac
}

manifest_mount() {
    case "$1" in
    ucx) echo "/ucx" ;;
    ompi) echo "/ompi" ;;
    rdma-core) echo "/rdma-core" ;;
    open-gpu-kernel-modules) echo "/open-gpu-kernel-modules" ;;
    linux) echo "/linux" ;;
    *) return 1 ;;
    esac
}

# Everything except linux, which is a multi-hour kernel build that wipes its
# source tree -- it takes --all or its own name.
default_projects=(ucx ompi rdma-core open-gpu-kernel-modules)
all_projects=(ucx ompi rdma-core open-gpu-kernel-modules linux)

do_build=1
do_generate=1
do_upload=1
want_all=0
projects=()

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options] [project...]

  no arguments   ${default_projects[*]}
  --all          the above plus linux
  <project>...   exactly those; linux is allowed when named

Options:
  --skip-build      reuse the indexer images that are already built
  --skip-generate   upload what is already in $index_root/<project>/
  --skip-upload     generate only
  --list            print the manifest and exit
  -h, --help        this

Known projects: ${all_projects[*]}

Environment:
  REINDEX_SRC_ROOT        where the sources live (default: \$HOME/src/linux)
  REINDEX_INDEX_ROOT      where indices are written (default: <workspace>/index)
  REINDEX_INDEXER_REPO    the askl-clang-indexer checkout
  REINDEX_ASKLD_URL       askld's address INSIDE its container (default: $askld_url)
USAGE
}

list_manifest() {
    printf '%-26s %-10s %-44s %s\n' PROJECT DEFAULT SOURCE MOUNT
    for p in "${all_projects[@]}"; do
        local in_default=no
        for d in "${default_projects[@]}"; do
            [[ "$d" == "$p" ]] && in_default=yes
        done
        local src
        src="$(manifest_src "$p")"
        local mark=""
        [[ -d "$src" ]] || mark=" (MISSING)"
        printf '%-26s %-10s %-44s %s\n' "$p" "$in_default" "$src$mark" "$(manifest_mount "$p")"
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --all) want_all=1; shift ;;
    --skip-build) do_build=0; shift ;;
    --skip-generate) do_generate=0; shift ;;
    --skip-upload) do_upload=0; shift ;;
    --list) list_manifest; exit 0 ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) projects+=("$1"); shift ;;
    esac
done
projects+=("$@")

if [[ ${#projects[@]} -eq 0 ]]; then
    if [[ $want_all -eq 1 ]]; then
        projects=("${all_projects[@]}")
    else
        projects=("${default_projects[@]}")
    fi
elif [[ $want_all -eq 1 ]]; then
    echo "error: --all takes no project arguments" >&2
    exit 1
fi

die() {
    echo "error: $*" >&2
    exit 1
}

# --- preflight -------------------------------------------------------------
# Every check that can be done before the first multi-minute build is done here,
# so a typo in a project name does not surface an hour in.

for p in "${projects[@]}"; do
    manifest_src "$p" >/dev/null 2>&1 \
        || die "unknown project: $p (known: ${all_projects[*]})"
done

if [[ $do_generate -eq 1 ]]; then
    [[ -d "$indexer_repo/docker" ]] \
        || die "no indexer repo at $indexer_repo (set REINDEX_INDEXER_REPO)"
    for p in "${projects[@]}"; do
        src="$(manifest_src "$p")"
        [[ -d "$src" ]] || die "source for $p is missing: $src (set REINDEX_SRC_ROOT)"
        [[ -d "$indexer_repo/docker/$p" ]] \
            || die "no image definition at $indexer_repo/docker/$p"
    done
fi

askld_cid=""
if [[ $do_upload -eq 1 ]]; then
    askld_cid="$("${compose[@]}" ps -q askld 2>/dev/null || true)"
    [[ -n "$askld_cid" ]] \
        || die "the dev stack is not running; start it with 'make deploy-dev' in $compose_dir"

    if [[ -z "${ASKL_TOKEN:-}" && -f "$compose_dir/.env" ]]; then
        set -a
        # shellcheck disable=SC1091
        . "$compose_dir/.env"
        set +a
    fi
    [[ -n "${ASKL_TOKEN:-}" ]] \
        || die "ASKL_TOKEN is not set and $compose_dir/.env did not provide it"

    # The index this uploads into must be read by an askld that understands it.
    # The containment tree is recent; an older server has neither the upload
    # validator nor the queries that read the DFS interval, so a reindex into it
    # verifies nothing.
    #
    # The RUNNING CONTAINER's creation time, not the image's: askld:latest is
    # built reproducibly, so its own Created is a fixed 1980 epoch and says
    # nothing.  The container's is real, and it is also the better question --
    # what is serving, rather than what is on disk.
    if [[ -d "$ask_root/askl/.git" ]]; then
        started="$(docker inspect "$askld_cid" --format '{{.Created}}' 2>/dev/null || true)"
        started_at="$([[ -n "$started" ]] && date -d "$started" +%s 2>/dev/null || true)"
        head_at="$(git -C "$ask_root/askl" log -1 --format=%ct 2>/dev/null || true)"
        if [[ -n "$started_at" && -n "$head_at" && "$started_at" -lt "$head_at" ]]; then
            cat >&2 <<STALE
warning: the running askld started $(date -d "@$started_at" '+%Y-%m-%d %H:%M'), before askl's HEAD
         ($(date -d "@$head_at" '+%Y-%m-%d %H:%M')).  It will validate this upload and answer every
         query against it, so a reindex into it verifies the OLD engine.  To
         refresh:
           ( cd $ask_root/askl       && docker build -t askld -f docker/askld/Dockerfile . )
           ( cd $ask_root/askl-react && docker build --pull=false -t codevyr . )
           ( cd $compose_dir         && make deploy-dev )
STALE
        fi
    fi
fi

if [[ $do_generate -eq 1 ]]; then
    for p in "${projects[@]}"; do
        if [[ "$p" == "linux" ]]; then
            cat >&2 <<WARN
note: generating 'linux' runs 'make mrproper' then a full allmodconfig build in
      $(manifest_src linux) -- hours, and it discards whatever is built there now.
WARN
        fi
    done
fi

# --- phases ----------------------------------------------------------------

base_built=0
build_images() {
    local p="$1"
    if [[ $base_built -eq 0 ]]; then
        # The base first: every docker/<p>/Dockerfile opens with
        # ARG BASE_IMAGE=askl-clang-indexer:latest, and its build context is
        # docker/<p>/ alone, so the base cannot come from there.
        #
        # FAIL HARD if it does not build.  This used to set base_built=1
        # unconditionally and return the status of the per-project build
        # below, which succeeds against the base image still tagged from a
        # previous run -- so a base that failed to compile produced indices
        # from whatever binary that image held, and the script reported
        # success.  It happened: a CMakeLists change broke the build and ucx
        # was regenerated by a week-old producer, surfacing only as an upload
        # rejection naming an unrelated-looking invariant.
        echo ":: building askl-clang-indexer:latest"
        if ! ( cd "$indexer_repo" \
                && docker build -t askl-clang-indexer:latest -f docker/Dockerfile . ); then
            echo "!! base image build FAILED -- refusing to index with the previously" >&2
            echo "!! tagged askl-clang-indexer:latest, which is older code." >&2
            return 1
        fi
        base_built=1
    fi
    echo ":: building askl-clang-indexer-$p:latest"
    ( cd "$indexer_repo" \
        && docker build -t "askl-clang-indexer-$p:latest" "docker/$p/" )
}

generate() {
    local p="$1" src mount out
    src="$(manifest_src "$p")"
    mount="$(manifest_mount "$p")"
    out="$index_root/$p"
    mkdir -p "$out"
    echo ":: generating $p from $src into $out"
    # Writable on purpose: the entrypoints build the project in place.  The
    # indexer clears stale contents-*.pb from the output itself, so a rerun does
    # not accumulate fragments.
    docker run --rm \
        -v "$src:$mount" \
        -v "$out:/out" \
        "askl-clang-indexer-$p:latest"
}

upload() {
    local p="$1" out="$index_root/$p"
    [[ -f "$out/project.pb" ]] || die "nothing to upload: $out/project.pb is missing"
    echo ":: staging $p ($(du -sh "$out" | cut -f1)) into the askld container"
    "${compose[@]}" exec -T askld rm -rf "/tmp/$p"
    docker cp "$out" "$askld_cid:/tmp/"
    echo ":: uploading $p (--force replaces the existing project)"
    # --force deletes the project with this name BEFORE uploading, which is the
    # purge.  It also means a failed upload leaves the project absent rather
    # than stale -- hence the summary below.
    #
    # Capture the status, THEN clean up, THEN return it.  Letting the cleanup
    # run last would hand its own exit status back as the function's: errexit
    # does not fire inside a function the caller is testing with `if !`, so a
    # failed upload followed by a successful `rm` reported success.  It did,
    # once -- a 401 on the delete came out as "ok" in the summary.
    local status=0
    "${compose[@]}" exec -T askld \
        askld index upload --url "$askld_url" --token "$ASKL_TOKEN" --force "/tmp/$p" \
        || status=$?
    "${compose[@]}" exec -T askld rm -rf "/tmp/$p" || true
    return $status
}

secs() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

results=()
overall=0
for p in "${projects[@]}"; do
    started=$SECONDS
    state="ok"

    if [[ $do_build -eq 1 ]]; then
        if ! build_images "$p"; then
            results+=("$(printf '%-26s build FAILED        %s' "$p" "$(secs $((SECONDS - started)))")")
            overall=1
            continue
        fi
    fi

    if [[ $do_generate -eq 1 ]]; then
        if ! generate "$p"; then
            # Nothing was purged, so the old index is still queryable.
            results+=("$(printf '%-26s generate FAILED     %s  (server untouched)' "$p" "$(secs $((SECONDS - started)))")")
            overall=1
            continue
        fi
    fi

    if [[ $do_upload -eq 1 ]]; then
        if ! upload "$p"; then
            results+=("$(printf '%-26s UPLOAD FAILED       %s  (project PURGED, retry with --skip-build --skip-generate %s)' "$p" "$(secs $((SECONDS - started)))" "$p")")
            overall=1
            continue
        fi
    else
        state="generated, not uploaded"
    fi

    size="$(du -sh "$index_root/$p" 2>/dev/null | cut -f1 || echo '-')"
    results+=("$(printf '%-26s %-20s %s  %s' "$p" "$state" "$(secs $((SECONDS - started)))" "$size")")
done

echo
echo "=== summary ==="
for r in "${results[@]}"; do echo "  $r"; done

if [[ $do_upload -eq 1 ]]; then
    echo
    echo "=== projects on the dev server ==="
    "${compose[@]}" exec -T askld \
        askld index list-projects --url "$askld_url" --token "$ASKL_TOKEN" || true
fi

exit $overall
