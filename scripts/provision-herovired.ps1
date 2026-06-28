# =============================================================================
# TravelMemory provisioning for the Hero Vired training account (ap-south-1)
# Tailored to the existing VPC after public networking was created.
#
# Prereqs already done:
#   - SSH key pair "travelmemory-key" (travelmemory-key.pem saved locally)
#   - Internet Gateway + public route table on vpc-069f6125bcf517236
#   - Subnets subnet-0e3626b847755c1a0 (az-a) and subnet-0217c47e865fde87b (az-b) are public
#
# Before running:
#   - Put your real Atlas string in secrets.env (git-ignored)
#   - Have an active session:  $env:AWS_PROFILE="herovired"
#
# Run from the repo root:  pwsh -File scripts/provision-herovired.ps1
# =============================================================================
$ErrorActionPreference = "Stop"
$env:AWS_PROFILE = "herovired"
$env:AWS_PAGER   = ""

# ---- Fixed environment values (discovered earlier) ----
$REGION   = "ap-south-1"
$VPC      = "vpc-069f6125bcf517236"
$SUBA     = "subnet-0e3626b847755c1a0"   # ap-south-1a (public)
$SUBB     = "subnet-0217c47e865fde87b"   # ap-south-1b (public)
$AMI      = "ami-0326c8c1e2d6bf78c"      # Ubuntu 22.04 LTS
$KEY      = "travelmemory-key"
$ITYPE    = "t2.micro"
$PROJECT  = "travelmemory"

# ---- 1. Read the Atlas URI from the git-ignored secrets file ----
if (-not (Test-Path "secrets.env")) { throw "secrets.env not found. Create it with MONGO_URI=..." }
$mongoLine = Select-String -Path "secrets.env" -Pattern '^\s*MONGO_URI\s*=' | Select-Object -First 1
if (-not $mongoLine) { throw "MONGO_URI not found in secrets.env" }
$MONGO_URI = ($mongoLine.Line -replace '^\s*MONGO_URI\s*=\s*', '').Trim().Trim('"')
if ($MONGO_URI -eq "" -or $MONGO_URI -like "*PASTE_YOUR*") { throw "Please set a real MONGO_URI in secrets.env" }

# ---- 2. Generate the user-data file (git-ignored *.local.*) with the secret injected ----
$template = Get-Content "scripts/user-data.sh" -Raw
$ud = $template -replace '(?m)^MONGO_URI=.*$', ("MONGO_URI=`"" + $MONGO_URI + "`"")
# Normalize to LF for Linux cloud-init
$ud = $ud -replace "`r`n", "`n"
$udPath = "scripts/user-data.local.sh"
[System.IO.File]::WriteAllText((Resolve-Path .).Path + "\" + $udPath, $ud)
Write-Host "Generated $udPath"

# ---- 3. Security groups ----
$MYIP = (Invoke-RestMethod -Uri "https://checkip.amazonaws.com").Trim()
Write-Host "Your public IP: $MYIP"

$ALB_SG = (aws ec2 create-security-group --group-name "$PROJECT-alb-sg" --description "TravelMemory ALB" --vpc-id $VPC --query "GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 80  --cidr 0.0.0.0/0 | Out-Null
aws ec2 authorize-security-group-ingress --group-id $ALB_SG --protocol tcp --port 443 --cidr 0.0.0.0/0 | Out-Null
Write-Host "ALB SG: $ALB_SG"

$EC2_SG = (aws ec2 create-security-group --group-name "$PROJECT-ec2-sg" --description "TravelMemory EC2" --vpc-id $VPC --query "GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 22 --cidr "$MYIP/32" | Out-Null
# Port 80 open so both the ALB and the assignment's direct A-record-to-EC2 work
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 80 --cidr 0.0.0.0/0 | Out-Null
Write-Host "EC2 SG: $EC2_SG"

# ---- 4. Launch two instances ----
function New-Instance($name, $subnet) {
  aws ec2 run-instances --image-id $AMI --instance-type $ITYPE --key-name $KEY `
    --security-group-ids $EC2_SG --subnet-id $subnet --associate-public-ip-address `
    --user-data ("file://" + $udPath) `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name}]" `
    --query "Instances[0].InstanceId" --output text
}
$INST1 = (New-Instance "$PROJECT-1" $SUBA)
$INST2 = (New-Instance "$PROJECT-2" $SUBB)
Write-Host "Instances: $INST1 , $INST2"

# ---- 5. Target group ----
$TG = (aws elbv2 create-target-group --name "$PROJECT-tg" --protocol HTTP --port 80 --vpc-id $VPC `
        --health-check-path "/" --target-type instance --query "TargetGroups[0].TargetGroupArn" --output text)
Write-Host "Target group: $TG"

Write-Host "Waiting for instances to reach running state..."
aws ec2 wait instance-running --instance-ids $INST1 $INST2
aws elbv2 register-targets --target-group-arn $TG --targets "Id=$INST1" "Id=$INST2" | Out-Null

# ---- 6. Application Load Balancer + listener ----
$ALB = (aws elbv2 create-load-balancer --name "$PROJECT-alb" --subnets $SUBA $SUBB `
         --security-groups $ALB_SG --scheme internet-facing --type application --ip-address-type ipv4 `
         --query "LoadBalancers[0].LoadBalancerArn" --output text)
aws elbv2 create-listener --load-balancer-arn $ALB --protocol HTTP --port 80 `
  --default-actions "Type=forward,TargetGroupArn=$TG" | Out-Null
$ALB_DNS = (aws elbv2 describe-load-balancers --load-balancer-arns $ALB --query "LoadBalancers[0].DNSName" --output text)

# ---- 7. Collect public IPs ----
$IP1 = (aws ec2 describe-instances --instance-ids $INST1 --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
$IP2 = (aws ec2 describe-instances --instance-ids $INST2 --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

Write-Host "============================================================"
Write-Host " Provisioning complete."
Write-Host "   Instance 1: $INST1  ($IP1)"
Write-Host "   Instance 2: $INST2  ($IP2)"
Write-Host "   ALB DNS (Cloudflare CNAME target): $ALB_DNS"
Write-Host "   Target group: $TG"
Write-Host "   SG: ALB=$ALB_SG  EC2=$EC2_SG"
Write-Host "------------------------------------------------------------"
Write-Host " Save these IDs for teardown. Bootstrap takes a few minutes."
Write-Host " Check targets:"
Write-Host "   aws elbv2 describe-target-health --target-group-arn $TG --query 'TargetHealthDescriptions[].TargetHealth.State' --output text"
Write-Host "============================================================"

# Persist resource IDs locally for later verification/teardown (git-ignored)
@"
INST1=$INST1
INST2=$INST2
IP1=$IP1
IP2=$IP2
ALB_ARN=$ALB
ALB_DNS=$ALB_DNS
TG_ARN=$TG
ALB_SG=$ALB_SG
EC2_SG=$EC2_SG
IGW=igw-01c42e3b53ac06084
RT=rtb-0fcfa859da184d360
"@ | Out-File -Encoding ascii "deploy-output.local.txt"
Write-Host "Resource IDs written to deploy-output.local.txt"
