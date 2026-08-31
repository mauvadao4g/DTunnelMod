#!/usr/bin/env bash
# build-apk.sh - Gera um APK do DTunnel Mod personalizado para um usuario.
# ---------------------------------------------------------------------------
# O app le dois assets para saber a quem/onde se conectar:
#   assets/user_id.txt      -> identificador do usuario logado
#   assets/dtunnelmod.json  -> { "url": "<painel hospedado>", ... }
#
# Este script troca esses dois arquivos dentro do APK base, realinha (zipalign)
# e assina (apksigner, esquemas v2+v3). NAO recompila codigo/recursos, entao
# nao precisa de apktool nem do Android SDK completo.
#
# Uso:
#   ./build-apk.sh --user-id maudavpn --url https://painel.seudominio.com
#
# Opcoes:
#   --user-id <str>     id do usuario         -> assets/user_id.txt        [obrigatorio]
#   --url <url>         URL do painel         -> .url de dtunnelmod.json   [obrigatorio]
#   --base <apk>        APK base                     (default: ./DTMod_4.5.7.apk)
#   --out <apk>         APK de saida                 (default: ./dist/DTMod-<user>.apk)
#   --keystore <jks>    keystore de assinatura       (default: ./keystore/dtmod.jks; criada se faltar)
#   --storepass <str>   senha da keystore            (default: $APK_KEYSTORE_PASS ou "dtunnelmod")
#   --keyalias <str>    alias da chave               (default: dtmod)
#   --json <arquivo>    modelo do dtunnelmod.json    (default: o que ja existe no APK base)
#   --progress-file <a> anexa "<pct>|<etapa>" a cada fase (para uma UI acompanhar)
#   --print-json        ao final imprime {"apk","sha256","size"} em uma linha
#   --quiet             silencia os passos; imprime so o caminho do APK final
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

USER_ID=""
PANEL_URL=""
BASE_APK="${BASE_APK:-$SELF_DIR/DTMod_4.5.7.apk}"
OUT_APK=""
KEYSTORE="${APK_KEYSTORE:-$SELF_DIR/keystore/dtmod.jks}"
STOREPASS="${APK_KEYSTORE_PASS:-dtunnelmod}"
KEYALIAS="${APK_KEY_ALIAS:-dtmod}"
KEYALIAS_EXPLICIT=0
JSON_TEMPLATE=""
PROGRESS_FILE=""
PRINT_JSON=0
QUIET=0

die()  { progress 100 "erro"; printf '\033[0;31m[erro]\033[0m %s\n' "$*" >&2; exit 1; }
log()  { [[ $QUIET -eq 1 ]] || printf '\033[0;36m=>\033[0m %s\n' "$*" >&2; }
progress() { [[ -n "$PROGRESS_FILE" ]] && printf '%s|%s\n' "$1" "$2" >> "$PROGRESS_FILE" 2>/dev/null || true; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user-id)    USER_ID="${2:-}";       shift 2 ;;
    --url)        PANEL_URL="${2:-}";      shift 2 ;;
    --base)       BASE_APK="${2:-}";       shift 2 ;;
    --out)        OUT_APK="${2:-}";        shift 2 ;;
    --keystore)   KEYSTORE="${2:-}";       shift 2 ;;
    --storepass)  STOREPASS="${2:-}";      shift 2 ;;
    --keyalias)   KEYALIAS="${2:-}"; KEYALIAS_EXPLICIT=1; shift 2 ;;
    --json)          JSON_TEMPLATE="${2:-}";  shift 2 ;;
    --progress-file) PROGRESS_FILE="${2:-}"; shift 2 ;;
    --print-json) PRINT_JSON=1;            shift ;;
    --quiet)      QUIET=1;                 shift ;;
    -h|--help)    sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "opcao desconhecida: $1  (use --help)" ;;
  esac
done

# --------------------------------------------------------------- validacoes
[[ -n "$USER_ID" ]]   || die "informe --user-id"
[[ -n "$PANEL_URL" ]] || die "informe --url"
[[ "$PANEL_URL" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]] || die "URL invalida: '$PANEL_URL'"
[[ -f "$BASE_APK" ]]  || die "APK base nao encontrado: $BASE_APK  (coloque o .apk aqui ou passe --base)"

for t in java keytool apksigner zipalign zip unzip; do
  command -v "$t" >/dev/null 2>&1 || die "falta a ferramenta '$t'. Rode:  $SELF_DIR/setup.sh"
done
JSON_ENGINE=""
command -v jq      >/dev/null 2>&1 && JSON_ENGINE="jq"
[[ -z "$JSON_ENGINE" ]] && command -v python3 >/dev/null 2>&1 && JSON_ENGINE="python3"
[[ -n "$JSON_ENGINE" ]] || die "instale 'jq' (ou python3) para editar o dtunnelmod.json"

# id "limpo" so para compor nomes de arquivo
SAFE_ID="$(printf '%s' "$USER_ID" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)"
[[ -n "$OUT_APK" ]] || OUT_APK="$SELF_DIR/dist/DTMod-${SAFE_ID}.apk"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
progress 5 "preparando"

# ------------------------------------------------------- 1. monta os assets
log "usuario : $USER_ID"
log "painel  : $PANEL_URL"
log "base    : $(basename "$BASE_APK")"

mkdir -p "$TMP/assets"
printf '%s' "$USER_ID" > "$TMP/assets/user_id.txt"

if [[ -n "$JSON_TEMPLATE" ]]; then
  [[ -f "$JSON_TEMPLATE" ]] || die "modelo json nao encontrado: $JSON_TEMPLATE"
  cp "$JSON_TEMPLATE" "$TMP/base.json"
elif unzip -p "$BASE_APK" assets/dtunnelmod.json > "$TMP/base.json" 2>/dev/null && [[ -s "$TMP/base.json" ]]; then
  :
elif [[ -f "$SELF_DIR/dtunnelmod.json" ]]; then
  cp "$SELF_DIR/dtunnelmod.json" "$TMP/base.json"
else
  printf '{}\n' > "$TMP/base.json"
fi

if [[ "$JSON_ENGINE" == "jq" ]]; then
  jq --arg u "$PANEL_URL" '.url = $u' "$TMP/base.json" > "$TMP/assets/dtunnelmod.json" \
    || die "dtunnelmod.json base nao e um JSON valido"
else
  URL="$PANEL_URL" python3 - "$TMP/base.json" "$TMP/assets/dtunnelmod.json" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(src))
except Exception as e:
    sys.exit(f"dtunnelmod.json base invalido: {e}")
if not isinstance(data, dict):
    data = {}
data["url"] = os.environ["URL"]
json.dump(data, open(dst, "w"), indent=4, ensure_ascii=False)
open(dst, "a").write("\n")
PY
fi
log "dtunnelmod.json -> url = $PANEL_URL"
progress 22 "montando credenciais"

# ------------------------------------------------------ 2. injeta no APK
WORK="$TMP/work.apk"
cp "$BASE_APK" "$WORK"
progress 40 "empacotando no APK"
( cd "$TMP" && zip -X -q "$WORK" assets/user_id.txt assets/dtunnelmod.json ) \
  || die "falha ao injetar os assets no APK"
# remove eventual assinatura v1 (JAR) - v2/v3 sao refeitas pelo apksigner
zip -q -d "$WORK" 'META-INF/*.RSA' 'META-INF/*.SF' 'META-INF/*.MF' >/dev/null 2>&1 || true

# ------------------------------------------------------ 3. zipalign
progress 60 "alinhando (zipalign)"
ALIGNED="$TMP/aligned.apk"
zipalign -f -p 4 "$WORK" "$ALIGNED" || die "zipalign falhou"
zipalign -c -p 4 "$ALIGNED" >/dev/null 2>&1 || log "aviso: verificacao de alinhamento reportou pendencias"

# ------------------------------------------------------ 4. keystore
if [[ ! -f "$KEYSTORE" ]]; then
  log "keystore nao encontrada -> gerando $KEYSTORE (alias: $KEYALIAS)"
  mkdir -p "$(dirname "$KEYSTORE")"
  keytool -genkeypair -keystore "$KEYSTORE" -alias "$KEYALIAS" -keyalg RSA -keysize 2048 \
    -validity 10000 -storepass "$STOREPASS" -keypass "$STOREPASS" \
    -dname "CN=DTunnel Mod, O=DTunnel, C=BR" >/dev/null 2>&1 \
    || die "nao foi possivel criar a keystore"
  chmod 600 "$KEYSTORE"
  log "GUARDE esta keystore: sem ela os usuarios nao recebem atualizacoes por cima."
elif [[ $KEYALIAS_EXPLICIT -eq 0 ]]; then
  # keystore ja existe e nenhum --keyalias foi dado: usa o 1o alias que ela tiver
  detected="$(LC_ALL=C keytool -list -rfc -keystore "$KEYSTORE" -storepass "$STOREPASS" 2>/dev/null \
              | sed -n 's/^Alias name: //p' | head -n1)"
  [[ -n "$detected" ]] && KEYALIAS="$detected"
fi
log "assinando com alias: $KEYALIAS"

# ------------------------------------------------------ 5. assina
progress 78 "assinando (apksigner)"
mkdir -p "$(dirname "$OUT_APK")"
apksigner sign \
  --ks "$KEYSTORE" --ks-key-alias "$KEYALIAS" \
  --ks-pass "pass:$STOREPASS" --key-pass "pass:$STOREPASS" \
  --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true \
  --out "$OUT_APK" "$ALIGNED" \
  || die "apksigner falhou (confira Java/apksigner com: apksigner version)"

progress 92 "verificando"
apksigner verify "$OUT_APK" >/dev/null 2>&1 || die "o APK assinado nao passou na verificacao"
chmod 644 "$OUT_APK"

SHA="$(sha256sum "$OUT_APK" | cut -d' ' -f1)"
SIZE="$(stat -c%s "$OUT_APK")"
progress 100 "concluido"

if [[ $PRINT_JSON -eq 1 ]]; then
  printf '{"apk":"%s","sha256":"%s","size":%s}\n' "$OUT_APK" "$SHA" "$SIZE"
elif [[ $QUIET -eq 1 ]]; then
  printf '%s\n' "$OUT_APK"
else
  log "APK gerado: $OUT_APK  ($(( SIZE / 1024 / 1024 )) MB)"
  log "sha256    : $SHA"
fi
