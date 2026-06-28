#!/bin/bash
# =============================================================================
# TravelMemory EC2 bootstrap (EC2 "User data" script)
# Paste this into the "User data" field when launching an Ubuntu 22.04 instance,
# or run it manually after SSH. It installs Node, Nginx, PM2, clones the app,
# configures the backend (.env), builds the frontend, and wires up Nginx.
#
# EDIT the two variables in the CONFIG section before use.
# =============================================================================
set -euxo pipefail

# ---------------------------- CONFIG (EDIT ME) -------------------------------
MONGO_URI="mongodb+srv://<user>:<password>@<cluster>.mongodb.net/travelmemory?retryWrites=true&w=majority"
BACKEND_PORT=3000
# With Nginx Pattern A the browser calls same-origin /api, so this stays "/api".
FRONTEND_BACKEND_URL="/api"
# -----------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
APP_USER="ubuntu"
APP_HOME="/home/${APP_USER}"

# 1. System packages
apt-get update -y
apt-get upgrade -y
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs nginx git
npm install -g pm2

# 2. Clone the application
cd "${APP_HOME}"
if [ ! -d TravelMemory ]; then
  sudo -u "${APP_USER}" git clone https://github.com/UnpredictablePrashant/TravelMemory.git
fi

# 3. Backend: .env + install + start under PM2
cat > "${APP_HOME}/TravelMemory/backend/.env" <<EOF
MONGO_URI='${MONGO_URI}'
PORT=${BACKEND_PORT}
EOF
chown "${APP_USER}:${APP_USER}" "${APP_HOME}/TravelMemory/backend/.env"

cd "${APP_HOME}/TravelMemory/backend"
sudo -u "${APP_USER}" npm install
sudo -u "${APP_USER}" PM2_HOME="${APP_HOME}/.pm2" pm2 start index.js --name travel-backend
sudo -u "${APP_USER}" PM2_HOME="${APP_HOME}/.pm2" pm2 save
# Enable PM2 on boot for the ubuntu user
env PATH=$PATH:/usr/bin pm2 startup systemd -u "${APP_USER}" --hp "${APP_HOME}"

# 4. Frontend: .env + build
cat > "${APP_HOME}/TravelMemory/frontend/.env" <<EOF
REACT_APP_BACKEND_URL=${FRONTEND_BACKEND_URL}
EOF
chown "${APP_USER}:${APP_USER}" "${APP_HOME}/TravelMemory/frontend/.env"

cd "${APP_HOME}/TravelMemory/frontend"
sudo -u "${APP_USER}" npm install
sudo -u "${APP_USER}" npm run build

# 5. Nginx: serve build + proxy /api -> backend
cat > /etc/nginx/sites-available/travelmemory <<EOF
server {
    listen 80;
    server_name _;

    root ${APP_HOME}/TravelMemory/frontend/build;
    index index.html;

    location / {
        try_files \$uri /index.html;
    }

    location /api/ {
        proxy_pass http://localhost:${BACKEND_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

ln -sf /etc/nginx/sites-available/travelmemory /etc/nginx/sites-enabled/travelmemory
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx

echo "TravelMemory bootstrap complete. App available on port 80."
