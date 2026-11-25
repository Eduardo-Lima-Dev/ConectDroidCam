#!/usr/bin/env bash
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_ID="io.github.eduardo_lima_dev.ConectDroidCam"
TEMPLATE="$RAIZ/flatpak/flathub/flatpak-flutter.yml"
SAIDA="$RAIZ/dist/flathub-pr"
TOOLS="$RAIZ/dist/tools/flatpak-flutter"
BUILD_DIR="$RAIZ/dist/flathub-build"
REPO_DIR="$RAIZ/dist/flathub-repo"
STATE_DIR="$RAIZ/dist/flathub-state"

TAG="v0.1.0"
COMMIT=""
SEM_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:?faltou o valor de --tag}"
      shift 2
      ;;
    --commit)
      COMMIT="${2:?faltou o valor de --commit}"
      shift 2
      ;;
    --sem-build)
      SEM_BUILD=1
      shift
      ;;
    *)
      echo "Uso: $0 [--tag v0.1.0] [--commit <sha>] [--sem-build]" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$COMMIT" ]]; then
  if git -C "$RAIZ" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
    COMMIT="$(git -C "$RAIZ" rev-list -n 1 "$TAG")"
  else
    COMMIT="$(git -C "$RAIZ" rev-parse HEAD)"
    echo "Aviso: tag '${TAG}' ainda não existe localmente; usando HEAD (${COMMIT})." >&2
  fi
fi

for cmd in git python3 flatpak; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Falta a ferramenta: $cmd" >&2
    exit 1
  fi
done

if ! flatpak info --user org.flatpak.Builder >/dev/null 2>&1 \
  && ! flatpak info org.flatpak.Builder >/dev/null 2>&1; then
  echo "Falta org.flatpak.Builder: flatpak install --user flathub org.flatpak.Builder" >&2
  exit 1
fi

if [[ ! -d "$TOOLS/.git" ]]; then
  mkdir -p "$(dirname "$TOOLS")"
  git clone --depth 1 https://github.com/TheAppgineer/flatpak-flutter.git "$TOOLS"
else
  git -C "$TOOLS" pull --ff-only
fi

rm -rf "$SAIDA"
mkdir -p "$SAIDA"

sed -e "s/__TAG__/${TAG}/g" -e "s/__COMMIT__/${COMMIT}/g" \
  "$TEMPLATE" > "$SAIDA/flatpak-flutter.yml"

echo "== Gerando manifesto e fontes offline para ${TAG} (${COMMIT}) =="
(
  cd "$SAIDA"
  python3 "$TOOLS/flatpak-flutter.py" \
    --app-module conectdroidcam \
    --app-pubspec "$RAIZ/apps/conectdroidcam/pubspec.yaml" \
    --cargo-locks "$RAIZ/rust/Cargo.lock" \
    flatpak-flutter.yml
)

rm -f "$SAIDA/flatpak-flutter.yml"

if [[ ! -f "$SAIDA/${APP_ID}.yml" ]]; then
  echo "Erro: ${APP_ID}.yml não foi gerado em ${SAIDA}" >&2
  exit 1
fi

echo "== Validando AppStream e manifesto com flatpak-builder-lint =="
flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
  appstream "$RAIZ/flatpak/${APP_ID}.metainfo.xml"
flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
  manifest "$SAIDA/${APP_ID}.yml"

if [[ "$SEM_BUILD" -eq 0 ]]; then
  echo "== Compilando no sandbox offline e validando repositório =="
  flatpak run org.flatpak.Builder \
    --user --force-clean --disable-rofiles-fuse \
    --install-deps-from=flathub \
    --state-dir="$STATE_DIR" \
    --repo="$REPO_DIR" \
    "$BUILD_DIR" "$SAIDA/${APP_ID}.yml"

  flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
    repo "$REPO_DIR"
fi

echo
echo "Arquivos prontos para o PR no Flathub em: $SAIDA"
ls -la "$SAIDA"
