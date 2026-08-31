#!/usr/bin/env bash
# VER: 1.0.2
# install.sh - Instalador multi-versao do Painel DTunnel
# ------------------------------------------------------
# - Lista os *.zip do diretorio (cada zip = uma versao) e deixa voce escolher.
# - Pergunta o subdominio e a porta interna do painel.
# - Instala Node.js, Nginx, SQLite, Certbot e dependencias.
# - Extrai o painel, gera o .env com segredos, roda as migrations do Prisma,
#   compila o projeto e sobe um servico systemd dedicado.
# - Configura o proxy reverso no Nginx e emite o certificado HTTPS (Let's Encrypt).
# - Permite varios paineis no mesmo servidor (um por subdominio/porta).
#
# Uso (na VPS):
#   cd /root/DTUNEL
#   chmod +x install.sh
#   ./install.sh
#
# Modo nao-interativo (opcional), via variaveis de ambiente:
#   ZIP=DTunnel-dtunnelmod-v16.zip DOMAIN=painel.seudominio.com PORT=3000 \
#   ADMIN_EMAIL=voce@dominio.com ADMIN_PASSWORD='SenhaForte123!' \
#   CERT_EMAIL=voce@dominio.com SKIP_DNS_CHECK=0 ASSUME_YES=1 ./install.sh
#
# Modo REMOTO (roda no SEU PC): envia o dtMod.zip + este script para a VPS e
# instala la dentro de uma sessao 'screen' (nao para se a conexao SSH cair):
#   ./install.sh --remote
# Pergunta dominio/porta/e-mail/senha UMA vez aqui; o resto e automatico.
# Ajustes por env: REMOTE_HOST REMOTE_USER REMOTE_PORT REMOTE_KEY REMOTE_DIR
#                  SESSION ZIP_FILE NO_ATTACH=1  (e DOMAIN/PORT/... p/ pular perguntas)
#
# Modulos de APK (automaticos se apk-generator/ + um .apk em app_base/ existirem):
#   - botao "GERAR APK" no painel (rota /application/apk)
#   - micro-servico de build para sites externos (dtmod.site): servico systemd
#     'apkbuild' em 127.0.0.1:8099, exposto pelo Nginx em /apkbuild/generate.
#     APK_BASE_APK=/caminho/base.apk   escolhe o APK base (default: app_base/DTMod_4.5.7.apk)
#     APKBUILD_KEY=<hex>               chave compartilhada com o site (default: gerada / preservada)
#
set -Eeuo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------ constantes
APP_ROOT="/opt/dtunnel"          # cada painel fica em /opt/dtunnel/<slug>
CONF_DIR="/etc/dtunnel"          # metadados por painel
HELPER="/usr/local/bin/dtunnel"  # comando de gerenciamento
NODE_MAJOR="22"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --------------------------------------------------------------------- cores/log
if [[ -t 1 ]]; then
  R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; CYA=$'\033[0;36m'; BLU=$'\033[0;34m'
else
  R=''; B=''; DIM=''; RED=''; GRN=''; YEL=''; CYA=''; BLU=''
fi
erro()  { printf '%b\n' "${RED}${B}[erro]${R} $*" >&2; exit 1; }
info()  { printf '%b\n' "${CYA}=>${R} $*"; }
ok()    { printf '%b\n' "${GRN}[ok]${R} $*"; }
aviso() { printf '%b\n' "${YEL}[aviso]${R} $*"; }
secao() { printf '\n%b\n' "${BLU}${B}== $* ==${R}"; }
trap 'erro "falha na linha $LINENO. Reveja a mensagem acima."' ERR

ASSUME_YES="${ASSUME_YES:-0}"
# confirmar "mensagem"  -> 0 se aceitar (SIM), 1 se recusar; ASSUME_YES=1 aceita sempre
confirmar() {
  local resp
  if [[ "$ASSUME_YES" == "1" ]]; then
    info "$1 ${DIM}-> SIM (automatico)${R}"
    return 0
  fi
  read -r -p "${YEL}$1 [digite SIM]: ${R}" resp
  [[ "$resp" =~ ^[Ss][Ii][Mm]$ ]]
}

# ================================================================= MODO REMOTO
# ./install.sh --remote   (ou:  REMOTE=1 ./install.sh)
# Roda no SEU computador: envia o pacote do painel + este instalador para a VPS
# e dispara a instalacao la dentro de um 'screen'. A instalacao NAO para se a
# conexao SSH cair. Os dados do painel sao perguntados uma unica vez aqui.
if [[ "${1:-}" == "--remote" || "${REMOTE:-0}" == "1" ]]; then
  REMOTE_USER="${REMOTE_USER:-root}"
  REMOTE_HOST="${REMOTE_HOST:-151.244.242.173}"
  REMOTE_PORT="${REMOTE_PORT:-22}"
  REMOTE_KEY="${REMOTE_KEY:-$HOME/.ssh/vps878}"
  REMOTE_DIR="${REMOTE_DIR:-/root/dtunnel-install}"
  SESSION="${SESSION:-dtunnel-install}"
  ZIP_FILE="${ZIP_FILE:-dtMod.zip}"
  RHOST="${REMOTE_USER}@${REMOTE_HOST}"
  SSH_OPTS=(-p "$REMOTE_PORT" -o IdentitiesOnly=yes -i "$REMOTE_KEY")   # ssh usa -p
  SCP_OPTS=(-P "$REMOTE_PORT" -o IdentitiesOnly=yes -i "$REMOTE_KEY")   # scp usa -P

  [[ -f "$REMOTE_KEY" ]]           || erro "chave SSH nao encontrada: $REMOTE_KEY  (rode ./vps878.sh)"
  [[ -f "$BASE_DIR/$ZIP_FILE" ]]   || erro "pacote nao encontrado: $BASE_DIR/$ZIP_FILE  (rode ./send_vps.sh ou gere o zip)"
  command -v scp >/dev/null 2>&1   || erro "scp nao instalado neste computador."

  secao "Instalacao remota do Painel DTunnel"
  info "VPS     : ${RHOST}:${REMOTE_PORT}"
  info "Pacote  : ${ZIP_FILE}  ($(du -h "$BASE_DIR/$ZIP_FILE" | cut -f1))"
  info "Sessao  : screen -S ${SESSION}   (dir remoto: ${REMOTE_DIR})"

  info "Testando acesso SSH..."
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 "$RHOST" true 2>/dev/null \
    || erro "sem acesso SSH a ${RHOST}. Configure a chave com:  ./vps878.sh"

  # ---- dados do painel: usa o que vier por env, pergunta o resto uma vez ----
  DOMAIN="$(printf '%s' "${DOMAIN:-}" | tr '[:upper:]' '[:lower:]' | xargs)"
  while [[ ! "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; do
    read -r -p "${CYA}Subdominio do painel (ex.: painel.seudominio.com): ${R}" DOMAIN
    DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)"
  done

  PORT="${PORT:-}"
  [[ -n "$PORT" ]] || { read -r -p "${CYA}Porta interna do painel [3000]: ${R}" PORT; PORT="${PORT:-3000}"; }
  [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]] || erro "porta invalida: '$PORT'"

  ADMIN_EMAIL="${ADMIN_EMAIL:-}"
  while [[ ! "$ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; do
    read -r -p "${CYA}E-mail do administrador: ${R}" ADMIN_EMAIL
  done

  ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"

  ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    while :; do
      read -rs -p "${CYA}Senha do administrador (min. 6): ${R}" ADMIN_PASSWORD; echo
      read -rs -p "${CYA}Confirme a senha: ${R}" _p2; echo
      [[ "$ADMIN_PASSWORD" == "$_p2" ]] || { aviso "as senhas nao conferem.";              continue; }
      [[ ${#ADMIN_PASSWORD} -ge 6 ]]    || { aviso "minimo de 6 caracteres.";               continue; }
      [[ "$ADMIN_PASSWORD" != *\'* ]]   || { aviso "a senha nao pode conter aspas simples."; continue; }
      break
    done
  else
    [[ ${#ADMIN_PASSWORD} -ge 6 && "$ADMIN_PASSWORD" != *\'* ]] \
      || erro "ADMIN_PASSWORD invalida (min. 6 caracteres, sem aspas simples)."
  fi

  CERT_EMAIL="${CERT_EMAIL:-$ADMIN_EMAIL}"

  # ---- runner remoto: exporta as variaveis, sobe o screen e se auto-apaga ----
  RUN_LOCAL="$(mktemp)"
  cat > "$RUN_LOCAL" <<RUNNER
#!/usr/bin/env bash
# gerado por install.sh --remote
set -eu
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
SESSION='${SESSION}'
LOG="\$DIR/install-\$(date -u +%Y%m%d-%H%M%S).log"

export ZIP='${ZIP_FILE}'
export DOMAIN='${DOMAIN}'
export PORT='${PORT}'
export ADMIN_EMAIL='${ADMIN_EMAIL}'
export ADMIN_USERNAME='${ADMIN_USERNAME}'
export ADMIN_PASSWORD='${ADMIN_PASSWORD}'
export CERT_EMAIL='${CERT_EMAIL}'
export SKIP_DNS_CHECK='${SKIP_DNS_CHECK:-0}'
export ASSUME_YES='1'
export DEBIAN_FRONTEND=noninteractive

cd "\$DIR" || exit 1
chmod +x install.sh
command -v screen >/dev/null 2>&1 || { apt-get update -y >/dev/null && apt-get install -y screen >/dev/null; }

screen -S "\$SESSION" -X quit >/dev/null 2>&1 || true
screen -dmS "\$SESSION" bash -c '
  cd "\$1" || exit 1
  ./install.sh 2>&1 | tee "\$2"
  s=\${PIPESTATUS[0]}
  echo
  echo "=========================================================="
  echo " install.sh terminou (exit \$s)  |  log: \$2"
  echo " Ctrl+A depois D para sair  |  screen -r \$3 para voltar"
  echo "=========================================================="
  exec bash
' _ "\$DIR" "\$LOG" "\$SESSION"

rm -f -- "\$0"
echo "SESSION=\$SESSION"
echo "LOG=\$LOG"
RUNNER

  info "Enviando arquivos para ${REMOTE_DIR}/ ..."
  ssh "${SSH_OPTS[@]}" "$RHOST" "mkdir -p '$REMOTE_DIR'"                              || erro "nao foi possivel criar $REMOTE_DIR na VPS."
  scp "${SCP_OPTS[@]}" "$BASE_DIR/$ZIP_FILE" "$RHOST:$REMOTE_DIR/$ZIP_FILE"          || erro "falha ao enviar $ZIP_FILE."
  scp "${SCP_OPTS[@]}" "${BASH_SOURCE[0]}"   "$RHOST:$REMOTE_DIR/install.sh"         || erro "falha ao enviar install.sh."
  scp "${SCP_OPTS[@]}" "$RUN_LOCAL"          "$RHOST:$REMOTE_DIR/.deploy-run.sh"     || erro "falha ao enviar o runner."
  rm -f "$RUN_LOCAL"
  # modulos opcionais (gerador de APK): manda a pasta inteira se existir
  for extra in build_app apk-generator app_base; do
    if [[ -d "$BASE_DIR/$extra" ]]; then
      info "Enviando $extra/ ..."
      ssh "${SSH_OPTS[@]}" "$RHOST" "rm -rf '$REMOTE_DIR/$extra'"
      scp "${SCP_OPTS[@]}" -r "$BASE_DIR/$extra" "$RHOST:$REMOTE_DIR/" \
        || aviso "falha ao enviar $extra/ (gerador de APK pode ficar desativado)."
    fi
  done

  info "Iniciando a instalacao dentro do screen '${SESSION}'..."
  ssh "${SSH_OPTS[@]}" "$RHOST" "bash '$REMOTE_DIR/.deploy-run.sh'"                   || erro "falha ao iniciar a instalacao remota."
  ok "Instalacao em andamento na VPS (sobrevive a queda de conexao)."

  ATTACH_CMD="ssh -p ${REMOTE_PORT} -i ${REMOTE_KEY} -t ${RHOST} 'screen -r ${SESSION}'"
  LOG_CMD="ssh -p ${REMOTE_PORT} -i ${REMOTE_KEY} ${RHOST} 'tail -f ${REMOTE_DIR}/install-*.log'"
  if [[ "${NO_ATTACH:-0}" == "1" ]]; then
    echo
    info "Acompanhar ao vivo:  ${B}${ATTACH_CMD}${R}"
    info "Ou ver o log:        ${B}${LOG_CMD}${R}"
    info "Sair do screen sem interromper a instalacao:  Ctrl+A  depois  D"
    exit 0
  fi
  info "Anexando ao screen...  (Ctrl+A depois D sai sem interromper a instalacao)"
  echo
  exec ssh "${SSH_OPTS[@]}" -t "$RHOST" "screen -r '$SESSION'"
fi

[[ "$(id -u)" -eq 0 ]] || erro "execute como root:  sudo ./install.sh"
command -v apt-get >/dev/null 2>&1 || erro "este instalador suporta apenas Ubuntu/Debian (apt)."

printf '%b\n' "${CYA}${B}"
printf '%s\n' "+----------------------------------------------+"
printf '%s\n' "|        INSTALADOR DO PAINEL DTUNNEL           |"
printf '%s\n' "|   multi-versao  .  HTTPS  .  Let's Encrypt    |"
printf '%s\n' "+----------------------------------------------+"
printf '%b\n' "${R}"

# ============================================================ 1. ESCOLHA DA VERSAO
secao "1/8  Versao do painel"
mapfile -t ZIPS < <(find "$BASE_DIR" -maxdepth 1 -type f -iname '*.zip' -printf '%f\n' | sort)
[[ ${#ZIPS[@]} -gt 0 ]] || erro "nenhum arquivo .zip encontrado em $BASE_DIR"

CHOSEN_ZIP=""
if [[ -n "${ZIP:-}" ]]; then
  if [[ "$ZIP" =~ ^[0-9]+$ ]]; then
    idx=$((ZIP - 1))
    [[ $idx -ge 0 && $idx -lt ${#ZIPS[@]} ]] || erro "indice ZIP=$ZIP fora da lista."
    CHOSEN_ZIP="${ZIPS[$idx]}"
  else
    for z in "${ZIPS[@]}"; do [[ "$z" == "$ZIP" ]] && CHOSEN_ZIP="$z" || true; done
    [[ -n "$CHOSEN_ZIP" ]] || erro "ZIP='$ZIP' nao encontrado em $BASE_DIR"
  fi
else
  echo "Versoes disponiveis em $BASE_DIR:"
  i=1
  for z in "${ZIPS[@]}"; do
    sz=$(du -h "$BASE_DIR/$z" | cut -f1)
    printf '  %b%2d%b) %s  %b(%s)%b\n' "$CYA$B" "$i" "$R" "$z" "$DIM" "$sz" "$R"
    i=$((i + 1))
  done
  read -r -p "${CYA}Numero da versao a instalar: ${R}" pick
  [[ "$pick" =~ ^[0-9]+$ ]] || erro "digite um numero."
  idx=$((pick - 1))
  [[ $idx -ge 0 && $idx -lt ${#ZIPS[@]} ]] || erro "opcao invalida."
  CHOSEN_ZIP="${ZIPS[$idx]}"
fi
ARCHIVE="$BASE_DIR/$CHOSEN_ZIP"
ok "Versao selecionada: ${B}${CHOSEN_ZIP}${R}"

# --- modulo opcional: gerador de APK (habilita se build_app/ (ou apk-generator/) + um .apk existirem) ---
APKGEN_DIR="$BASE_DIR/apk-generator"
[[ -f "$APKGEN_DIR/patch-application-page.py" ]] || APKGEN_DIR="$BASE_DIR/build_app"
APKGEN=0
APKBUILD=0
APK_SOURCE=""
if [[ -d "$APKGEN_DIR" ]]; then
  APK_SOURCE="${APK_BASE_APK:-}"
  # sem override: prefere o base "oficial" (DTMod_4.5.7.apk); senao, o 1o .apk por ordem
  for d in "$BASE_DIR/app_base" "$APKGEN_DIR"; do
    if [[ -z "$APK_SOURCE" && -f "$d/DTMod_4.5.7.apk" ]]; then APK_SOURCE="$d/DTMod_4.5.7.apk"; fi
  done
  [[ -z "$APK_SOURCE" ]] && APK_SOURCE="$(find "$BASE_DIR/app_base" "$APKGEN_DIR" -maxdepth 1 -type f -iname '*.apk' 2>/dev/null | sort | head -n1)"
  # builder: aceita apk-builder.sh ou build-apk.sh
  APK_BUILDER="$APKGEN_DIR/apk-builder.sh"
  [[ -f "$APK_BUILDER" ]] || APK_BUILDER="$APKGEN_DIR/build-apk.sh"
  if [[ -n "$APK_SOURCE" && -f "$APK_SOURCE" && -f "$APK_BUILDER" ]]; then
    APKGEN=1
    ok "Gerador de APK: base $(basename "$APK_SOURCE")"
    # micro-servico de build (apkbuild-server.js) para sites externos (dtmod.site).
    # so instala se os fontes existirem; chave compartilhada com o site.
    APKBUILD=0
    if [[ -f "$APKGEN_DIR/apkbuild-server.js" ]]; then
      APKBUILD=1
      APKBUILD_KEY="${APKBUILD_KEY:-}"
    fi
  else
    aviso "$(basename "$APKGEN_DIR")/ presente, mas falta o .apk base ou o build-apk.sh — gerador de APK desativado."
  fi
fi

# ============================================================ 2. DOMINIO E PORTA
secao "2/8  Subdominio e porta"
DOMAIN="${DOMAIN:-}"
if [[ -z "$DOMAIN" ]]; then
  read -r -p "${CYA}Subdominio do painel (ex.: painel.seudominio.com): ${R}" DOMAIN
fi
DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)"
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || erro "dominio invalido: '$DOMAIN'"

PORT="${PORT:-}"
if [[ -z "$PORT" ]]; then
  read -r -p "${CYA}Porta interna do painel [3000]: ${R}" PORT
  PORT="${PORT:-3000}"
fi
[[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]] || erro "porta invalida: '$PORT'"

# slug a partir do dominio -> permite varios paineis no mesmo servidor
SLUG="$(printf '%s' "$DOMAIN" | sed 's/[^a-z0-9]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')"
APP_DIR="$APP_ROOT/$SLUG"
SERVICE="dtunnel-$SLUG"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"
NGINX_FILE="/etc/nginx/sites-available/${SERVICE}.conf"
NGINX_LINK="/etc/nginx/sites-enabled/${SERVICE}.conf"
INSTANCE_CONF="$CONF_DIR/${SLUG}.conf"
ENV_FILE="$APP_DIR/.env"

# porta ja usada por OUTRO painel?
if [[ -d "$CONF_DIR" ]]; then
  while IFS= read -r other; do
    [[ -f "$other" ]] || continue
    [[ "$other" == "$INSTANCE_CONF" ]] && continue
    op="$(sed -n 's/^PORT=//p' "$other" | tr -d \"\' )"
    [[ "$op" != "$PORT" ]] || erro "a porta $PORT ja e usada pelo painel $(basename "${other%.conf}"). Escolha outra."
  done < <(find "$CONF_DIR" -maxdepth 1 -name '*.conf')
fi
if ss -ltn 2>/dev/null | grep -q ":${PORT} " && [[ ! -f "$INSTANCE_CONF" ]]; then
  confirmar "a porta $PORT ja esta em escuta neste servidor. Continuar assim mesmo?" || erro "cancelado."
fi

REINSTALL=0
[[ -f "$ENV_FILE" ]] && REINSTALL=1
if [[ $REINSTALL -eq 1 ]]; then
  ok "Reinstalacao detectada para ${B}${DOMAIN}${R} (.env e banco serao preservados)."
else
  ok "Nova instalacao: ${B}${DOMAIN}${R}  ->  127.0.0.1:${PORT}  (dir: $APP_DIR)"
fi

# ============================================================ 3. ADMIN + CERTBOT
secao "3/8  Administrador e certificado"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
CERT_EMAIL="${CERT_EMAIL:-}"

if [[ $REINSTALL -eq 0 ]]; then
  [[ -n "$ADMIN_EMAIL" ]]    || read -r -p  "${CYA}E-mail do administrador: ${R}" ADMIN_EMAIL
  [[ "$ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || erro "e-mail invalido."
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    read -rs -p "${CYA}Senha do administrador (min. 6): ${R}" ADMIN_PASSWORD; echo
    read -rs -p "${CYA}Confirme a senha: ${R}" p2; echo
    [[ "$ADMIN_PASSWORD" == "$p2" ]] || erro "as senhas nao conferem."
  fi
  [[ ${#ADMIN_PASSWORD} -ge 6 ]] || erro "a senha precisa ter ao menos 6 caracteres."
  [[ "$ADMIN_PASSWORD" != *\'* ]] || erro "a senha nao pode conter aspas simples ( ' )."
else
  info "Administrador mantido do .env atual (edite $ENV_FILE se quiser trocar)."
fi

if [[ -z "$CERT_EMAIL" ]]; then
  read -r -p "${CYA}E-mail do Let's Encrypt (ENTER para pular): ${R}" CERT_EMAIL
fi
[[ -z "$CERT_EMAIL" ]] && CERT_EMAIL="$ADMIN_EMAIL"

aviso "O subdominio ${B}${DOMAIN}${R} precisa apontar (registro A) para o IP desta VPS."
aviso "Se usar Cloudflare, deixe a nuvem CINZA (DNS only) durante a emissao do certificado."
confirmar "confirma que o DNS ja aponta para esta VPS e posso continuar?" || erro "ajuste o DNS e rode novamente."

# ============================================================ 4. DEPENDENCIAS
secao "4/8  Dependencias do sistema"
apt-get update -y
apt-get install -y ca-certificates curl gnupg unzip zip rsync openssl sqlite3 jq \
  build-essential python3 nginx certbot python3-certbot-nginx
if [[ $APKGEN -eq 1 ]]; then
  info "Toolchain do gerador de APK (JDK + apksigner + zipalign)..."
  apt-get install -y --no-install-recommends default-jdk-headless apksigner zipalign || {
    aviso "habilitando o repo 'universe' e tentando de novo..."
    apt-get install -y software-properties-common
    add-apt-repository -y universe
    apt-get update -y
    apt-get install -y --no-install-recommends default-jdk-headless apksigner zipalign \
      || erro "nao foi possivel instalar o toolchain de APK (JDK/apksigner/zipalign)."
  }
  for t in java keytool apksigner zipalign; do
    command -v "$t" >/dev/null 2>&1 || erro "toolchain de APK incompleto: falta '$t'."
  done
fi

if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 18 ]]; then
  info "Instalando Node.js ${NODE_MAJOR}.x ..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
fi
ok "Node $(node -v)  /  npm $(npm -v)"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
fi
systemctl enable --now nginx >/dev/null 2>&1 || true

# ============================================================ 5. CHECAGEM DE DNS
secao "5/8  Verificacao de DNS"
if [[ "${SKIP_DNS_CHECK:-0}" != "1" ]]; then
  PUBIP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || curl -4fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
  DNSIP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
  info "IP publico da VPS : ${PUBIP:-desconhecido}"
  info "IP(s) do dominio  : ${DNSIP:-nao resolveu}"
  if [[ -z "$DNSIP" ]]; then
    aviso "o dominio ainda nao resolve. O Certbot vai falhar se o DNS nao propagar."
    confirmar "continuar mesmo assim?" || erro "cancelado."
  elif [[ -n "$PUBIP" ]] && ! grep -qw "$PUBIP" <<<"$DNSIP"; then
    aviso "o dominio nao aponta para o IP desta VPS (possivel Cloudflare proxied ou registro errado)."
    confirmar "continuar mesmo assim?" || erro "cancelado."
  else
    ok "DNS aponta para esta VPS."
  fi
else
  aviso "checagem de DNS ignorada (SKIP_DNS_CHECK=1)."
fi

# ============================================================ 6. EXTRACAO
secao "6/8  Extraindo o painel"
if unzip -Z1 "$ARCHIVE" | grep -q '\\'; then
  erro "ZIP incompativel (caminhos com barra invertida). Gere o pacote novamente."
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -q "$ARCHIVE" -d "$TMP"

PKG="$(find "$TMP" -maxdepth 4 -type f -name package.json -not -path '*/node_modules/*' -print -quit)"
if [[ -z "$PKG" ]]; then
  NESTED="$(find "$TMP" -maxdepth 3 -type f -iname '*.zip' -print -quit)"
  [[ -n "$NESTED" ]] || erro "package.json nao encontrado dentro de $CHOSEN_ZIP"
  unzip -Z1 "$NESTED" | grep -q '\\' && erro "ZIP interno incompativel."
  unzip -q "$NESTED" -d "$TMP/_nested"
  PKG="$(find "$TMP/_nested" -maxdepth 4 -type f -name package.json -not -path '*/node_modules/*' -print -quit)"
  [[ -n "$PKG" ]] || erro "package.json nao encontrado dentro do zip aninhado."
fi
SRC="$(dirname "$PKG")"
[[ -f "$SRC/prisma/schema.prisma" ]] || erro "schema.prisma nao encontrado; zip nao parece ser o painel DTunnel."
ok "Codigo-fonte: ${SRC#$TMP/}"

# ============================================================ 7. BUILD + SERVICO
secao "7/8  Instalando em $APP_DIR"
if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE}.service"; then
  systemctl stop "$SERVICE" 2>/dev/null || true
fi

install -d -m 0755 "$APP_DIR" "$APP_DIR/data" "$CONF_DIR"
rsync -a --delete \
  --exclude 'node_modules/' --exclude 'build/' --exclude '.env' \
  --exclude 'data/' --exclude '*.db' --exclude '.git/' --exclude 'app_base/' \
  "$SRC/" "$APP_DIR/"
find "$APP_DIR" -maxdepth 1 -type f -name 'ecosystem*.*' -delete
cd "$APP_DIR"

# --- correcoes do painel (bugfixes aplicados a cada instalacao) ---
if [[ -f "$APKGEN_DIR/patch-dtunnelmod-api.py" ]]; then
  python3 "$APKGEN_DIR/patch-dtunnelmod-api.py" "$APP_DIR" || aviso "patch de /api/dtunnelmod nao aplicado."
fi

if [[ $APKGEN -eq 1 ]]; then
  info "Injetando o modulo gerador de APK no codigo-fonte..."
  install -d -m 0755 "$APP_DIR/app_base" "$APP_DIR/app_base/cache" "$APP_DIR/app_base/dist" "$APP_DIR/src/routes/DTunnel/Apk"
  # rotas do painel (POST /application/apk, status, download + estado compartilhado)
  rm -f "$APP_DIR/src/routes/DTunnel/Apk"/*.ts
  install -m 0644 "$APKGEN_DIR"/panel-src/routes/DTunnel/Apk/*.ts "$APP_DIR/src/routes/DTunnel/Apk/"
  install -m 0755 "$APK_BUILDER" "$APP_DIR/app_base/apk-builder.sh"
  install -m 0644 "$APK_SOURCE" "$APP_DIR/app_base/base.apk"
  python3 "$APKGEN_DIR/patch-application-page.py" "$APP_DIR"
fi

DB_PATH="$APP_DIR/data/database.db"
if [[ $REINSTALL -eq 0 ]]; then
  # migra um banco antigo, se existir dentro do pacote
  for cand in "$APP_DIR/prisma/database.db" "$APP_DIR/database.db"; do
    if [[ -s "$cand" && ! -s "$DB_PATH" ]]; then
      info "reaproveitando banco de $cand"; cp "$cand" "$DB_PATH"
    fi
  done
  # valores entre aspas simples: seguros para espacos, $, !, ", etc.
  umask 077
  cat > "$ENV_FILE" <<EOF
NODE_ENV=production
PORT=${PORT}
DATABASE_URL='file:${DB_PATH}'
CSRF_SECRET='$(openssl rand -base64 48 | tr -d '\n')'
JWT_SECRET_KEY='$(openssl rand -base64 48 | tr -d '\n')'
JWT_SECRET_REFRESH='$(openssl rand -base64 48 | tr -d '\n')'
ADMIN_EMAIL='${ADMIN_EMAIL}'
ADMIN_USERNAME='${ADMIN_USERNAME}'
ADMIN_PASSWORD='${ADMIN_PASSWORD}'
PUBLIC_URL='https://${DOMAIN}'
APK_KEYSTORE_PASS='$(openssl rand -hex 16)'
EOF
  umask 022
else
  sed -i "s|^PORT=.*|PORT=${PORT}|"                            "$ENV_FILE"
  sed -i "s|^DATABASE_URL=.*|DATABASE_URL='file:${DB_PATH}'|"  "$ENV_FILE"
  grep -q '^PUBLIC_URL=' "$ENV_FILE" \
    && sed -i "s|^PUBLIC_URL=.*|PUBLIC_URL='https://${DOMAIN}'|" "$ENV_FILE" \
    || echo "PUBLIC_URL='https://${DOMAIN}'" >> "$ENV_FILE"
fi
if [[ $APKGEN -eq 1 ]] && ! grep -q '^APK_KEYSTORE_PASS=' "$ENV_FILE"; then
  echo "APK_KEYSTORE_PASS='$(openssl rand -hex 16)'" >> "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"
find "$APP_DIR/prisma" -maxdepth 1 -name '*.db' -delete 2>/dev/null || true

info "Instalando dependencias do painel (pode demorar)..."
NODE_ENV=development npm install --include=dev --no-audit --no-fund
# o Prisma CLI carrega o .env do diretorio automaticamente
npx prisma generate
# As migrations deste pacote sao inconsistentes (duas migrations criam as mesmas
# tabelas), entao 'migrate deploy' quebra e, depois de um 'db push', da P3005.
# schema.prisma e a fonte da verdade -> sincronizamos sempre com 'db push'.
if [[ -s "$DB_PATH" ]]; then
  info "banco existente -> sincronizando schema (prisma db push)"
  npx prisma db push --skip-generate \
    || { aviso "db push seguro falhou; aplicando com --accept-data-loss."; \
         npx prisma db push --skip-generate --accept-data-loss; }
else
  info "banco novo -> criando schema (prisma db push)"
  npx prisma db push --skip-generate
fi
info "Compilando..."
rm -rf "$APP_DIR/build"
npm run build
npm prune --omit=dev >/dev/null 2>&1 || true
npx prisma generate >/dev/null 2>&1 || true
[[ -f "$APP_DIR/build/index.js" ]] || erro "a compilacao nao gerou build/index.js"
ok "Painel compilado."

if [[ $APKGEN -eq 1 ]]; then
  KS_PASS="$(sed -n "s/^APK_KEYSTORE_PASS='\(.*\)'\$/\1/p" "$ENV_FILE" | head -n1)"
  KS_FILE="$APP_DIR/app_base/panel.jks"
  if [[ ! -f "$KS_FILE" ]]; then
    keytool -genkeypair -keystore "$KS_FILE" -alias painel -keyalg RSA -keysize 2048 -validity 10000 \
      -storepass "$KS_PASS" -keypass "$KS_PASS" -dname "CN=DTunnel Panel, O=DTunnel, C=BR" >/dev/null 2>&1 \
      && ok "Keystore de assinatura criada (app_base/panel.jks)." \
      || aviso "nao foi possivel pre-criar a keystore; sera criada no primeiro uso."
  else
    ok "Keystore de assinatura preservada."
  fi
  chmod 600 "$KS_FILE" 2>/dev/null || true
  info "Smoke test do gerador de APK..."
  if bash "$APP_DIR/app_base/apk-builder.sh" --user-id smoke-test-00000000 --url "https://${DOMAIN}" \
       --base "$APP_DIR/app_base/base.apk" --keystore "$KS_FILE" --storepass "$KS_PASS" \
       --out "/tmp/apk-smoke-$$.apk" >/dev/null 2>&1; then
    rm -f "/tmp/apk-smoke-$$.apk"
    ok "Gerador de APK validado."
  else
    aviso "smoke test do gerador de APK falhou (verifique Java/apksigner com: apksigner version)."
  fi
fi

# ------------------- modulo opcional: micro-servico de build (sites externos) -------------------
# apkbuild-server.js em 127.0.0.1:8099, exposto pelo Nginx em /apkbuild/generate.
# Usado pelo painel PHP (dtmod.site) via core/gerar_apk.php. Compartilha a MESMA
# keystore do gerador do painel (assinaturas compativeis).
if [[ $APKBUILD -eq 1 ]]; then
  secao "Extra  Micro-servico de build de APK (/apkbuild/generate)"
  APKBUILD_DIR="/opt/apkbuild"
  APKBUILD_ENV="$CONF_DIR/apkbuild.conf"
  # chave compartilhada com o site: env > conf existente > gerada
  if [[ -z "${APKBUILD_KEY:-}" && -f "$APKBUILD_ENV" ]]; then
    APKBUILD_KEY="$(sed -n 's/^APKBUILD_KEY=//p' "$APKBUILD_ENV" | tr -d \"\' | head -n1)"
  fi
  [[ -n "${APKBUILD_KEY:-}" ]] || APKBUILD_KEY="$(openssl rand -hex 32)"

  install -d -m 0755 "$APKBUILD_DIR" "$APKBUILD_DIR/base" "$APKBUILD_DIR/cache"
  install -m 0755 "$APKGEN_DIR/apk-builder.sh"     "$APKBUILD_DIR/apk-builder.sh"
  install -m 0755 "$APKGEN_DIR/apkbuild-server.js" "$APKBUILD_DIR/apkbuild-server.js"
  install -m 0644 "$APK_SOURCE" "$APKBUILD_DIR/base/default.apk"
  # bases por tipo, se existirem em app_base/ (ssh|pro|v2ray)
  for t in ssh pro v2ray; do
    b="$(find "$BASE_DIR/app_base" -maxdepth 1 -type f -iname "*${t}*.apk" 2>/dev/null | sort | head -n1)"
    [[ -n "$b" ]] && install -m 0644 "$b" "$APKBUILD_DIR/base/${t}.apk" && info "base ${t}: $(basename "$b")"
  done

  # keystore: reaproveita a do gerador do painel (mesma chave = updates compativeis)
  KS_PASS="${KS_PASS:-$(sed -n "s/^APK_KEYSTORE_PASS='\(.*\)'\$/\1/p" "$ENV_FILE" | head -n1)}"
  if [[ -f "${KS_FILE:-}" ]]; then
    install -m 0600 "$KS_FILE" "$APKBUILD_DIR/panel.jks"
    ok "keystore compartilhada com o gerador do painel."
  elif [[ ! -f "$APKBUILD_DIR/panel.jks" ]]; then
    keytool -genkeypair -keystore "$APKBUILD_DIR/panel.jks" -alias painel -keyalg RSA -keysize 2048 \
      -validity 10000 -storepass "$KS_PASS" -keypass "$KS_PASS" \
      -dname "CN=DTunnel Panel, O=DTunnel, C=BR" >/dev/null 2>&1 \
      && ok "keystore criada em $APKBUILD_DIR/panel.jks" \
      || aviso "keystore sera criada no 1o build."
  fi
  chmod 600 "$APKBUILD_DIR/panel.jks" 2>/dev/null || true

  SDK_BT="$(find /opt/android-sdk/build-tools -maxdepth 1 -type d -name '3*' 2>/dev/null | sort -V | tail -n1)"
  cat > /etc/systemd/system/apkbuild.service <<EOF
[Unit]
Description=DTunnel APK build service (apkbuild-server.js)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${APKBUILD_DIR}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${SDK_BT:+:$SDK_BT}
Environment=APKBUILD_PORT=8099
Environment=APKBUILD_DIR=${APKBUILD_DIR}
Environment=APKBUILD_KEY=${APKBUILD_KEY}
Environment=APK_KEYSTORE_PASS=${KS_PASS}
ExecStart=$(command -v node) ${APKBUILD_DIR}/apkbuild-server.js
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  umask 077
  cat > "$APKBUILD_ENV" <<EOF
APKBUILD_KEY=${APKBUILD_KEY}
APKBUILD_DIR=${APKBUILD_DIR}
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  umask 022
  chmod 600 "$APKBUILD_ENV"

  systemctl daemon-reload
  systemctl enable apkbuild >/dev/null 2>&1 || true
  systemctl restart apkbuild

  okb=0
  for _ in $(seq 1 15); do
    if curl -fsS -o /dev/null --max-time 3 -X POST http://127.0.0.1:8099/generate \
         -H "X-Build-Key: ${APKBUILD_KEY}" \
         --data "type=default&user_id=smoke0000&panel_url=https://${DOMAIN}"; then okb=1; break; fi
    sleep 1
  done
  if [[ $okb -eq 1 ]]; then
    ok "Micro-servico de build ativo (127.0.0.1:8099) e smoke test OK."
  else
    aviso "apkbuild nao respondeu ao smoke test:"
    journalctl -u apkbuild -n 20 --no-pager || true
  fi
fi

NODE_BIN="$(command -v node)"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Painel DTunnel (${DOMAIN})
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} ${APP_DIR}/build/index.js
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1 || true
systemctl restart "$SERVICE"

info "Testando o painel em 127.0.0.1:${PORT} ..."
okport=0
for _ in $(seq 1 20); do
  if curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:${PORT}/login"; then okport=1; break; fi
  sleep 1
done
[[ $okport -eq 1 ]] || { journalctl -u "$SERVICE" -n 40 --no-pager || true; erro "o painel nao respondeu na porta ${PORT}."; }
ok "Painel ativo na porta interna ${PORT}."

# ============================================================ 8. NGINX + HTTPS
secao "8/8  Nginx e HTTPS"
APKBUILD_LOC=""
if [[ $APKBUILD -eq 1 ]]; then
  APKBUILD_LOC=$(cat <<'NLOC'

    # micro-servico de build de APK (apkbuild-server.js) usado por sites externos (dtmod.site)
    location = /apkbuild/generate {
        proxy_pass http://127.0.0.1:8099/generate;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        client_max_body_size 8k;
    }
NLOC
)
fi
cat > "$NGINX_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 25M;

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }

    # gerador de APK: build ~10s + download ~60 MB
    location = /application/apk {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
${APKBUILD_LOC}
}
EOF
ln -sfn "$NGINX_FILE" "$NGINX_LINK"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

info "Emitindo certificado Let's Encrypt para ${DOMAIN} ..."
CB=(certbot --nginx --non-interactive --agree-tos --redirect --keep-until-expiring -d "$DOMAIN")
if [[ -n "$CERT_EMAIL" ]]; then CB+=(--email "$CERT_EMAIL"); else CB+=(--register-unsafely-without-email); fi
if "${CB[@]}"; then
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  nginx -t && systemctl reload nginx || true
  HTTPS_OK=1
else
  aviso "o Certbot falhou. O painel segue acessivel em HTTP."
  aviso "corrija o DNS/porta 80 e rode:  certbot --nginx -d ${DOMAIN} --redirect"
  HTTPS_OK=0
fi

# --------------------------------------------------------------- metadados + helper
cat > "$INSTANCE_CONF" <<EOF
SLUG=${SLUG}
DOMAIN=${DOMAIN}
PORT=${PORT}
APP_DIR=${APP_DIR}
SERVICE=${SERVICE}
VERSION_ZIP=${CHOSEN_ZIP}
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 600 "$INSTANCE_CONF"

cat > "$HELPER" <<'HELPER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
CONF_DIR="/etc/dtunnel"
list() {
  printf '%-28s %-8s %-10s %s\n' "DOMINIO" "PORTA" "ESTADO" "SERVICO"
  for f in "$CONF_DIR"/*.conf; do
    [[ -f "$f" ]] || continue
    ( . "$f"
      st="$(systemctl is-active "$SERVICE" 2>/dev/null || echo desconhecido)"
      printf '%-28s %-8s %-10s %s\n' "$DOMAIN" "$PORT" "$st" "$SERVICE" )
  done
}
pick() {
  local d="${1:-}"
  [[ -n "$d" ]] || { echo "informe o dominio. use: dtunnel list" >&2; exit 1; }
  local f="$CONF_DIR/$(printf '%s' "$d" | sed 's/[^a-z0-9]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//').conf"
  [[ -f "$f" ]] || { echo "painel '$d' nao encontrado. use: dtunnel list" >&2; exit 1; }
  echo "$f"
}
cmd="${1:-list}"; shift || true
case "$cmd" in
  list|ls) list ;;
  status)  . "$(pick "${1:-}")"; systemctl status "$SERVICE" --no-pager ;;
  logs)    . "$(pick "${1:-}")"; journalctl -u "$SERVICE" -n 100 -f ;;
  restart) . "$(pick "${1:-}")"; systemctl restart "$SERVICE"; echo "reiniciado: $DOMAIN" ;;
  stop)    . "$(pick "${1:-}")"; systemctl stop "$SERVICE";  echo "parado: $DOMAIN" ;;
  start)   . "$(pick "${1:-}")"; systemctl start "$SERVICE"; echo "iniciado: $DOMAIN" ;;
  renew)   certbot renew --nginx ;;
  uninstall|remove)
    f="$(pick "${1:-}")"; . "$f"
    read -r -p "Remover o painel $DOMAIN e seus dados? digite REMOVER: " c
    [[ "$c" == "REMOVER" ]] || { echo "cancelado."; exit 0; }
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE}.service"
    systemctl daemon-reload
    rm -f "/etc/nginx/sites-enabled/${SERVICE}.conf" "/etc/nginx/sites-available/${SERVICE}.conf"
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null || true
    rm -rf "$APP_DIR"; rm -f "$f"
    echo "painel $DOMAIN removido. Nginx e demais paineis preservados." ;;
  *) echo "uso: dtunnel {list|status|logs|restart|start|stop|renew|uninstall} [dominio]" ; exit 1 ;;
esac
HELPER_EOF
chmod 0755 "$HELPER"

# --------------------------------------------------------------------- resumo
secao "Concluido"
ok "Painel     : ${B}${DOMAIN}${R}"
if [[ "${HTTPS_OK:-0}" -eq 1 ]]; then
  ok "Acesso     : ${B}https://${DOMAIN}/login${R}"
else
  ok "Acesso     : ${B}http://${DOMAIN}/login${R}  (HTTPS pendente)"
fi
ok "Versao     : ${CHOSEN_ZIP}"
ok "Porta      : ${PORT} (interna, atras do Nginx)"
ok "Diretorio  : ${APP_DIR}"
ok "Banco      : ${DB_PATH}"
ok "Servico    : systemctl status ${SERVICE}"
ok "Gerenciar  : ${B}dtunnel list${R} | dtunnel logs ${DOMAIN} | dtunnel restart ${DOMAIN}"
if [[ $APKGEN -eq 1 ]]; then
  ok "Gerar APK  : botao 'GERAR APK' em ${B}https://${DOMAIN}/application${R}"
  ok "             base: app_base/base.apk  .  chave: app_base/panel.jks  .  cache: app_base/cache/"
  aviso "APK assinado com chave propria: para instalar por cima do app da loja, desinstale antes."
fi
if [[ $APKBUILD -eq 1 ]]; then
  ok "Build API  : ${B}https://${DOMAIN}/apkbuild/generate${R}  (servico apkbuild, 127.0.0.1:8099)"
  ok "             dir: /opt/apkbuild  .  bases: /opt/apkbuild/base/  .  chave em /etc/dtunnel/apkbuild.conf"
  ok "             no site (public_html/core/apkbuild_config.php):"
  ok "               APKBUILD_URL = 'https://${DOMAIN}/apkbuild/generate'"
  ok "               APKBUILD_KEY = '${APKBUILD_KEY}'"
  aviso "FACA BACKUP de /opt/apkbuild/panel.jks (perder a chave = usuarios reinstalam)."
fi
if [[ $REINSTALL -eq 0 ]]; then
  echo
  info "Login inicial: ${ADMIN_EMAIL}  /  (a senha definida agora)"
fi
echo
