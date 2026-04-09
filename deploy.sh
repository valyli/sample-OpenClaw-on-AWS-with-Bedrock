#!/bin/bash

set -e

echo "=========================================="
echo "OpenClaw on AWS - One-Click Deployment"
echo "=========================================="
echo ""

# 检查 AWS CLI
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI not found. Please install: https://aws.amazon.com/cli/"
    exit 1
fi

# 选择 Region
echo "Select AWS Region:"
echo "1) us-west-2 (Oregon) - Recommended"
echo "2) us-east-1 (N. Virginia)"
echo "3) eu-west-1 (Ireland)"
echo "4) ap-northeast-1 (Tokyo)"
read -p "Enter choice (1-4) or custom region: " region_choice

case $region_choice in
    1) REGION="us-west-2" ;;
    2) REGION="us-east-1" ;;
    3) REGION="eu-west-1" ;;
    4) REGION="ap-northeast-1" ;;
    *) REGION="$region_choice" ;;
esac

echo "✅ Selected region: $REGION"
echo ""

# 获取 Key Pairs
echo "Fetching EC2 key pairs in $REGION..."
KEY_PAIRS=$(aws ec2 describe-key-pairs --region $REGION --query 'KeyPairs[*].KeyName' --output text 2>/dev/null || echo "")

if [ -z "$KEY_PAIRS" ]; then
    echo "❌ No key pairs found in $REGION"
    echo "Create one at: https://console.aws.amazon.com/ec2/home?region=$REGION#KeyPairs:"
    exit 1
fi

echo "Available key pairs:"
i=1
for key in $KEY_PAIRS; do
    echo "$i) $key"
    i=$((i+1))
done

read -p "Select key pair (1-$((i-1))): " key_choice
KEY_PAIR=$(echo $KEY_PAIRS | cut -d' ' -f$key_choice)
echo "✅ Selected key pair: $KEY_PAIR"
echo ""

# 选择模型
echo "Select Bedrock Model:"
echo "1) Nova 2 Lite (default, cheapest, $0.30/$2.50 per 1M tokens)"
echo "2) Claude Sonnet 4.5 (most capable, $3/$15 per 1M tokens)"
echo "3) Claude Sonnet 4.6 (latest, $3/$15 per 1M tokens)"
echo "4) Nova Pro (balanced, $0.80/$3.20 per 1M tokens)"
echo "5) Claude Opus 4.6 (advanced reasoning)"
echo "6) Claude Haiku 4.5 (fast, $1/$5 per 1M tokens)"
echo "7) DeepSeek R1 (reasoning, $0.55/$2.19 per 1M tokens)"
echo "8) Llama 3.3 70B (open-source)"
read -p "Enter choice (1-8, default: 1): " model_choice

case ${model_choice:-1} in
    1) MODEL="global.amazon.nova-2-lite-v1:0" ;;
    2) MODEL="global.anthropic.claude-sonnet-4-5-20250929-v1:0" ;;
    3) MODEL="global.anthropic.claude-sonnet-4-20250514-v1:0" ;;
    4) MODEL="us.amazon.nova-pro-v1:0" ;;
    5) MODEL="global.anthropic.claude-opus-4-6-v1" ;;
    6) MODEL="global.anthropic.claude-haiku-4-5-20251001-v1:0" ;;
    7) MODEL="us.deepseek.r1-v1:0" ;;
    8) MODEL="us.meta.llama3-3-70b-instruct-v1:0" ;;
    *) MODEL="global.amazon.nova-2-lite-v1:0" ;;
esac
echo "✅ Selected model: $MODEL"

read -p "Instance type (default: c7g.large): " INSTANCE
INSTANCE=${INSTANCE:-"c7g.large"}

read -p "VPC Endpoints? (yes/no, default: yes): " VPC_ENDPOINTS
VPC_ENDPOINTS=${VPC_ENDPOINTS:-"yes"}
[ "$VPC_ENDPOINTS" = "yes" ] && VPC_ENDPOINTS="true" || VPC_ENDPOINTS="false"

STACK_NAME="openclaw-bedrock-$(date +%s)"

echo ""
echo "=========================================="
echo "Configuration Summary"
echo "=========================================="
echo "Region: $REGION"
echo "Stack Name: $STACK_NAME"
echo "Model: $MODEL"
echo "Instance: $INSTANCE"
echo "Key Pair: $KEY_PAIR"
echo "VPC Endpoints: $VPC_ENDPOINTS"
echo ""
read -p "Proceed with deployment? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Deployment cancelled"
    exit 0
fi

# 部署
echo ""
echo "🚀 Deploying CloudFormation stack..."
aws cloudformation create-stack \
    --stack-name $STACK_NAME \
    --template-body file://clawdbot-bedrock.yaml \
    --parameters \
        ParameterKey=OpenClawModel,ParameterValue=$MODEL \
        ParameterKey=InstanceType,ParameterValue=$INSTANCE \
        ParameterKey=KeyPairName,ParameterValue=$KEY_PAIR \
        ParameterKey=CreateVPCEndpoints,ParameterValue=$VPC_ENDPOINTS \
    --capabilities CAPABILITY_IAM \
    --region $REGION

echo ""
echo "⏳ Waiting for deployment to complete (8-10 minutes)..."
aws cloudformation wait stack-create-complete \
    --stack-name $STACK_NAME \
    --region $REGION

# 获取输出
echo ""
echo "=========================================="
echo "✅ Deployment Complete!"
echo "=========================================="
echo ""

INSTANCE_ID=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
    --output text)

CF_DOMAIN=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDomain`].OutputValue' \
    --output text)

TOKEN=$(aws ssm get-parameter \
    --name "/openclaw/$STACK_NAME/gateway-token" \
    --with-decryption \
    --query Parameter.Value \
    --output text \
    --region $REGION 2>/dev/null || echo "")

echo "📋 Access Instructions:"
echo ""

if [ -n "$CF_DOMAIN" ] && [ "$CF_DOMAIN" != "None" ]; then
    echo "🌐 CloudFront URL (Recommended - HTTPS, Secure):"
    echo "   https://$CF_DOMAIN/?token=$TOKEN"
    echo ""
    echo "   Note: CloudFront may take 15-20 minutes to fully deploy."
    echo "   Check status: aws cloudfront list-distributions --query 'DistributionList.Items[?Comment==\`OpenClaw Distribution\`].Status' --output text"
    echo ""
fi

echo "🔒 SSM Port Forwarding (Alternative - Local access):"
echo "   1. Install SSM Plugin (one-time):"
echo "      https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
echo ""
echo "   2. Run port forwarding (keep terminal open):"
echo "      aws ssm start-session --target $INSTANCE_ID --region $REGION --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"18789\"],\"localPortNumber\":[\"18789\"]}'"
echo ""
echo "   3. Open in browser:"
echo "      http://localhost:18789/?token=$TOKEN"
echo ""
echo "=========================================="
echo "🎉 Start using OpenClaw!"
echo "=========================================="
