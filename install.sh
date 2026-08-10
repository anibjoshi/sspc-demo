#!/usr/bin/env bash
# sspc demo installer — serverless Postgres on your own machine.
# Guided flow: preflight → cluster → images → platform → sample estate →
# agent registration → the estate UI opens. Re-runs are idempotent and fast.
set -euo pipefail
cd "$(dirname "$0")"
YES=${1:-}
T0=$(date +%s)

PINS=(
  "ghcr.io/neondatabase/neon@sha256:7a4f124917bb929964b2d696d710f19584f80bb9bd51b2af4a6e2425434c761f|ghcr.io/neondatabase/neon:latest"
  "ghcr.io/neondatabase/compute-node-v16@sha256:b3e151661bd2ee11eb2843c8926001966cb23969227e9673c5f42fc3fbe14249|ghcr.io/neondatabase/compute-node-v16:latest"
  "postgres@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777|postgres:16-alpine"
  "minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727|minio/mc:latest"
  "quay.io/minio/minio@sha256:df7363871efee5192fb5510ee80e10bb8c5cdc45c9301a825302b1d52c60ba64|quay.io/minio/minio:RELEASE.2022-10-20T00-55-09Z"
  "busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662|busybox:1.36"
)
OPERATOR_TAG=sspc-operator:p1
IMAGE_URL="https://github.com/anibjoshi/sspc-demo/releases/download/m1/operator-image.tar.gz"
MCP_URL=http://localhost:30080/mcp

step() { printf '\033[1;36m[%3dm%02ds] %s\033[0m\n' $((($(date +%s)-T0)/60)) $((($(date +%s)-T0)%60)) "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; PREFLIGHT_FAIL=1; }
die()  { printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
ask()  { # ask "question" varname (default y). Reads /dev/tty so curl|bash works.
  local ans=y
  if [ "$YES" != "--yes" ] && [ -e /dev/tty ]; then
    read -r -p "  $1 [Y/n] " ans < /dev/tty || ans=y
    ans=${ans:-y}
  fi
  eval "$2=\$ans"
}

cat <<'EOF'

  sspc — serverless Postgres on your own machine
  ------------------------------------------------
  This will:
   1. create a local kind cluster (ports bind 127.0.0.1 only)
   2. pull ~2 GB of pinned images (first run only)
   3. install the platform and seed a sample database
   4. register the agent API with Claude Code / IBM Bob
   5. open the estate UI in your browser

  First run ~5 minutes; re-runs are seconds. ./down.sh removes
  everything. Nothing leaves your machine.

EOF

REG_CLAUDE=n; REG_BOB=n
command -v claude >/dev/null && ask "Register with Claude Code when ready?" REG_CLAUDE
[ -d "$HOME/.bob" ] && ask "Register with IBM Bob when ready?" REG_BOB

step "preflight"
PREFLIGHT_FAIL=0
BREW_MISSING=()
for bin in kind kubectl helm jq; do
  command -v "$bin" >/dev/null && ok "$bin" || { bad "$bin missing"; BREW_MISSING+=("$bin"); }
done
command -v curl >/dev/null && ok "curl" || bad "curl missing — install it first"
if command -v docker >/dev/null; then ok "docker"; else
  bad "docker missing — a human choice we won't make for you:"
  echo "      Docker Desktop:  https://www.docker.com/products/docker-desktop"
  echo "      or lightweight:  brew install colima docker && colima start"
fi
if [ ${#BREW_MISSING[@]} -gt 0 ]; then
  if command -v brew >/dev/null; then
    FIX=n; ask "Install missing tools now? (brew install ${BREW_MISSING[*]})" FIX
    if [ "$FIX" = y ] || [ "$FIX" = Y ]; then
      brew install "${BREW_MISSING[@]}"
      PREFLIGHT_FAIL=0
      for bin in "${BREW_MISSING[@]}"; do
        command -v "$bin" >/dev/null && ok "$bin installed" || bad "$bin still missing"
      done
    else
      echo "      install with: brew install ${BREW_MISSING[*]}"
    fi
  else
    echo "      install with your package manager, e.g.: brew install ${BREW_MISSING[*]}"
  fi
fi
if command -v docker >/dev/null && ! docker info >/dev/null 2>&1; then
  STARTED=n
  if command -v colima >/dev/null; then
    ask "Docker daemon not running — start colima now?" S
    if [ "$S" = y ] || [ "$S" = Y ]; then colima start && STARTED=y; fi
  elif [ -d /Applications/Docker.app ]; then
    ask "Docker daemon not running — launch Docker Desktop?" S
    if [ "$S" = y ] || [ "$S" = Y ]; then
      open -a Docker
      printf '  waiting for the daemon'
      for i in $(seq 1 45); do docker info >/dev/null 2>&1 && { STARTED=y; break; }; printf '.'; sleep 2; done
      echo
    fi
  fi
  docker info >/dev/null 2>&1 && ok "docker daemon running"     || bad "docker daemon not running — start Docker/colima and re-run"
elif command -v docker >/dev/null; then
  ok "docker daemon running"
fi
if ! kind get clusters 2>/dev/null | grep -qx sspc; then
  for p in 30080 30001; do
    if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then bad "port $p already in use"; else ok "port $p free"; fi
  done
fi
[ "$PREFLIGHT_FAIL" = 0 ] || die "preflight failed — fix the ✗ items above and re-run"

if ! kind get clusters 2>/dev/null | grep -qx sspc; then
  step "creating kind cluster (loopback-bound port block)"
  kind create cluster --config kind-config.yaml --wait 120s >/dev/null
else
  step "kind cluster exists — reusing"
fi

step "images (pinned digests; cached after first run)"
tags=()
for pin in "${PINS[@]}"; do
  digest="${pin%%|*}"; tag="${pin##*|}"
  docker image inspect "$tag" >/dev/null 2>&1 || { docker pull -q "$digest" >/dev/null; docker tag "$digest" "$tag"; }
  tags+=("$tag")
done
docker image inspect "$OPERATOR_TAG" >/dev/null 2>&1 || {
  step "downloading the sspc operator (~40 MB)"
  t=$(mktemp -d); curl -fsSL "$IMAGE_URL" -o "$t/img.tar.gz"; docker load -qi "$t/img.tar.gz" >/dev/null; rm -rf "$t"
}
if ! docker exec sspc-control-plane crictl images 2>/dev/null | grep -q sspc-operator; then
  step "loading images into the cluster"
  tar=$(mktemp -d)/images.tar
  docker save --platform linux/arm64 -o "$tar" "${tags[@]}" "$OPERATOR_TAG" 2>/dev/null || docker save -o "$tar" "${tags[@]}" "$OPERATOR_TAG"
  kind load image-archive --name sspc "$tar" >/dev/null
  rm -f "$tar"
fi

step "installing the platform"
helm upgrade --install sspc ./chart -n sspc-cell --create-namespace >/dev/null
kubectl -n sspc-cell wait --for=condition=Available deploy --all --timeout=300s >/dev/null
for ss in controller-pg safekeeper pageserver; do
  kubectl -n sspc-cell rollout status "statefulset/$ss" --timeout=300s >/dev/null
done
kubectl -n sspc-cell wait --for=condition=Complete job/minio-create-bucket --timeout=120s >/dev/null 2>&1 || true
ok "platform healthy"

step "seeding the sample estate"
mcp() { curl -sf -X POST -H "Content-Type: application/json" -d "$1" "$MCP_URL"; }
mcp '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_database","arguments":{"name":"sample","suspend_after_seconds":120}}}' >/dev/null
# get_connection wakes it if a prior run left it suspended (idempotent re-runs)
uri=$(mcp '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_connection","arguments":{"name":"sample"}}}' | jq -r '.result.content[0].text' | jq -r '.connection_uri // empty')
[ -n "$uri" ] || die "sample database did not come up — check: kubectl -n sspc-cell logs deploy/sspc-operator"
kubectl -n sspc-cell exec sample -- psql -U cloud_admin -h localhost -p 55433 -d postgres -q -c \
  "create table if not exists visits(id int, note text); insert into visits select g, md5(g::text) from generate_series(1,50000) g where not exists (select 1 from visits limit 1);" >/dev/null
mcp '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_branch","arguments":{"name":"sample-dev","database":"sample"}}}' >/dev/null
ok "sample (50k rows) + branch sample-dev — watch it scale to zero after 2 min idle"

if [ "$REG_CLAUDE" = y ] || [ "$REG_CLAUDE" = Y ]; then
  claude mcp remove -s user sspc >/dev/null 2>&1 || true
  claude mcp add -s user -t http sspc "$MCP_URL" >/dev/null && ok "Claude Code registered"
fi
if [ "$REG_BOB" = y ] || [ "$REG_BOB" = Y ]; then
  BOB_CFGS="$HOME/.bob/mcp.json"
  [ -d "$HOME/.bob/settings" ] && BOB_CFGS="$BOB_CFGS $HOME/.bob/settings/mcp.json"
  for cfg in $BOB_CFGS; do
    [ -f "$cfg" ] || printf '{"mcpServers":{}}\n' > "$cfg"
    tmp=$(mktemp)
    jq --arg url "$MCP_URL" '.mcpServers.sspc = {"type":"streamable-http","url":$url,"alwaysAllow":[],"disabled":false}' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  done
  ok "IBM Bob registered (restart the server from Bob's MCP settings tab)"
fi

{ [ "$YES" != "--yes" ] && command -v open >/dev/null && open "http://localhost:30080/"; } || true
step "done"
cat <<'EOF'

  The estate UI is open at http://localhost:30080 — leave it visible.
  In ~2 minutes you'll watch `sample` suspend to zero pods. Click
  Connect to wake it (~1 s) with all 50k rows intact.

  First five minutes — paste into Claude Code or IBM Bob:
   1. "Create a database called scratch and load some test data with psql."
   2. "Branch sample and drop a column on the branch. Is sample affected?"
   3. "Enroll my existing postgres at postgresql://user:pass@host:5432/db
       and show me the estate."

  Inspect:   kubectl -n sspc-cell get databases,branches,enrolleddatabases
  Teardown:  ./down.sh
EOF
