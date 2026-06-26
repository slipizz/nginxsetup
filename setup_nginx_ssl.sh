#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]; then echo "Run as root"; exit 1; fi

read -rp "Введите домен: " DOMAIN
[ -n "$DOMAIN" ] || { echo "Домен не указан"; exit 1; }
read -rp "Введите email: " EMAIL
[ -n "$EMAIL" ] || { echo "Email не указан"; exit 1; }

apt update
apt install -y nginx ufw curl socat dnsutils

SERVER4=$(curl -4 -s https://api.ipify.org || true)
SERVER6=$(curl -6 -s https://api64.ipify.org || true)
A=$(dig +short A "$DOMAIN"|tail -1)
AAAA=$(dig +short AAAA "$DOMAIN"|tail -1)
if ! { [ -n "$A" ] && [ "$A" = "$SERVER4" ]; } && ! { [ -n "$AAAA" ] && [ "$AAAA" = "$SERVER6" ]; }; then
 echo "DNS домена не указывает на этот сервер"; exit 1; fi

check_port(){
p=$1
if ss -ltnp "( sport = :$p )"|grep -q LISTEN; then
 echo "Порт $p занят:"
 ss -ltnp "( sport = :$p )"
 PID=$(ss -ltnp "( sport = :$p )"|grep -oP 'pid=\K[0-9]+'|head -1||true)
 if [ -n "${PID:-}" ]; then
  USER=$(ps -o user= -p "$PID")
  echo "PID: $PID"
  echo "Процесс: $(ps -o comm= -p "$PID")"
  echo "Пользователь: $USER"
  echo "UID: $(id -u "$USER")"
 fi
 exit 1
fi
}
check_port 80
check_port 4443

[ -f "$HOME/.acme.sh/acme.sh" ] || curl https://get.acme.sh | sh
"$HOME/.acme.sh/acme.sh" --register-account -m "$EMAIL" || true

mkdir -p /var/www/certbot /etc/nginx/ssl/"$DOMAIN"

cat >/etc/nginx/sites-available/"$DOMAIN" <<EOF
server {
 listen 80;
 server_name $DOMAIN;
 location /.well-known/acme-challenge/ { root /var/www/certbot; }
 location / { return 200 "ACME"; }
}
EOF
ln -sf /etc/nginx/sites-available/"$DOMAIN" /etc/nginx/sites-enabled/"$DOMAIN"
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

"$HOME/.acme.sh/acme.sh" --issue -d "$DOMAIN" --webroot /var/www/certbot
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 4443/tcp; ufw allow 2222/tcp
ufw --force enable && ufw reload
"$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN"  --key-file /etc/nginx/ssl/"$DOMAIN"/privkey.pem  --fullchain-file /etc/nginx/ssl/"$DOMAIN"/fullchain.pem  --reloadcmd "systemctl reload nginx"

cat >/etc/nginx/sites-available/"$DOMAIN" <<EOF
server {
 listen 80;
 server_name $DOMAIN;
 location /.well-known/acme-challenge/ { root /var/www/certbot; }
 location / { return 301 https://\$host\$request_uri; }
}
server {
 listen 443 ssl http2;
 server_name $DOMAIN;
 ssl_certificate /etc/nginx/ssl/$DOMAIN/fullchain.pem;
 ssl_certificate_key /etc/nginx/ssl/$DOMAIN/privkey.pem;
 ssl_protocols TLSv1.2 TLSv1.3;
 location / {
  proxy_pass http://127.0.0.1:4443;
  proxy_http_version 1.1;
  proxy_set_header Host \$host;
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto https;
  proxy_buffering off;
  proxy_request_buffering off;
  proxy_read_timeout 3600s;
  proxy_send_timeout 3600s;
 }
}
EOF
nginx -t && systemctl restart nginx
GREEN='\033[0;32m'
NC='\033[0m'

echo
echo -e "${GREEN}"
echo "############################################################"
echo "#                                                          #"
echo "#                       ГОТОВО!                            #"
echo "#                                                          #"
echo "############################################################"
echo -e "${NC}"

echo "Домен: $DOMAIN"
echo "HTTPS: https://$DOMAIN"
echo
echo "✔ SSL сертификат установлен"
echo "✔ Nginx настроен"
echo "✔ Firewall настроен"
echo
