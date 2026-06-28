#!/usr/bin/env bash
# =============================================================================
# TravelMemory - AWS provisioning via AWS CLI
# Creates: security groups, 2 EC2 instances (auto-bootstrapped), a target group,
# and an internet-facing Application Load Balancer.
#
# PREREQUISITES
#   1. AWS CLI v2 installed.
#   2. Authenticated session, e.g. via SSO:
#         aws configure sso          # one-time setup
#         aws sso login --profile <your-profile>
#         export AWS_PROFILE=<your-profile>
#   3. Edit the CONFIG section below (key pair name, region, Mongo URI in user-data.sh).
#
# Run:  bash scripts/provision-aws.sh
# =============================================================================
set -euo pipefail

# ------------------------------- CONFIG (EDIT) -------------------------------
REGION="us-east-1"
KEY_NAME="your-key-pair"          # an existing EC2 key pair name in this region
INSTANCE_TYPE="t2.micro"
# Ubuntu 22.04 LTS AMI (amd64). Find current one for your region with:
#   aws ec2 describe-images --owners 099720109477 \
#     --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
#     --query 'reverse(sort_by(Images,&CreationDate))[:1].ImageId' --output text --region $REGION
AMI_ID="ami-xxxxxxxxxxxxxxxxx"
PROJECT="travelmemory"
USER_DATA_FILE="scripts/user-data.sh"
# -----------------------------------------------------------------------------

echo ">> Using region $REGION"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$REGION")
echo ">> Default VPC: $VPC_ID"

# Subnets across two AZs (required by the ALB)
mapfile -t SUBNETS < <(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId' \
  --output text --region "$REGION" | tr '\t' '\n')
SUBNET_1="${SUBNETS[0]}"
SUBNET_2="${SUBNETS[1]}"
echo ">> Subnets: $SUBNET_1 , $SUBNET_2"

# --- Security group for the ALB (public 80/443) ---
ALB_SG=$(aws ec2 create-security-group --group-name "${PROJECT}-alb-sg" \
  --description "TravelMemory ALB SG" --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text --region "$REGION")
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION"
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0 --region "$REGION"
echo ">> ALB SG: $ALB_SG"

# --- Security group for instances (80 from ALB only, 22 from your IP) ---
MY_IP=$(curl -s https://checkip.amazonaws.com)
EC2_SG=$(aws ec2 create-security-group --group-name "${PROJECT}-ec2-sg" \
  --description "TravelMemory EC2 SG" --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text --region "$REGION")
aws ec2 authorize-security-group-ingress --group-id "$EC2_SG" \
  --protocol tcp --port 22 --cidr "${MY_IP}/32" --region "$REGION"
aws ec2 authorize-security-group-ingress --group-id "$EC2_SG" \
  --protocol tcp --port 80 --source-group "$ALB_SG" --region "$REGION"
echo ">> EC2 SG: $EC2_SG (SSH from ${MY_IP}/32, HTTP from ALB only)"

# --- Launch two instances with the bootstrap user-data ---
launch_instance () {
  local name="$1" subnet="$2"
  aws ec2 run-instances \
    --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$EC2_SG" \
    --subnet-id "$subnet" --associate-public-ip-address \
    --user-data "file://${USER_DATA_FILE}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${name}}]" \
    --query 'Instances[0].InstanceId' --output text --region "$REGION"
}
INSTANCE_1=$(launch_instance "${PROJECT}-1" "$SUBNET_1")
INSTANCE_2=$(launch_instance "${PROJECT}-2" "$SUBNET_2")
echo ">> Instances: $INSTANCE_1 , $INSTANCE_2 (bootstrapping...)"

# --- Target group ---
TG_ARN=$(aws elbv2 create-target-group --name "${PROJECT}-tg" \
  --protocol HTTP --port 80 --vpc-id "$VPC_ID" \
  --health-check-path "/" --target-type instance \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION")
echo ">> Target group: $TG_ARN"

echo ">> Waiting for instances to enter running state..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_1" "$INSTANCE_2" --region "$REGION"
aws elbv2 register-targets --target-group-arn "$TG_ARN" \
  --targets Id="$INSTANCE_1" Id="$INSTANCE_2" --region "$REGION"

# --- Application Load Balancer + listener ---
ALB_ARN=$(aws elbv2 create-load-balancer --name "${PROJECT}-alb" \
  --subnets "$SUBNET_1" "$SUBNET_2" --security-groups "$ALB_SG" \
  --scheme internet-facing --type application --ip-address-type ipv4 \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION")
aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN" --region "$REGION" >/dev/null

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text --region "$REGION")

echo "============================================================"
echo " Provisioning complete."
echo "   ALB DNS (use for Cloudflare CNAME): $ALB_DNS"
echo "   Instance 1: $INSTANCE_1"
echo "   Instance 2: $INSTANCE_2"
echo " It takes a few minutes for user-data bootstrap + health checks."
echo " Check targets:  aws elbv2 describe-target-health --target-group-arn $TG_ARN --region $REGION"
echo "============================================================"
