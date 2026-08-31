#!/usr/bin/env bash
# setup.sh - Instala as dependencias para gerar o APK (Debian/Ubuntu).
# ---------------------------------------------------------------------------
#   default-jdk-headless  -> java + keytool (runtime do apksigner, criacao da keystore)
#   apksigner             -> assinatura v1/v2/v3
#   zipalign             -> alinhamento do zip do APK
#   zip / unzip          -> troca dos assets dentro do APK
#   jq                   -> edicao do assets/dtunnelmod.json
#
# Uso:  ./setup.sh          (pede sudo sozinho se necessario)
# ---------------------------------------------------------------------------
set -Eeuo pipefail

PKGS=(default-jdk-headless apksigner zipalign zip unzip jq)

if [[ "$(id -u)" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { echo "rode como root ou instale o sudo." >&2; exit 1; }
  exec sudo -E bash "$0" "$@"
fi

command -v apt-get >/dev/null 2>&1 || {
  echo "este setup automatico so cobre Debian/Ubuntu (apt)." >&2
  echo "instale manualmente: JDK, apksigner e zipalign (Android build-tools), zip, unzip, jq." >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
echo "=> apt-get update"
apt-get update -y

echo "=> instalando: ${PKGS[*]}"
if ! apt-get install -y --no-install-recommends "${PKGS[@]}"; then
  echo "=> habilitando o repositorio 'universe' e tentando de novo"
  apt-get install -y --no-install-recommends software-properties-common
  add-apt-repository -y universe
  apt-get update -y
  apt-get install -y --no-install-recommends "${PKGS[@]}"
fi

echo
FALTOU=0
for t in java keytool apksigner zipalign zip unzip jq; do
  if command -v "$t" >/dev/null 2>&1; then
    printf '  [ok]  %s\n' "$t"
  else
    printf '  [--]  %s  (FALTANDO)\n' "$t"; FALTOU=1
  fi
done
[[ $FALTOU -eq 0 ]] || { echo; echo "alguma ferramenta nao ficou disponivel no PATH." >&2; exit 1; }

echo
echo "toolchain pronto:"
echo "  java     : $(java -version 2>&1 | head -n1)"
echo "  apksigner: $(apksigner version 2>/dev/null || echo '?')"
echo "  zipalign : $(zipalign 2>&1 | head -n1)"
echo
echo "agora gere um APK:  ./build-apk.sh --user-id <id> --url https://painel.seudominio.com"
