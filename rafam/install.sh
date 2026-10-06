#!/usr/bin/env bash
# התקנת מערכת זימון התורים על השרת (AlmaLinux). מורידה את הקוד מ-GitHub ומתקינה.
# שימוש בשרת:
#   curl -sL https://raw.githubusercontent.com/esti3021/blank-app/rafam-deploy/rafam/install.sh | sudo bash -s -- rafam.co.il EMAIL
set -euo pipefail
dnf install -y curl >/dev/null 2>&1 || true
curl -sfL https://raw.githubusercontent.com/esti3021/blank-app/rafam-deploy/rafam/rafam.zip -o /tmp/rafam.zip
DOMAIN="${1:-}"; EMAIL="${2:-}"
APP=/opt/rafam_scheduler

dnf install -y epel-release
dnf install -y python3.11 python3.11-pip unzip nginx

id rafam >/dev/null 2>&1 || useradd --system --home-dir "$APP" --shell /sbin/nologin rafam
mkdir -p "$APP"
rm -rf /tmp/rafam_x && unzip -oq /tmp/rafam.zip -d /tmp/rafam_x
cp -a /tmp/rafam_x/rafam_scheduler_v2/. "$APP"/

python3.11 -m venv "$APP/.venv"
"$APP/.venv/bin/pip" install -q flask gunicorn openpyxl

if [ ! -f /etc/rafam.env ]; then
  echo "SECRET_KEY=$(python3.11 -c 'import secrets;print(secrets.token_hex(32))')" > /etc/rafam.env
  chmod 600 /etc/rafam.env
fi

chown -R rafam:rafam "$APP"
cd "$APP"
# יוצר את מסד הנתונים. בהפעלה ראשונה מודפסת כאן סיסמת admin: שמור אותה
runuser -u rafam -- "$APP/.venv/bin/python" -c "import app; app.init()"

cat > /etc/systemd/system/rafam.service <<'EOF'
[Unit]
Description=Rafam medical scheduler
After=network.target

[Service]
User=rafam
WorkingDirectory=/opt/rafam_scheduler
EnvironmentFile=/etc/rafam.env
ExecStart=/opt/rafam_scheduler/.venv/bin/gunicorn -w 2 -b 127.0.0.1:8000 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

SN="_"
[ -n "$DOMAIN" ] && SN="$DOMAIN www.$DOMAIN"
cat > /etc/nginx/conf.d/rafam.conf <<EOF
server {
    listen 80;
    server_name $SN;
    client_max_body_size 20m;
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# SELinux: מאפשר ל-nginx לפנות ל-gunicorn
if command -v setsebool >/dev/null; then setsebool -P httpd_can_network_connect 1 || true; fi
# חומת אש
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http --add-service=https
  firewall-cmd --reload
fi

systemctl daemon-reload
systemctl enable --now rafam
systemctl restart rafam
nginx -t
systemctl enable --now nginx
systemctl reload nginx

if [ -n "$DOMAIN" ]; then
  dnf install -y certbot python3-certbot-nginx
  if [ -n "$EMAIL" ]; then MAILOPT="-m $EMAIL --no-eff-email"; else MAILOPT="--register-unsafely-without-email"; fi
  if certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" $MAILOPT --agree-tos --redirect -n; then
    grep -q COOKIE_SECURE /etc/rafam.env || echo "COOKIE_SECURE=1" >> /etc/rafam.env
    systemctl restart rafam
    echo "HTTPS פעיל: https://$DOMAIN/"
  else
    echo "!!! התעודה לא הותקנה. בדוק שרשומת A של $DOMAIN (ושל www) מצביעה על השרת, והרץ שוב."
  fi
else
  echo "האתר זמין ב-http בלבד. כדי להתקין HTTPS הרץ שוב עם דומיין ואימייל."
fi
