#!/usr/bin/env bash
# Gera o bundle de release do app Linux, monta o Flatpak e instala para o usuário atual.
# Não usa sudo: o Flatpak fica em ~/.local/share/flatpak.
#
# Uso: scripts/flatpak/instalar-local.sh [--sem-build-flutter]
#   --sem-build-flutter  usa o bundle de release que já existe, sem recompilar o Flutter.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_ID=io.github.eduardo_lima_dev.ConectDroidCam
MANIFESTO="$RAIZ/flatpak/$APP_ID.yml"
BUILD="$RAIZ/dist/flatpak-build"
REPO="$RAIZ/dist/flatpak-repo"

if [[ "${1:-}" != "--sem-build-flutter" ]]; then
  (cd "$RAIZ/apps/conectdroidcam" && flutter build linux --release)
fi

if ! flatpak info --user org.gnome.Platform//51 >/dev/null 2>&1 \
  || ! flatpak info --user org.gnome.Sdk//51 >/dev/null 2>&1; then
  echo "Falta o runtime: flatpak install --user flathub org.gnome.Platform//51 org.gnome.Sdk//51" >&2
  exit 1
fi

# O flatpak-builder roda pelo próprio Flatpak (org.flatpak.Builder), sem instalar nada no sistema.
flatpak run org.flatpak.Builder \
  --user --install --force-clean --disable-rofiles-fuse \
  --state-dir="$RAIZ/dist/flatpak-state" \
  --repo="$REPO" \
  "$BUILD" "$MANIFESTO"

echo
echo "Instalado. Para abrir: flatpak run $APP_ID  (ou pelo menu de aplicativos)"
