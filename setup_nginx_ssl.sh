#!/bin/bash
set -Eeuo pipefail

trap 'echo -e "\n\033[0;31m✘  Упал на строке ${LINENO}: [${BASH_COMMAND}] код $?\033[0m\n"; exit 1' ERR

# Цвета
R='\033[0;31m'
G='\033[0;32m'
Y='\033[0;33m'
B='\033[0;34m'
C='\033[0;36m'
M='\033[0;35m'
W='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

STEP=0
TOTAL=8

header() {
  echo -e "\n${B}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${B}║${W}  Nginx + SSL автонастройка                  ${B}║${NC}"
  echo -e "${B}╚══════════════════════════════════════════════╝${NC}\n"
}

step() {
  STEP=$((STEP + 1))
  local label="$1"
  local bar=""
  local filled=$(( STEP * 20 / TOTAL ))
  for ((i=0; i<filled; i++));  do bar+="█"; done
  for ((i=filled; i<20; i++)); do bar+="░"; done
  echo -e "\n${C}┌─[${W} Шаг ${STEP}/${TOTAL}${C} ]──────────────────────────────${NC}"
  echo -e "${C}│${NC} ${W}${label}${NC}"
  echo -e "${C}│${NC} ${G}${bar}${NC} ${DIM}${STEP}/${TOTAL}${NC}"
  echo -e "${C}└────────────────────────────────────────────${NC}"
}

ok()   { echo -e "  ${G}v${NC}  $*"; }
info() { echo -e "  ${C}i${NC}  $*"; }
warn() { echo -e "  ${Y}!${NC}  $*"; }
die()  { echo -e "\n  ${R}x  ОШИБКА: $*${NC}\n"; exit 1; }

[ "$EUID" -eq 0 ] || die "Запустите скрипт от root"

header

# ── Шаг 1: параметры ──────────────────────────
step "Ввод параметров"

read -rp "$(echo -e "  ${M}> Домен: ${NC}")" DOMAIN
[ -n "${DOMAIN:-}" ] || die "Домен не указан"
read -rp "$(echo -e "  ${M}> Email: ${NC}")" EMAIL
[ -n "${EMAIL:-}" ] || die "Email не указан"

ok "Домен: ${W}${DOMAIN}${NC}"
ok "Email: ${W}${EMAIL}${NC}"

# ── Шаг 2: порты ──────────────────────────────
step "Проверка портов 80 и 4443"

check_port() {
  local p="$1"
  if ss -ltnp "( sport = :${p} )" 2>/dev/null | grep -q LISTEN; then
    warn "Порт ${p} занят!"
    local PID
    PID=$(ss -ltnp "( sport = :${p} )" | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    if [ -n "${PID:-}" ]; then
      local PROC USER_NAME
      PROC=$(ps -o comm= -p "$PID" 2>/dev/null || echo "?")
      USER_NAME=$(ps -o user= -p "$PID" 2>/dev/null || echo "?")
      echo -e "  ${DIM}PID=${PID}  процесс=${PROC}  пользователь=${USER_NAME}${NC}"
    fi
    die "Освободите порт ${p} и перезапустите скрипт"
  else
    ok "Порт ${p} свободен"
  fi
}

check_port 80
check_port 4443

# ── Шаг 3: apt ────────────────────────────────
step "Ожидание apt и установка пакетов"

wait_for_apt() {
  local locks=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/cache/apt/archives/lock
    /var/lib/apt/lists/lock
  )
  local waited=0
  local busy busy_lock

  while true; do
    busy=false
    busy_lock=""
    for lk in "${locks[@]}"; do
      if [ -f "$lk" ] && lsof "$lk" &>/dev/null 2>&1; then
        busy=true
        busy_lock="$lk"
        break
      fi
    done

    if [ "$busy" = "false" ]; then
      break
    fi

    if [ "$waited" -eq 0 ]; then
      echo ""
      warn "apt заблокирован другим процессом..."
      local APT_PID=""
      APT_PID=$(lsof -t "$busy_lock" 2>/dev/null | head -1 || true)
      if [ -n "${APT_PID:-}" ]; then
        local APT_CMD
        APT_CMD=$(ps -o cmd= -p "$APT_PID" 2>/dev/null || echo "?")
        echo -e "  ${DIM}PID=${APT_PID}  команда: ${APT_CMD}${NC}"
      fi
      echo ""
      echo -e "  ${Y}Что делаем?${NC}"
      echo -e "  ${W}[1]${NC} Ждать (проверка каждые 5 сек)"
      echo -e "  ${W}[2]${NC} Убить процесс и продолжить"
      echo -e "  ${W}[3]${NC} Выйти"
      local APT_CHOICE=""
      read -rp "$(echo -e "  ${M}> Выбор [1/2/3]: ${NC}")" APT_CHOICE
      case "${APT_CHOICE:-1}" in
        2)
          if [ -n "${APT_PID:-}" ]; then
            warn "Убиваем PID ${APT_PID}..."
            kill -9 "$APT_PID" 2>/dev/null || true
            sleep 2
            dpkg --configure -a 2>/dev/null || true
            ok "Процесс убит, dpkg восстановлен"
          else
            warn "PID не определён — ждём..."
          fi
          ;;
        3) die "Прервано пользователем" ;;
        *) info "Ждём освобождения apt..." ;;
      esac
    fi

    echo -ne "  ${DIM}Ждём apt... ${waited}s\r${NC}"
    sleep 5
    waited=$((waited + 5))

    if [ "$waited" -ge 300 ]; then
      die "apt заблокирован уже 5 минут"
    fi
  done

  if [ "$waited" -gt 0 ]; then
    echo ""
  fi
}

wait_for_apt

info "Обновляем индекс пакетов..."
apt-get update 2>&1 | while IFS= read -r line; do echo -e "  ${DIM}${line}${NC}"; done
true

info "Устанавливаем: nginx ufw curl socat dnsutils..."
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx ufw curl socat dnsutils \
  2>&1 | while IFS= read -r line; do echo -e "  ${DIM}${line}${NC}"; done
true

ok "Пакеты установлены"

# ── Шаг 4: DNS ────────────────────────────────
step "Проверка DNS домена"

SERVER4=$(curl -4 -s --max-time 5 https://api.ipify.org || true)
SERVER6=$(curl -6 -s --max-time 5 https://api64.ipify.org || true)
A=$(dig +short A "$DOMAIN" | tail -1 || true)
AAAA=$(dig +short AAAA "$DOMAIN" | tail -1 || true)

info "IPv4 сервера : ${SERVER4:-н/д}"
info "IPv6 сервера : ${SERVER6:-н/д}"
info "A-запись     : ${A:-н/д}"
info "AAAA-запись  : ${AAAA:-н/д}"

MATCH=false
if [ -n "$A" ] && [ "$A" = "$SERVER4" ]; then MATCH=true; fi
if [ -n "$AAAA" ] && [ "$AAAA" = "$SERVER6" ]; then MATCH=true; fi

if [ "$MATCH" = "false" ]; then
  die "DNS домена ${DOMAIN} не указывает на этот сервер"
fi
ok "DNS в порядке"

# ── Шаг 5: acme.sh + сертификат ───────────────
step "Установка acme.sh и получение сертификата"

ACME="$HOME/.acme.sh/acme.sh"

if [ ! -f "$ACME" ]; then
  info "Устанавливаем acme.sh..."
  curl -fsSL https://get.acme.sh -o /tmp/acme_install.sh
  bash /tmp/acme_install.sh 2>&1 | while IFS= read -r line; do
    echo -e "  ${DIM}${line}${NC}"
  done
  true
  rm -f /tmp/acme_install.sh
  if [ -f "$HOME/.acme.sh/acme.sh.env" ]; then
    # shellcheck disable=SC1091
    source "$HOME/.acme.sh/acme.sh.env" || true
  fi
  if [ ! -f "$ACME" ]; then
    die "acme.sh не установился — проверьте интернет-соединение"
  fi
  ok "acme.sh установлен"
else
  ok "acme.sh уже есть: ${ACME}"
fi

"$ACME" --register-account -m "$EMAIL" 2>/dev/null || true

mkdir -p /var/www/certbot "/etc/nginx/ssl/${DOMAIN}"

info "Настраиваем временный nginx для ACME challenge..."
cat > "/etc/nginx/sites-available/${DOMAIN}" <<NGINXEOF
server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 200 "ACME ready";
    }
}
NGINXEOF

ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
rm -f /etc/nginx/sites-enabled/default
nginx -t -q && systemctl restart nginx
ok "Временный nginx запущен"

info "Выпускаем сертификат для ${DOMAIN}..."
"$ACME" --issue -d "$DOMAIN" --webroot /var/www/certbot --force 2>&1 | \
  while IFS= read -r line; do echo -e "  ${DIM}${line}${NC}"; done
ISSUE_RC="${PIPESTATUS[0]}"
if [ "${ISSUE_RC}" -ne 0 ] && [ "${ISSUE_RC}" -ne 2 ]; then
  die "acme.sh --issue завершился с кодом ${ISSUE_RC}"
fi
ok "Сертификат выпущен"

# ── Шаг 6: установка сертификата ──────────────
step "Установка сертификата в систему"

"$ACME" --install-cert -d "$DOMAIN" \
  --key-file      "/etc/nginx/ssl/${DOMAIN}/privkey.pem" \
  --fullchain-file "/etc/nginx/ssl/${DOMAIN}/fullchain.pem" \
  --reloadcmd     "systemctl reload nginx"

ok "Сертификат установлен в /etc/nginx/ssl/${DOMAIN}/"

# ── Шаг 7: финальный nginx ────────────────────
step "Финальная конфигурация nginx"

cat > "/etc/nginx/sites-available/${DOMAIN}" <<NGINXEOF
server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    ssl_certificate     /etc/nginx/ssl/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    location / {
        proxy_pass              http://127.0.0.1:4443;
        proxy_http_version      1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_read_timeout      3600s;
        proxy_send_timeout      3600s;
    }
}
NGINXEOF

nginx -t -q && systemctl restart nginx
ok "Nginx перезапущен с финальным конфигом"

# ── Шаг 8: ufw ────────────────────────────────
step "Настройка ufw"

ufw allow 22/tcp    comment 'SSH'     > /dev/null
ufw allow 80/tcp    comment 'HTTP'    > /dev/null
ufw allow 443/tcp   comment 'HTTPS'   > /dev/null
ufw allow 4443/tcp  comment 'App'     > /dev/null
ufw allow 2222/tcp  comment 'SSH-alt' > /dev/null
ufw --force enable  > /dev/null
ufw reload          > /dev/null

ok "Разрешены порты: 22, 80, 443, 4443, 2222"

# ── Итог ──────────────────────────────────────
echo ""
echo -e "${G}╔══════════════════════════════════════════════╗${NC}"
echo -e "${G}║${W}  Готово!                                     ${G}║${NC}"
echo -e "${G}╠══════════════════════════════════════════════╣${NC}"
echo -e "${G}║${NC}  https://${DOMAIN}"
echo -e "${G}║${NC}  Сертификат : /etc/nginx/ssl/${DOMAIN}/"
echo -e "${G}║${NC}  Бэкенд     : http://127.0.0.1:4443"
echo -e "${G}║${NC}  Autorenewal: cron настроен acme.sh"
echo -e "${G}╚══════════════════════════════════════════════╝${NC}"
echo ""
