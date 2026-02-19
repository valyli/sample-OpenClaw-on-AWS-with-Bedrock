#!/bin/bash

# 不要在遇到错误时立即退出，我们需要手动处理错误
set +e

echo "=========================================="
echo "Add CloudFront to OpenClaw"
echo "=========================================="
echo ""

# 获取参数
read -p "Enter your OpenClaw stack name (default: openclaw-bedrock-*): " STACK_NAME
STACK_NAME=${STACK_NAME:-$(aws cloudformation list-stacks --region ap-northeast-1 --query 'StackSummaries[?contains(StackName, `openclaw-bedrock`) && StackStatus==`CREATE_COMPLETE`].StackName' --output text | head -1)}

read -p "Enter region (default: ap-northeast-1): " REGION
REGION=${REGION:-"ap-northeast-1"}

echo ""
echo "Using stack: $STACK_NAME in $REGION"
echo ""

# 获取实例信息
INSTANCE_ID=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
    --output text)

VPC_ID=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query 'Reservations[0].Instances[0].VpcId' \
    --output text)

SUBNET_ID=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query 'Reservations[0].Instances[0].SubnetId' \
    --output text)

echo "Instance ID: $INSTANCE_ID"
echo "VPC ID: $VPC_ID"
echo "Subnet ID: $SUBNET_ID"
echo ""

# 创建或获取 ALB 安全组
echo "Creating or getting ALB Security Group..."
ALB_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=openclaw-alb-sg" "Name=vpc-id,Values=$VPC_ID" \
    --region $REGION \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null)

if [ "$ALB_SG_ID" = "None" ] || [ -z "$ALB_SG_ID" ]; then
    echo "Creating new security group..."
    ALB_SG_ID=$(aws ec2 create-security-group \
        --group-name "openclaw-alb-sg" \
        --description "OpenClaw ALB Security Group" \
        --vpc-id $VPC_ID \
        --region $REGION \
        --query 'GroupId' \
        --output text)
    
    aws ec2 authorize-security-group-ingress \
        --group-id $ALB_SG_ID \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 \
        --region $REGION
else
    echo "Using existing security group: $ALB_SG_ID"
fi

echo "ALB Security Group: $ALB_SG_ID"
echo ""

# 更新实例安全组，允许 ALB 访问
INSTANCE_SG=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
    --output text)

echo "Adding ALB access to instance security group..."
aws ec2 authorize-security-group-ingress \
    --group-id $INSTANCE_SG \
    --protocol tcp \
    --port 18789 \
    --source-group $ALB_SG_ID \
    --region $REGION 2>/dev/null || echo "Rule already exists"

# 获取不同 AZ 的子网（ALB 需要至少2个不同 AZ）
echo "Finding subnets in different AZs..."
SUBNETS_JSON=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --region $REGION \
    --query 'Subnets[*].[SubnetId,AvailabilityZone]' \
    --output json)

# 提取不同 AZ 的子网
SUBNET1=$(echo $SUBNETS_JSON | jq -r '.[0][0]')
AZ1=$(echo $SUBNETS_JSON | jq -r '.[0][1]')
SUBNET2=$(echo $SUBNETS_JSON | jq -r '.[] | select(.[1] != "'$AZ1'") | .[0]' | head -1)

if [ -z "$SUBNET2" ]; then
    echo "❌ Error: Only found subnets in one AZ. Creating second subnet..."
    
    # 获取 VPC CIDR
    VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --region $REGION --query 'Vpcs[0].CidrBlock' --output text)
    
    # 获取可用的 AZ
    AVAILABLE_AZS=$(aws ec2 describe-availability-zones --region $REGION --query 'AvailabilityZones[?State==`available`].ZoneName' --output text)
    AZ_ARRAY=($AVAILABLE_AZS)
    
    # 选择不同的 AZ
    for az in "${AZ_ARRAY[@]}"; do
        if [ "$az" != "$AZ1" ]; then
            NEW_AZ=$az
            break
        fi
    done
    
    # 创建新子网
    SUBNET2=$(aws ec2 create-subnet \
        --vpc-id $VPC_ID \
        --cidr-block "10.0.3.0/24" \
        --availability-zone $NEW_AZ \
        --region $REGION \
        --query 'Subnet.SubnetId' \
        --output text)
    
    # 关联到公网路由表
    ROUTE_TABLE=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=route.destination-cidr-block,Values=0.0.0.0/0" \
        --region $REGION \
        --query 'RouteTables[0].RouteTableId' \
        --output text)
    
    if [ "$ROUTE_TABLE" = "None" ] || [ -z "$ROUTE_TABLE" ]; then
        echo "⚠️  No public route table found, using main route table"
        ROUTE_TABLE=$(aws ec2 describe-route-tables \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --region $REGION \
            --query 'RouteTables[0].RouteTableId' \
            --output text)
    fi
    
    echo "Using route table: $ROUTE_TABLE"
    
    aws ec2 associate-route-table \
        --route-table-id $ROUTE_TABLE \
        --subnet-id $SUBNET2 \
        --region $REGION
    
    echo "✅ Created subnet $SUBNET2 in $NEW_AZ"
fi

echo "Using subnets: $SUBNET1 (AZ: $AZ1), $SUBNET2"
echo ""

# 创建 ALB
echo "Creating Application Load Balancer..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "openclaw-alb" \
    --region $REGION \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>&1)

# 检查是否返回错误（ALB 不存在）
if echo "$ALB_ARN" | grep -q "LoadBalancerNotFound\|An error occurred"; then
    echo "Creating new ALB..."
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name "openclaw-alb" \
        --subnets $SUBNET1 $SUBNET2 \
        --security-groups $ALB_SG_ID \
        --region $REGION \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text 2>&1)
    
    if echo "$ALB_ARN" | grep -q "An error occurred"; then
        echo "❌ Error creating ALB: $ALB_ARN"
        exit 1
    fi
    echo "ALB created: $ALB_ARN"
elif [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; then
    echo "Creating new ALB..."
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name "openclaw-alb" \
        --subnets $SUBNET1 $SUBNET2 \
        --security-groups $ALB_SG_ID \
        --region $REGION \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text)
    echo "ALB created: $ALB_ARN"
else
    echo "Using existing ALB: $ALB_ARN"
fi

# 等待 ALB 变为可用状态
echo "Waiting for ALB to become active..."
MAX_WAIT=180  # 最多等待3分钟
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    ALB_STATE=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns $ALB_ARN \
        --region $REGION \
        --query 'LoadBalancers[0].State.Code' \
        --output text)
    
    if [ "$ALB_STATE" = "active" ]; then
        echo "✅ ALB is now active!"
        break
    fi
    
    echo "  Status: $ALB_STATE (waited ${WAIT_COUNT}s)..."
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 10))
done

if [ "$ALB_STATE" != "active" ]; then
    echo "⚠️  ALB is still not active after ${MAX_WAIT}s, but continuing..."
fi

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --region $REGION \
    --query 'LoadBalancers[0].DNSName' \
    --output text)

echo "ALB DNS: $ALB_DNS"
echo ""

# 创建目标组
echo "Creating Target Group..."
TG_ARN=$(aws elbv2 describe-target-groups \
    --names "openclaw-tg" \
    --region $REGION \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null)

if [ "$TG_ARN" = "None" ] || [ -z "$TG_ARN" ]; then
    echo "Creating new target group..."
    TG_ARN=$(aws elbv2 create-target-group \
        --name "openclaw-tg" \
        --protocol HTTP \
        --port 18789 \
        --vpc-id $VPC_ID \
        --health-check-path "/" \
        --region $REGION \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text)
else
    echo "Using existing target group: $TG_ARN"
fi

# 注册实例
echo "Registering instance to target group..."
aws elbv2 register-targets \
    --target-group-arn $TG_ARN \
    --targets Id=$INSTANCE_ID \
    --region $REGION 2>/dev/null || echo "Instance already registered"

# 创建监听器
echo "Creating listener..."
LISTENER_ARN=$(aws elbv2 describe-listeners \
    --load-balancer-arn $ALB_ARN \
    --region $REGION \
    --query 'Listeners[0].ListenerArn' \
    --output text 2>/dev/null)

if [ "$LISTENER_ARN" = "None" ] || [ -z "$LISTENER_ARN" ]; then
    aws elbv2 create-listener \
        --load-balancer-arn $ALB_ARN \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn=$TG_ARN \
        --region $REGION
    echo "Listener created"
else
    echo "Listener already exists"
fi

echo ""
echo "✅ ALB setup complete!"

# 创建 CloudFront 分配
echo ""
echo "Creating CloudFront Distribution..."

CALLER_REF=$(date +%s)
CF_CONFIG=$(cat <<EOF
{
  "CallerReference": "$CALLER_REF",
  "Comment": "OpenClaw Distribution",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "ALBOrigin",
        "DomainName": "$ALB_DNS",
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "OriginProtocolPolicy": "http-only"
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "ALBOrigin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
      "CachedMethods": {
        "Quantity": 2,
        "Items": ["GET", "HEAD"]
      }
    },
    "ForwardedValues": {
      "QueryString": true,
      "Cookies": {"Forward": "all"},
      "Headers": {"Quantity": 1, "Items": ["*"]}
    },
    "MinTTL": 0,
    "DefaultTTL": 0,
    "MaxTTL": 0,
    "TrustedSigners": {"Enabled": false, "Quantity": 0}
  }
}
EOF
)

CF_ID=$(aws cloudfront create-distribution \
    --distribution-config "$CF_CONFIG" \
    --region us-east-1 \
    --query 'Distribution.Id' \
    --output text)

CF_DOMAIN=$(aws cloudfront get-distribution \
    --id $CF_ID \
    --query 'Distribution.DomainName' \
    --output text)

echo ""
echo "=========================================="
echo "✅ CloudFront Setup Complete!"
echo "=========================================="
echo ""
echo "CloudFront Domain: $CF_DOMAIN"
echo "Status: Deploying (15-20 minutes)"
echo ""
echo "Get your token:"
echo "aws ssm get-parameter --name /openclaw/$STACK_NAME/gateway-token --with-decryption --query Parameter.Value --output text --region $REGION"
echo ""
echo "Access URL (after CloudFront deploys):"
echo "https://$CF_DOMAIN/?token=<YOUR_TOKEN>"
echo ""
echo "Check CloudFront status:"
echo "aws cloudfront get-distribution --id $CF_ID --query 'Distribution.Status' --output text"
echo ""
echo "=========================================="
