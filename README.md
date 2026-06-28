# TravelMemory on AWS

This is my deployment of the TravelMemory MERN app on AWS. The app itself comes
from https://github.com/UnpredictablePrashant/TravelMemory - I didn't write the
application, the work here is getting it running on EC2 behind Nginx and a load
balancer, with the database on MongoDB Atlas.

The setup, in short:

* Two Ubuntu EC2 instances, each running the Node backend on port 3000 (kept
  alive with PM2) and Nginx on port 80.
* Nginx serves the React build as static files and proxies `/api` to the backend
  on the same box. This avoids CORS headaches.
* An Application Load Balancer in front of both instances, spread across two
  availability zones.
* MongoDB Atlas for the database.
* Cloudflare for the custom domain (CNAME to the load balancer, A record to a
  frontend instance).

There's a diagram in `architecture/` and a rendered version at
`screenshots/11-architecture.png`.

## What got deployed

The live values from my run are in [SUBMISSION.txt](SUBMISSION.txt). Quick
version:

* Account `145678291577`, region `ap-south-1`
* Instances `i-0f063ccb3d08dad9a` (65.1.136.12, ap-south-1a) and
  `i-07c84e906535f48dd` (13.233.80.192, ap-south-1b), both t2.micro
* Load balancer `travelmemory-alb`, endpoint
  `http://travelmemory-alb-376816329.ap-south-1.elb.amazonaws.com/`
* Target group `travelmemory-tg`, both targets healthy

Everything returns 200 - the raw AWS CLI output I captured is in
`screenshots/VERIFICATION.txt`.

## Backend

Launch an Ubuntu 22.04 instance (t2.micro is fine). Security group inbound:

* 22 from my IP only
* 80 from anywhere (later locked to the load balancer's SG)
* 3000 only from within the SG, just for debugging - never public

SSH in and install the basics:

```bash
sudo apt update && sudo apt upgrade -y
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs nginx git
sudo npm install -g pm2
```

Clone the app and set up the backend:

```bash
cd ~
git clone https://github.com/UnpredictablePrashant/TravelMemory.git
cd TravelMemory/backend
npm install
```

The assignment wants the backend on port 3000 (the upstream repo uses 3001, so I
changed it). Create `backend/.env`:

```env
MONGO_URI='mongodb+srv://<user>:<password>@<cluster>.mongodb.net/travelmemory?retryWrites=true&w=majority'
PORT=3000
```

Don't commit this. `.env` is in `.gitignore`. Also remember to add the instance
IP (or 0.0.0.0/0 if you're just testing) to Network Access in Atlas, otherwise
the connection just times out.

Run it under PM2 so it survives reboots:

```bash
cd ~/TravelMemory/backend
pm2 start index.js --name travel-backend
pm2 save
pm2 startup     # run whatever command it prints
pm2 status
curl http://localhost:3000/trip   # should return JSON
```

## Wiring the frontend to the backend

The frontend reads the backend URL from `frontend/src/url.js` (the assignment
text calls it `urls.js`, but the actual file is `url.js`):

```js
export const baseUrl = process.env.REACT_APP_BACKEND_URL;
```

Because Nginx proxies `/api` on the same host, I point the frontend at a relative
path. `frontend/.env`:

```env
REACT_APP_BACKEND_URL=/api
```

Then build it:

```bash
cd ~/TravelMemory/frontend
npm install
npm run build
```

Heads up: the React build can run out of memory on a t2.micro (1 GB RAM). I added
a 2 GB swap file before building - the bootstrap script does this automatically.

## Nginx

One server block: serve the React build, proxy `/api` to the backend.

```nginx
server {
    listen 80;
    server_name _;

    root /home/ubuntu/TravelMemory/frontend/build;
    index index.html;

    location / {
        try_files $uri /index.html;
    }

    location /api/ {
        proxy_pass http://localhost:3000/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Enable it:

```bash
sudo cp travelmemory.conf /etc/nginx/sites-available/travelmemory
sudo ln -s /etc/nginx/sites-available/travelmemory /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo chmod o+x /home/ubuntu        # see note below
sudo nginx -t
sudo systemctl restart nginx
```

That `chmod o+x /home/ubuntu` line cost me a while. Nginx runs as `www-data` and
couldn't traverse into `/home/ubuntu` to reach the build folder, so every request
was a 500. Adding execute-for-others on the home dir fixed it. The config I used
is in `code/nginx/`.

After this, `http://<instance-ip>/` loads the app.

## Second instance + load balancer

Once the first instance worked, I made an AMI from it (Actions -> Image -> Create
image) and launched a second instance from that image in a different AZ. PM2's
startup hook and the Nginx service both come back on boot, so the second box was
ready without much fiddling.

Target group: type Instances, HTTP on port 80, health check path `/`. Register
both instances.

Load balancer: internet-facing ALB, two AZs, HTTP listener on 80 forwarding to
the target group. Give the ALB its own security group allowing 80 in from
anywhere, then change the instance security group so port 80 only accepts traffic
from the ALB's SG. That way nobody can hit the instances directly once the LB is
up.

The ALB DNS name is what you hand to Cloudflare.

> One thing that bit me: the VPC I was given had no internet gateway and the
> subnets were on private route tables. The instances booted with no internet
> (so the bootstrap failed) and weren't reachable. I had to create an IGW, a
> public route table with a default route to it, and repoint the subnet route
> table associations. If you're using a default VPC you won't hit this.

## Cloudflare domain

Add the domain to Cloudflare and switch the registrar's nameservers to the ones
Cloudflare gives you. Once it's active, add two records:

| Type  | Name  | Target                                  | Proxy   |
|-------|-------|-----------------------------------------|---------|
| CNAME | app   | the ALB DNS name                        | Proxied |
| A     | @     | a frontend instance's public IP         | Proxied |

The CNAME points the subdomain at the load balancer; the A record maps the root
to an instance IP (a root record needs an IP, not a DNS name, which is why the LB
goes on a subdomain). Set SSL/TLS to Full and turn on Always Use HTTPS.

I didn't own a domain for the graded run, so the live URL is the raw ALB endpoint
and this section is the documented step to finish it.

## Checking it works

```bash
curl http://localhost:3000/trip                 # backend direct
curl http://<instance-ip>/api/trip              # through Nginx
curl http://<alb-dns>/api/trip                  # through the load balancer
```

Open `http://<alb-dns>/` in a browser, add a trip via the form, and it should
show up in the list. In the console the target group should show both targets
healthy.

## Security notes

* SSH locked to my IP, port 3000 never exposed publicly, instance port 80 only
  from the ALB SG.
* `MONGO_URI` lives in `.env` and is never committed. If it ever leaks, rotate
  the Atlas password.
* Atlas Network Access should be the instance IPs rather than 0.0.0.0/0 once
  you're past testing.
* Backend runs as the `ubuntu` user under PM2, not root.

## Things that went wrong (and the fixes)

* **Nginx 500 on every request** - `www-data` couldn't traverse `/home/ubuntu`.
  Fixed with `chmod o+x /home/ubuntu`.
* **Instances had no internet / weren't reachable** - private VPC with no IGW.
  Created an internet gateway, a public route table, and reassociated the subnets.
* **React build killed mid-way** - out of memory on t2.micro. Added a 2 GB swap
  file.
* **`querySrv ENOTFOUND` from Mongo** - the Atlas SRV record wasn't resolving
  because the cluster was still spinning up. Waited, restarted the backend, fine
  after that.

## Files in this repo

* `code/` - the Nginx config and example env files
* `scripts/` - the EC2 bootstrap script and the provisioning helper I used
* `architecture/` - the draw.io diagram
* `screenshots/` - app screenshots and the CLI verification output
* `DEPLOYMENT.md` - step-by-step with screenshots
* `RUNBOOK.md` - the exact commands I ran

## Tearing it down

Two EC2 instances plus an ALB cost money, so after grading delete them. Rough
order: load balancer, then target group, then the instances, then the security
groups. The commands are in [RUNBOOK.md](RUNBOOK.md).
