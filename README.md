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

## Files

- `compose.yaml`: base stack
- `compose.local.yaml`: local-only settings (HTTP tokens, local CORS, upload limit)
- `compose.trace.yaml`: optional trace volume mount
- `bin/generate_index_docker.sh`: indexer helper script
