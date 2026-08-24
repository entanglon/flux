#!/bin/zsh
# Bundles the hydra torrent/stream server into a Flux.app bundle so the app is
# self-contained (no external checkout / nvm / tsx needed at runtime).
#
# Usage:
#   scripts/bundle_hydra.sh [path/to/Flux.app]
#
# If no app path is given, installs into the Debug build product in DerivedData.
#
# Layout created inside the app:
#   Contents/Resources/hydra-server/
#     node              (bundled node runtime from hydra's node_bin)
#     dist/index.js     (compiled server)
#     node_modules/     (production dependencies only)
#     .env              (server configuration)
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Hydra is vendored inside this repo (hydra/). Override with HYDRA_SRC=/path if needed.
HYDRA_SRC="${HYDRA_SRC:-$SCRIPT_DIR/../hydra}"
APP_PATH="${1:-DerivedData/Build/Products/Debug/flux.app}"

if [[ ! -d "$HYDRA_SRC" ]]; then
  echo "error: hydra source not found at $HYDRA_SRC"
  exit 1
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found at $APP_PATH"
  exit 1
fi

DEST="$APP_PATH/Contents/Resources/hydra-server"

echo "==> Cleaning $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"

echo "==> Compiling hydra with esbuild"
(cd "$HYDRA_SRC" && ./node_modules/.bin/esbuild src/index.ts --bundle --platform=node --target=node22 --outfile=dist/index.js --packages=external)
if [[ ! -f "$HYDRA_SRC/dist/index.js" ]]; then
  echo "error: hydra compilation produced no dist/index.js"
  exit 1
fi

echo "==> Installing production dependencies into staging"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/hydra-bundle.XXXXXX")
trap "rm -rf $STAGE" EXIT
cp "$HYDRA_SRC/package.json" "$STAGE/"
cp "$HYDRA_SRC/package-lock.json" "$STAGE/" 2>/dev/null || true
(cd "$STAGE" && npm install --omit=dev --no-audit --no-fund --loglevel=error)

echo "==> Assembling bundle"
cp -R "$HYDRA_SRC/dist" "$DEST/dist"
cp -R "$STAGE/node_modules" "$DEST/node_modules"
cp "$HYDRA_SRC/.env" "$DEST/.env"
# Embed a node runtime so the app is self-contained on machines without node.
# Prefer the repo's node_bin if present; otherwise use the build machine's node.
NODE_SRC="$HYDRA_SRC/node_bin"
if [[ ! -f "$NODE_SRC" ]]; then
  NODE_SRC="$(command -v node)"
fi
if [[ -n "$NODE_SRC" && -f "$NODE_SRC" ]]; then
  cp "$NODE_SRC" "$DEST/node"
  chmod +x "$DEST/node"
else
  echo "warning: no node runtime found; app will require system node at runtime"
fi

SIZE=$(du -sh "$DEST" | cut -f1)
echo "==> Done. hydra-server bundled ($SIZE) into:"
echo "    $DEST"
