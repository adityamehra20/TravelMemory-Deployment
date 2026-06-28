# Deployment Runbook — What YOU run, what to screenshot

This automates the deployment as far as possible. The steps requiring your
authenticated AWS session and a browser (SSO login, console screenshots,
Cloudflare) must be done by you — they cannot be automated from an assistant.

## A. One-time local setup

1. **Install AWS CLI v2** (Windows):
   ```powershell
   winget install -e --id Amazon.AWSCLI
   ```
   Open a new terminal, then verify: `aws --version`.

2. **Configure SSO** against your portal `https://herovired-devops.awsapps.com/start`:
   ```powershell
   aws configure sso
   # SSO start URL: https://herovired-devops.awsapps.com/start
   # SSO region:    (the region shown in the portal, e.g. us-east-1)
   # Pick your account + role, give the profile a name, default region, output=json
   ```
   Then log in (opens a browser for you to authenticate with MFA):
   ```powershell
   aws sso login --profile <your-profile>
   $env:AWS_PROFILE = "<your-profile>"
   aws sts get-caller-identity        # confirms you are authenticated
   ```
   > Type your credentials/MFA directly in the browser — never share them here.

## B. Provision the infrastructure

1. Edit [scripts/user-data.sh](scripts/user-data.sh) → set your real `MONGO_URI`.
2. Edit [scripts/provision-aws.sh](scripts/provision-aws.sh) → set `REGION`,
   `KEY_NAME` (an existing EC2 key pair), and `AMI_ID` (command to find it is in
   the file).
3. Run it from a Bash shell (Git Bash or WSL):
   ```bash
   cd /c/Users/adity/TravelMemory-Deployment
   bash scripts/provision-aws.sh
   ```
   It prints the **ALB DNS name** at the end — save it for Cloudflare.

## C. Cloudflare (browser)

1. Add your domain to Cloudflare and switch nameservers at your registrar.
2. DNS records:
   - **CNAME** `app` → `<ALB_DNS_NAME>` (Proxied)
   - **A** `@` → `<EC2_PUBLIC_IP of the frontend instance>` (Proxied)
3. SSL/TLS → **Full** (or Full strict) + **Always Use HTTPS**.

## D. Screenshots to capture (save into ./screenshots)

| File | Where | What to show |
|------|-------|--------------|
| `01-ec2-instance.png`  | EC2 → Instances | Both instances **running** + public IPs |
| `02-dependencies.png`  | SSH terminal | `node -v`, `nginx -v`, `pm2 -v` |
| `03-backend-pm2.png`   | SSH terminal | `pm2 status` + `curl localhost:3000/trip` |
| `04-backend-env.png`   | SSH terminal | `backend/.env` (redact the password) |
| `05-frontend-build.png`| SSH terminal | `npm run build` success |
| `06-nginx.png`         | Browser | App at `http://<EC2_IP>/` |
| `07-target-group.png`  | EC2 → Target Groups | Both targets **healthy** |
| `08-alb.png`           | Browser | App at `http://<ALB_DNS>/` |
| `09-cloudflare-dns.png`| Cloudflare → DNS | CNAME → ALB and A → EC2 IP |
| `10-live-domain.png`   | Browser | App at `https://<your-domain>` |
| `11-architecture.png`  | draw.io | Exported diagram PNG |

## E. Publish to GitHub

```powershell
cd C:\Users\adity\TravelMemory-Deployment
git add screenshots/
git commit -m "Add deployment screenshots"
git push
```

## F. Teardown (avoid charges when done / graded)

```bash
# Delete in reverse order: listener/ALB, target group, instances, security groups
aws elbv2 delete-load-balancer --load-balancer-arn <ALB_ARN> --region <REGION>
aws elbv2 delete-target-group  --target-group-arn  <TG_ARN>  --region <REGION>
aws ec2 terminate-instances --instance-ids <ID1> <ID2> --region <REGION>
# After instances terminate, delete the two security groups.
```
