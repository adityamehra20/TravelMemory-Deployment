# Runbook

The actual commands I ran, in order. The bits that need a browser (AWS SSO login,
console screenshots, Cloudflare) can't be scripted, so those are manual.

## Local setup

Install the AWS CLI on Windows:

```powershell
winget install -e --id Amazon.AWSCLI
```

Open a fresh terminal and check `aws --version`. Then configure SSO against the
portal:

```powershell
aws configure sso
# start URL: https://herovired-devops.awsapps.com/start
# pick the account + role, name the profile, region ap-south-1, output json
```

Log in (this opens a browser for MFA - type credentials there, not in any tool):

```powershell
aws sso login --profile herovired
$env:AWS_PROFILE = "herovired"
aws sts get-caller-identity
```

One gotcha on Windows: each new PowerShell needs the PATH refreshed and the pager
turned off, otherwise the CLI hangs on long output:

```powershell
$env:Path=[Environment]::GetEnvironmentVariable("Path","Machine")+";"+[Environment]::GetEnvironmentVariable("Path","User")
$env:AWS_PROFILE="herovired"
$env:AWS_PAGER=""
```

## Provisioning

Two scripts do the heavy lifting:

* `scripts/user-data.sh` - the EC2 bootstrap (installs everything, configures the
  backend, builds the frontend, wires up Nginx). Edit the `MONGO_URI` at the top
  before using it.
* `scripts/provision-herovired.ps1` - what I actually ran. It reads the Mongo URI
  from `secrets.env`, creates the security groups, launches two instances,
  creates the target group and the load balancer, and prints the resource IDs.

The generic Bash version is `scripts/provision-aws.sh` if you'd rather run it from
Git Bash or WSL.

If a VPC has no internet gateway (mine didn't), the instances boot with no network
and the bootstrap fails. Create an IGW, a public route table with
`0.0.0.0/0 -> igw`, associate the subnets with it, and turn on auto-assign public
IP. Then relaunch or re-run the bootstrap over SSH.

## Cloudflare

In the browser:

1. Add the domain, switch nameservers at the registrar.
2. DNS records: CNAME `app` -> ALB DNS (proxied), A `@` -> a frontend instance IP
   (proxied).
3. SSL/TLS set to Full, turn on Always Use HTTPS.

## Screenshots to grab

Save these into `screenshots/`:

| File | Where | What |
|------|-------|------|
| 01-ec2-instance.png | EC2 console | instances running + IPs |
| 02-dependencies.png | SSH | node/nginx/pm2 versions |
| 03-backend-pm2.png | SSH | pm2 status + curl localhost:3000/trip |
| 04-backend-env.png | SSH | backend/.env (blur the password) |
| 05-frontend-build.png | SSH | npm run build finishing |
| 06-nginx.png | browser | app at the instance IP |
| 07-target-group.png | EC2 console | both targets healthy |
| 08-alb.png | browser | app at the ALB DNS |
| 09-cloudflare-dns.png | Cloudflare | the two DNS records |
| 10-live-domain.png | browser | app over HTTPS |
| 11-architecture.png | draw.io | exported diagram |

## Push to GitHub

```powershell
cd C:\Users\adity\TravelMemory-Deployment
git add screenshots/
git commit -m "Add deployment screenshots"
git push
```

## Teardown

Delete in reverse order so nothing's still referenced:

```bash
aws elbv2 delete-load-balancer --load-balancer-arn <ALB_ARN>
aws elbv2 delete-target-group  --target-group-arn  <TG_ARN>
aws ec2 terminate-instances --instance-ids <ID1> <ID2>
# once the instances are gone, delete the two security groups
```

For my run those IDs are in `SUBMISSION.txt` / `screenshots/VERIFICATION.txt`.
