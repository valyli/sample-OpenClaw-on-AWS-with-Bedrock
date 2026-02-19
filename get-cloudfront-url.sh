#!/bin/bash
# 获取 CloudFront 访问地址

REGION="${1:-us-west-2}"

# 查找最新的 openclaw stack
STACK_NAME=$(aws cloudformation list-stacks \
  --region $REGION \
  --query 'StackSummaries[?contains(StackName, `openclaw`) && StackStatus==`CREATE_COMPLETE`].StackName' \
  --output text | head -1)

if [ -z "$STACK_NAME" ]; then
  echo "❌ No openclaw stack found in $REGION"
  exit 1
fi

echo "Stack: $STACK_NAME"
echo ""

# 获取 CloudFront Domain
CF_DOMAIN=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --region $REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDomain`].OutputValue' \
  --output text)

# 获取 Token
TOKEN=$(aws ssm get-parameter \
  --name "/openclaw/$STACK_NAME/gateway-token" \
  --with-decryption \
  --query Parameter.Value \
  --output text \
  --region $REGION)

echo "=========================================="
echo "✅ OpenClaw CloudFront Access"
echo "=========================================="
echo ""
echo "CloudFront URL:"
echo "https://$CF_DOMAIN/?token=$TOKEN"
echo ""
echo "CloudFront Domain: $CF_DOMAIN"
echo "Token: $TOKEN"
echo ""
echo "=========================================="
