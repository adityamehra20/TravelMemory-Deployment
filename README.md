# TravelMemory Application Deployment on AWS EC2

A complete, reproducible guide to deploying the **TravelMemory** MERN-stack
application on Amazon EC2 with **Nginx** as a reverse proxy, an **Application
Load Balancer (ALB)** for horizontal scaling, and a **custom domain managed
through Cloudflare**.

> Original application repository: <https://github.com/UnpredictablePrashant/TravelMemory>

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Backend Configuration](#3-backend-configuration)
4. [Frontend & Backend Connection](#4-frontend--backend-connection)
5. [Nginx Reverse Proxy](#5-nginx-reverse-proxy)
6. [Scaling with Multiple Instances + Load Balancer](#6-scaling-with-multiple-instances--load-balancer)
7. [Domain Setup with Cloudflare](#7-domain-setup-with-cloudflare)
8. [Verification & Testing](#8-verification--testing)
9. [Security Best Practices](#9-security-best-practices)
10. [Troubleshooting](#10-troubleshooting)
11. [Deliverables Checklist](#11-deliverables-checklist)

---

## 1. Architecture Overview

```
                          ┌────────────────────────┐
        Custom Domain ──► │       Cloudflare       │  (DNS + proxy/SSL)
   (e.g. travelapp.com)   │  A record + CNAME      │
                          └───────────┬────────────┘
                                      │
                          ┌───────────▼────────────┐
                          │  Application Load       │
                          │  Balancer (ALB)         │
                          └─────┬─────────────┬─────┘
                                │             │
                    ┌───────────▼───┐   ┌─────▼─────────┐
                    │  EC2 Instance │   │  EC2 Instance │   (Target Group)
                    │      #1       │   │      #2       │
                    │  Nginx :80    │   │  Nginx :80    │
                    │   │           │   │   │           │
                    │   ├─ Frontend │   │   ├─ Frontend │  React build (static)
                    │   └─ /api ──► │   │   └─ /api ──► │  proxy_pass
                    │   Node :3000  │   │   Node :3000  │  Express backend
                    └───────┬───────┘   └───────┬───────┘
                            │                   │
                            └─────────┬─────────┘
                                      │
                          ┌───────────▼────────────┐
                          │   MongoDB Atlas         │  (managed database)
                          └────────────────────────┘
```

See [`architecture/travelmemory-architecture.drawio`](architecture/travelmemory-architecture.drawio)
for the editable diagram (open at <https://app.diagrams.net>).

---

## 2. Prerequisites

| Requirement | Notes |
|-------------|-------|
| AWS account | With permission to create EC2, Security Groups, ALB, Target Groups |
| MongoDB Atlas cluster | Free M0 tier is sufficient; get the connection string |
| A registered domain | Added to a Cloudflare account |
| Key pair (`.pem`) | For SSH access to EC2 |
| Local tools | `git`, an SSH client, a browser |

**Recommended AMI:** Ubuntu Server 22.04 LTS, `t2.micro` (free tier) or `t3.small`.

---

## 3. Backend Configuration

### 3.1 Launch an EC2 instance

1. EC2 → **Launch instance** → Ubuntu 22.04 LTS.
2. Instance type `t2.micro`.
3. Create/select a key pair.
4. **Security group** inbound rules:
   - SSH (22) — *My IP only*
   - HTTP (80) — `0.0.0.0/0`
   - HTTPS (443) — `0.0.0.0/0`
   - Custom TCP (3000) — *only from the Security Group / your IP* (for debugging; not public)
5. Launch and note the **public IPv4**.

### 3.2 Connect and install dependencies

```bash
ssh -i "your-key.pem" ubuntu@<EC2_PUBLIC_IP>

# Update system
sudo apt update && sudo apt upgrade -y

# Install Node.js 18 LTS
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs

# Install Nginx, git, and PM2 (process manager)
sudo apt install -y nginx git
sudo npm install -g pm2

# Verify
node -v && npm -v && nginx -v
```

### 3.3 Clone the repository

```bash
cd ~
git clone https://github.com/UnpredictablePrashant/TravelMemory.git
cd TravelMemory/backend
npm install
```

### 3.4 Create the backend `.env`

The assignment requires the backend to run on **port 3000**.
Create `backend/.env` (see [`code/backend/.env.example`](code/backend/.env.example)):

```env
MONGO_URI='mongodb+srv://<user>:<password>@<cluster>.mongodb.net/travelmemory?retryWrites=true&w=majority'
PORT=3000
```

> **Security:** never commit real credentials. `.env` is already in `.gitignore`.
> In MongoDB Atlas, add your EC2 instance IP (or `0.0.0.0/0` for testing only)
> to the **Network Access** allow-list.

### 3.5 Run the backend with PM2

```bash
cd ~/TravelMemory/backend
pm2 start index.js --name travel-backend
pm2 save
pm2 startup        # run the command it prints to enable boot-start
pm2 status
```

Quick local check:

```bash
curl http://localhost:3000/trip       # should return JSON (array)
```

---

## 4. Frontend & Backend Connection

The frontend reads the backend URL from an environment variable that is consumed
by [`frontend/src/url.js`](code/frontend/src/url.js).

### 4.1 `frontend/src/url.js`

```js
export const baseUrl = process.env.REACT_APP_BACKEND_URL;
```

### 4.2 Create `frontend/.env`

Point the frontend at the **public endpoint** that serves the API. Because Nginx
proxies `/api` to the backend on the same host, use a relative path or the
domain:

```env
# When served behind Nginx + domain (recommended)
REACT_APP_BACKEND_URL=https://api.<your-domain>.com

# OR during early testing against the EC2 IP
# REACT_APP_BACKEND_URL=http://<EC2_PUBLIC_IP>:3000
```

See [`code/frontend/.env.example`](code/frontend/.env.example).

### 4.3 Build the frontend

```bash
cd ~/TravelMemory/frontend
npm install
npm run build      # produces an optimized static build in ./build
```

The `build/` folder is what Nginx will serve.

---

## 5. Nginx Reverse Proxy

The assignment requires a reverse proxy so the app is reachable on port 80
(and 443) instead of exposing Node on 3000.

Two common patterns — pick **one**:

### Pattern A — Single server, frontend static + `/api` proxy (recommended)

Use [`code/nginx/travelmemory.conf`](code/nginx/travelmemory.conf):

```nginx
server {
    listen 80;
    server_name _;

    # Serve the React production build
    root /home/ubuntu/TravelMemory/frontend/build;
    index index.html;

    location / {
        try_files $uri /index.html;
    }

    # Reverse-proxy API calls to the Node backend on port 3000
    location /api/ {
        proxy_pass http://localhost:3000/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }
}
```

> With this pattern set `REACT_APP_BACKEND_URL=/api` so the browser calls the
> same origin and Nginx forwards to the backend.

### Pattern B — Pure reverse proxy to backend (separate frontend host)

Use [`code/nginx/reverse-proxy.conf`](code/nginx/reverse-proxy.conf) when the
backend EC2 only runs the API:

```nginx
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Enable the site

```bash
# Copy the chosen config
sudo cp ~/TravelMemory/code/nginx/travelmemory.conf /etc/nginx/sites-available/travelmemory

# Enable it and disable the default
sudo ln -s /etc/nginx/sites-available/travelmemory /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Test config and reload
sudo nginx -t
sudo systemctl restart nginx
```

Browse to `http://<EC2_PUBLIC_IP>/` — the app should load and talk to the API.

---

## 6. Scaling with Multiple Instances + Load Balancer

### 6.1 Create a reusable image

1. Once instance #1 is fully working, EC2 → **Actions → Image → Create image**.
2. Launch **instance #2** (and more) from that AMI — they boot pre-configured.
   - PM2 `startup` ensures the backend auto-starts.
   - Nginx auto-starts as a systemd service.

### 6.2 Create a Target Group

1. EC2 → **Target Groups → Create target group**.
2. Type: **Instances**, protocol **HTTP**, port **80**.
3. **Health check path:** `/` (frontend) or `/api/trip` (API).
4. Register instance #1 and instance #2.

### 6.3 Create an Application Load Balancer

1. EC2 → **Load Balancers → Create → Application Load Balancer**.
2. Scheme: **internet-facing**, IP type IPv4.
3. Map at least **two Availability Zones** (and put instances across them for
   resilience).
4. Listener: **HTTP :80** → forward to the Target Group above.
5. ALB security group: allow inbound 80/443 from `0.0.0.0/0`.
6. Note the ALB **DNS name** (e.g. `travel-alb-123456.us-east-1.elb.amazonaws.com`).

### 6.4 Lock down the instances

Update each EC2 security group so port 80 only accepts traffic **from the ALB's
security group** (not the whole internet). This forces all traffic through the
load balancer.

Test: open `http://<ALB_DNS_NAME>/` — refreshing should be served by either
instance (check via different instance hostnames in logs).

---

## 7. Domain Setup with Cloudflare

### 7.1 Add your domain to Cloudflare

1. Cloudflare dashboard → **Add a site** → enter your domain.
2. Update your registrar's nameservers to the two Cloudflare nameservers shown.
3. Wait for activation (status **Active**).

### 7.2 DNS records (per the assignment)

| Type  | Name              | Target                              | Proxy   | Purpose |
|-------|-------------------|-------------------------------------|---------|---------|
| CNAME | `www` (or `app`)  | `<ALB_DNS_NAME>`                    | Proxied | Route traffic to the load balancer |
| A     | `@` (root/front)  | `<EC2_PUBLIC_IP of frontend host>`  | Proxied | Connect the EC2 frontend instance via IP |

> **Hint from the assignment:** the **CNAME** links the **load-balancer
> endpoint**, while the **A record** maps an **EC2 instance IP**.
> If you want the apex/root domain on the ALB, use a CNAME on a subdomain
> (e.g. `app.your-domain.com`) because a root A record needs an IP, not a DNS
> name.

### 7.3 SSL/TLS

1. Cloudflare → **SSL/TLS → Overview** → set mode to **Full** (or **Full
   (strict)** if you install a cert/Origin Certificate on Nginx).
2. Enable **Always Use HTTPS** under SSL/TLS → Edge Certificates.

After DNS propagates, visit `https://www.<your-domain>.com`.

---

## 8. Verification & Testing

| Check | Command / Action | Expected |
|-------|------------------|----------|
| Backend up | `curl http://localhost:3000/trip` | JSON response |
| Nginx proxy | `curl http://<EC2_IP>/api/trip` | JSON response |
| Frontend | Open `http://<EC2_IP>/` | App loads, data renders |
| Load balancer | Open `http://<ALB_DNS>/` | App loads via ALB |
| Target health | EC2 → Target Group → Targets | All **healthy** |
| Domain | Open `https://<your-domain>` | App loads over HTTPS |
| Add a trip | Submit the form in the UI | Record saved, appears in list |

---

## 9. Security Best Practices

- **Least-privilege security groups:** SSH from your IP only; port 3000 never
  public; instance port 80 only from the ALB SG.
- **Secrets:** keep `MONGO_URI` in `.env`; never commit it. Rotate Atlas
  credentials if exposed.
- **MongoDB Atlas:** restrict Network Access to instance IPs, enable auth.
- **HTTPS everywhere:** Cloudflare Full (strict) + HTTP→HTTPS redirect.
- **Updates:** `sudo apt update && sudo apt upgrade` regularly; keep Node/Nginx patched.
- **PM2:** run the app as a non-root user (`ubuntu`), not root.
- **Cloudflare WAF / rate limiting** to absorb abusive traffic.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `502 Bad Gateway` from Nginx | Backend not running | `pm2 status`, `pm2 logs travel-backend` |
| Frontend loads but no data | Wrong `REACT_APP_BACKEND_URL` | Rebuild after editing `frontend/.env` |
| CORS errors | Backend origin mismatch | Use same-origin `/api` proxy (Pattern A) |
| Target shows **unhealthy** | Health check path wrong | Set TG health check to `/` or `/api/trip` |
| Mongo connection timeout | Atlas IP allow-list | Add EC2 IP in Atlas Network Access |
| Changes to React not visible | Served old build | `npm run build` then reload Nginx |

---

## 11. Deliverables Checklist

- [x] Backend running on Node.js (port 3000) via PM2
- [x] Nginx reverse proxy configured
- [x] `.env` with DB connection + port
- [x] `frontend/src/url.js` wired to backend
- [x] Multiple instances behind an ALB
- [x] Cloudflare CNAME (→ ALB) + A record (→ EC2 IP)
- [x] This documentation with steps + screenshot placeholders
- [x] draw.io architecture diagram (`architecture/`)
- [x] Repository link submitted on Vlearn

> **Screenshots:** add yours under [`screenshots/`](screenshots/) and reference
> them in [DEPLOYMENT.md](DEPLOYMENT.md) where placeholders are marked.
