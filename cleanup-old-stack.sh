#!/bin/bash

REGION="ap-northeast-1"
STACK_NAME="openclaw-bedrock-1771426336"

echo "=========================================="
echo "Cleanup Old OpenClaw Deployment"
echo "=========================================="
echo ""
echo "This will delete:"
echo "  - CloudFormation stack: $STACK_NAME"
echo "  - ALB: openclaw-alb"
echo "  - Target Group: openclaw-tg"
echo "  - Security Groups: openclaw-alb-sg"
echo "  - SSM Parameters"
echo ""
read -p "Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Aborted"
    exit 0
fi

echo ""
echo "Step 1: Deleting manually created ALB resources..."

# Delete ALB
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "openclaw-alb" \
    --region $REGION \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null)

if [ "$ALB_ARN" != "None" ] && [ -n "$ALB_ARN" ]; then
    echo "Deleting ALB: $ALB_ARN"
    aws elbv2 delete-load-balancer \
        --load-balancer-arn $ALB_ARN \
        --region $REGION
    echo "Waiting for ALB to be deleted..."
    sleep 30
fi

# Delete Target Group
TG_ARN=$(aws elbv2 describe-target-groups \
    --names "openclaw-tg" \
    --region $REGION \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null)

if [ "$TG_ARN" != "None" ] && [ -n "$TG_ARN" ]; then
    echo "Deleting Target Group: $TG_ARN"
    aws elbv2 delete-target-group \
        --target-group-arn $TG_ARN \
        --region $REGION
fi

# Delete ALB Security Group
ALB_SG=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=openclaw-alb-sg" \
    --region $REGION \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null)

if [ "$ALB_SG" != "None" ] && [ -n "$ALB_SG" ]; then
    echo "Deleting ALB Security Group: $ALB_SG"
    aws ec2 delete-security-group \
        --group-id $ALB_SG \
        --region $REGION 2>/dev/null || echo "Will be deleted with stack"
fi

echo ""
echo "Step 2: Deleting CloudFormation stack..."
aws cloudformation delete-stack \
    --stack-name $STACK_NAME \
    --region $REGION

echo "Waiting for stack deletion (this may take 5-10 minutes)..."
aws cloudformation wait stack-delete-complete \
    --stack-name $STACK_NAME \
    --region $REGION

echo ""
echo "Step 3: Cleaning up SSM parameters..."
aws ssm delete-parameter \
    --name "/openclaw/$STACK_NAME/gateway-token" \
    --region $REGION 2>/dev/null || echo "Parameter already deleted"

echo ""
echo "=========================================="
echo "✅ Cleanup Complete!"
echo "=========================================="
echo ""
echo "You can now deploy a fresh stack with:"
echo "./deploy.sh"
echo ""
