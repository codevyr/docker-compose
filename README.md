# Codevyr local compose

Run the Codevyr stack locally with Docker Compose and generate indexes with the helper script.

## Stack layout

- `askld` API on `http://localhost:3002`
- `codevyr` UI on `http://localhost:3000`
- `db` (Postgres) is internal-only

## Quick start (local)

```sh
docker compose -f compose.yaml -f compose.local.yaml up -d
```

The local override enables HTTP tokens and local CORS. It also sets a higher upload limit via `ASKL_MAX_UPLOAD_BYTES`.

## Optional trace volume

If you want to collect traces, add the trace override and set the path:

```sh
ASKL_TRACE_DIR="$HOME/codevyr/trace" \
  docker compose -f compose.yaml -f compose.local.yaml -f compose.trace.yaml up -d
```

## Generate an index

Use the helper script to run the indexer image.

```sh
./bin/generate_index_docker.sh \
  --project kubernetes \
  --path cmd/kubelet \
  ./kubernetes ./index/index-kubernetes.pb \
  --include-git-files
```

Notes:
- `--project` sets the in-container mount point to `/<project>` and is also forwarded to the indexer.
- Indexer args are forwarded as-is; the container runs with the working directory set to the project root, and `--path` values are prefixed with `/<project>` automatically (quote globs like `'cmd/*'`).
- The output index path is the second positional argument; do not pass `--index`.

## Regenerate every index

`scripts/reindex.sh` rebuilds the indexer images, regenerates the indices for the
projects this deployment serves, and replaces them on the local dev stack.

```sh
./scripts/reindex.sh                      # ucx, ompi, rdma-core, open-gpu-kernel-modules
./scripts/reindex.sh --all                # the above plus linux
./scripts/reindex.sh ucx                  # just one
./scripts/reindex.sh --list               # the manifest, with resolved source paths
```

Each project's image is self-contained — it configures the source, builds it and
runs the indexer with that project's own flags — so the script only knows where
the source is and where the image mounts it. Sources default to
`$HOME/src/linux/<project>` (`linux` itself is in `kernel/`); override with
`REINDEX_SRC_ROOT`. Indices land in `../index/<project>/`, which is what
`make load-index` rsyncs to the remote.

Two things worth knowing before the first run:

- **Generation writes into the source tree.** The `linux` image runs
  `make mrproper` before `allmodconfig`, `rdma-core` runs `rm -rf build`, and
  `ucx`/`ompi` run `autogen.sh`. That is those entrypoints' behaviour, and it is
  why `linux` — hours of kernel build — has to be named explicitly rather than
  being part of the default set.
- **Upload purges first.** `askld index upload --force` deletes the project with
  that name and then uploads, so a failed *upload* leaves it absent. A failed
  *generation* uploads nothing, leaving the old index queryable. The summary at
  the end says which happened; retry an upload alone with
  `--skip-build --skip-generate <project>`.

## Ship the indices to production

`make load-index` rsyncs `../index` to `codevyr:~/` and stops there: nothing
on the remote reads it until each project is uploaded into the remote askld.
That is the same two steps `reindex.sh`'s `upload()` runs locally -- copy the
project directory into the askld container, then `askld index upload --force`
-- under the remote docker context:

```sh
cid=$(docker --context codevyr compose -f compose.yaml ps -q askld)
ssh codevyr "docker cp ~/index/<project> $cid:/tmp/"
docker --context codevyr compose -f compose.yaml exec -T askld \
    askld index upload --url https://api.codevyr.com --token "$ASKL_TOKEN" --force /tmp/<project>
```

Two things differ from the dev stack. The copy runs *on* the host over ssh:
`docker --context codevyr cp` would stream the index through the docker API a
second time, after rsync already put it in `~/index`. And the URL is the public
HTTPS one even from inside the container: production does not set
`ASKL_ALLOW_INSECURE_TOKENS`, so a token presented over plain HTTP
(`127.0.0.1:8080`) is answered with `403 API tokens require HTTPS`. nginx in
front of it allows 400 MB per request and 300 s per response; uploads are
chunked well below that, but a single `delete-project` of `linux` is not (see
below). `ASKL_TOKEN` is the production key -- `compose/.env` holds the dev
stack's key too, so take the right line rather than sourcing the file.

Upload `ucx` first as the smoke test and `linux` last; `--force` purges the
project with that name before uploading, exactly as on the dev stack.

**Run the `linux` upload client off the production host.** The client reads
the whole `project.pb` into memory and decodes it -- about 4.2 GB for the
kernel's 1 GB file -- and the 7.7 GB host without swap OOM-kills it (exec
exit 137) after it has created the project and before the first chunk, so the
project is left `[uploading]` and empty. From a machine with memory to spare,
the same image works against the public endpoint (26 min on 2026-10-18):

```sh
docker run --rm --network host -e ASKL_TOKEN="$ASKL_TOKEN" \
    -v "$PWD/../index/linux:/tmp/linux:ro" ghcr.io/codevyr/askld:<tag> \
    index upload --url https://api.codevyr.com --timeout 0 --window 4 --force /tmp/linux
```

The six smaller projects (up to kubernetes' 294 MB) fit on the host.

**Order matters when the engine changes too.** The new askld runs its schema
migrations at boot over whatever rows exist, and an index produced for an
older engine cannot be served by a newer one anyway -- so when a release brings
both a new engine and regenerated indices, **delete every project before
`make deploy-remote`**:

```sh
for p in ucx ompi rdma-core open-gpu-kernel-modules kueue kubernetes linux; do
  docker --context codevyr compose -f compose.yaml exec -T askld \
      askld index delete-project --name "$p" --url https://api.codevyr.com --token "$ASKL_TOKEN"
done
```

The migrations then run over empty tables and boot is instant; there is no
window in which the new engine serves the old indices wrongly; and nothing is
migrated only to be replaced minutes later. Do it after the tag is bumped and
immediately before the deploy -- in between, production serves nothing.

Deleting `linux` (5.3 M symbols, 13 M instances, 20 M references) outlasts
nginx's 300 s: the CLI prints `504 Gateway Time-out` while the server keeps
going. Treat that as "still running", not "failed": the project shows as
`linux [deleting]` in `list-projects`, postgres sits near 100 % CPU, and
`docker --context codevyr compose -f compose.yaml logs askld` ends with
`delete_project: complete project_id=…` when it is done (31 minutes on the
2026-10-18 release, 29 of them in `DELETE FROM index.symbols`). Deploy only
after that line.

The script warns when the running `askld` container predates `askl`'s HEAD,
because that server validates the upload and answers every query against it.
Refresh it with:

```sh
( cd ../askl       && docker build -t askld -f docker/askld/Dockerfile . )
( cd ../askl-react && docker build --pull=false -t codevyr . )
make deploy-dev
```

## Files

- `compose.yaml`: base stack
- `compose.local.yaml`: local-only settings (HTTP tokens, local CORS, upload limit)
- `compose.trace.yaml`: optional trace volume mount
- `bin/generate_index_docker.sh`: Go indexer helper (read-only mount, explicit
  output file — a different job from the self-building C images)
- `scripts/reindex.sh`: regenerate and re-upload every index
