#!/usr/bin/env bash
# Download public model weights on the head node.
set -euo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$KIT/../runtime/cluster.env"

fail() { echo "FAIL: $1 — $2" >&2; exit 1; }

# ssh "$CLUSTER_USER@$HEAD_HOST" "HF_CACHE='$HF_CACHE' DSPARK_MODEL='$DSPARK_MODEL' DSPARK_REVISION='${DSPARK_REVISION:-}' bash -s" <<'REMOTE' \
#  || fail "weight download failed on $HEAD_HOST" "rerun; huggingface_hub download is resumable"
# set -euo pipefail

ssh "$CLUSTER_USER@$HEAD_HOST" \
"HTTP_PROXY='${HTTP_PROXY:-}' \
 HTTPS_PROXY='${HTTPS_PROXY:-}' \
 http_proxy='${http_proxy:-}' \
 https_proxy='${https_proxy:-}' \
 HF_CACHE='$HF_CACHE' \
 DSPARK_MODEL='$DSPARK_MODEL' \
 DSPARK_REVISION='${DSPARK_REVISION:-}' \
 bash -s" <<'REMOTE' \
  || fail "weight download failed on $HEAD_HOST" "rerun; huggingface_hub download is resumable"
set -euo pipefail

# let HF use proper proxy
unset ALL_PROXY all_proxy
#env | grep -i proxy

if [ ! -x ~/hf-venv/bin/hf ]; then
  python3 -m venv ~/hf-venv
  ~/hf-venv/bin/pip -q install -U "huggingface_hub[cli]"
fi
echo "ok: hf CLI available"

mkdir -p "$HF_CACHE"
rev_args=()
[ -n "$DSPARK_REVISION" ] && rev_args+=(--revision "$DSPARK_REVISION")

# hf download prints a report containing "path: <resolved snapshot>" on stdout.
# Extract that path so every check below targets THE snapshot this run produced.
snap_path="$(
  HF_HOME="$HF_CACHE" \
  HF_HUB_DISABLE_XET=1 \
  ~/hf-venv/bin/hf download "$DSPARK_MODEL" "${rev_args[@]}" \
  | awk '/snapshots\// {print $NF}' \
  | tail -n1
)"
echo "ok: hf download completed"

model_dir="$HF_CACHE/hub/models--${DSPARK_MODEL//\//--}"
[ -d "$snap_path" ] && [ "$(dirname "$(dirname "$snap_path")")" = "$model_dir" ] \
  || { echo "FAIL: hf download did not report a snapshot dir under $model_dir (got '$snap_path')" >&2; exit 1; }
snap="$(basename "$snap_path")"
# Offline-serving traps (burned 2026-07-31 on the 0731 upgrade): a --revision-pinned
# download creates snapshots/<sha> but NOT refs/main, and vLLM's HF_HUB_OFFLINE=1 startup
# resolves revision "main" via that ref → LocalEntryNotFoundError at boot. And a ref file
# MUST NOT have a trailing newline (41 vs 40 bytes — huggingface_hub 1.24 rejects it).
# Write refs/main UNCONDITIONALLY to this run's snapshot: a stale ref from a previous
# revision would otherwise survive the "flip DSPARK_REVISION and re-run 07/08" workflow
# and silently serve the OLD weights offline.
mkdir -p "$model_dir/refs"; printf '%s' "$snap" > "$model_dir/refs/main"
echo "ok: refs/main -> $snap (offline resolution)"
[ -f "$snap_path/config.json" ] \
  || { echo "FAIL: config.json missing under $snap_path — download is incomplete" >&2; exit 1; }
if find "$model_dir/blobs" -name '*.safetensors.incomplete' -print -quit | grep -q .; then
  echo "FAIL: incomplete safetensors blobs remain — rerun download" >&2
  exit 1
fi
# Shard-level completeness: refs/main + config.json can both be present while an
# individual shard never got linked into the snapshot (an interrupted download that
# left no .incomplete marker). Walk the index's weight_map and assert every shard exists.
index="$snap_path/model.safetensors.index.json"
[ -f "$index" ] || { echo "FAIL: model.safetensors.index.json missing under $snap_path — download is incomplete" >&2; exit 1; }
missing_shards="$(python3 - "$index" <<'PY'
import json, os, sys
index_path = sys.argv[1]
snap_dir = os.path.dirname(index_path)
weight_map = json.load(open(index_path, encoding="utf-8"))["weight_map"]
missing = sorted({shard for shard in weight_map.values()
                  if not os.path.isfile(os.path.join(snap_dir, shard))})
for shard in missing:
    print("missing shard:", shard, file=sys.stderr)
print(len(missing))
PY
)"
echo "missing_shards=$missing_shards"
[ "$missing_shards" = "0" ] || { echo "FAIL: $missing_shards safetensors shards missing from the snapshot — rerun download" >&2; exit 1; }
echo "ok: all safetensors shards present"
du -sh "$model_dir"
echo "ok: weights present"

if [ -f "$HF_CACHE/token" ]; then
  echo "WARN: $HF_CACHE/token exists even though $DSPARK_MODEL is public" >&2
else
  echo "ok: no HF token file"
fi
REMOTE
