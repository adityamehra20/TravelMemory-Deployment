# Deployment Walkthrough (with Screenshot Placeholders)

Use this file as the narrative submission document. Follow each step in
[README.md](README.md), capture the screenshots, and replace the placeholders
below. Save the finished version as a PDF for Vlearn if required.

> Place image files in the [`screenshots/`](screenshots/) folder and keep the
> filenames below, or update the links.

---

## Step 1 — EC2 Instance Launched
![EC2 instance running](screenshots/01-ec2-instance.png)
*EC2 console showing the running instance, its public IPv4, and security group.*

## Step 2 — SSH + Dependencies Installed
![Node, Nginx, PM2 versions](screenshots/02-dependencies.png)
*Terminal output of `node -v`, `nginx -v`, `pm2 -v`.*

## Step 3 — Backend Running on Port 3000
![PM2 backend running](screenshots/03-backend-pm2.png)
*`pm2 status` showing `travel-backend` online and a `curl localhost:3000/trip` response.*

## Step 4 — `.env` Configured
![Backend .env](screenshots/04-backend-env.png)
*`backend/.env` with MONGO_URI (redacted) and PORT=3000.*

## Step 5 — Frontend Built & `url.js` Wired
![Frontend build](screenshots/05-frontend-build.png)
*`npm run build` success and `frontend/src/url.js` / `frontend/.env` contents.*

## Step 6 — Nginx Reverse Proxy Working
![Nginx serving app](screenshots/06-nginx.png)
*`sudo nginx -t` OK and the app loading at `http://<EC2_IP>/`.*

## Step 7 — Multiple Instances + Load Balancer
![Target group healthy](screenshots/07-target-group.png)
*Target group showing both instances **healthy**.*

![ALB serving app](screenshots/08-alb.png)
*App loading via the ALB DNS name.*

## Step 8 — Cloudflare DNS Records
![Cloudflare DNS](screenshots/09-cloudflare-dns.png)
*CNAME → ALB endpoint and A record → EC2 IP, both proxied.*

## Step 9 — Live Application on Custom Domain
![Live app over HTTPS](screenshots/10-live-domain.png)
*App loading at `https://<your-domain>` with a valid certificate.*

## Step 10 — Architecture Diagram
![Architecture diagram](screenshots/11-architecture.png)
*Exported PNG of `architecture/travelmemory-architecture.drawio`.*

---

### Notes / Decisions
- Backend standardized on **port 3000** per the assignment (upstream README uses 3001).
- Frontend file is `url.js` (the assignment text says `urls.js`).
- Chose Nginx **Pattern A** (static frontend + `/api` proxy) to avoid CORS issues.
