#!/bin/bash

INSTANCE_ID="i-080b4d37d5821ab22"
REGION="ap-northeast-1"

echo "=========================================="
echo "OpenClaw Status Check"
echo "=========================================="
echo ""

# 检查实例状态
echo "1. Checking EC2 instance status..."
aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --region $REGION \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text

echo ""
echo "2. Checking OpenClaw service on instance..."
aws ssm send-command \
    --instance-ids $INSTANCE_ID \
    --region $REGION \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=[
        "echo \"=== OpenClaw Service Status ===\"",
        "sudo -u ubuntu bash -c \"export XDG_RUNTIME_DIR=/run/user/1000 && systemctl --user status openclaw || echo Service not running\"",
        "echo \"\"",
        "echo \"=== OpenClaw Logs (last 20 lines) ===\"",
        "sudo -u ubuntu journalctl --user -u openclaw -n 20 --no-pager || echo No logs found",
        "echo \"\"",
        "echo \"=== Port 18789 Status ===\"",
        "sudo netstat -tlnp | grep 18789 || echo Port not listening",
        "echo \"\"",
        "echo \"=== Setup Log (last 30 lines) ===\"",
        "tail -30 /var/log/openclaw-setup.log"
    ]' \
    --output text \
    --query 'Command.CommandId'

echo ""
echo "Command sent. Wait 5 seconds for results..."
sleep 5

echo ""
echo "=========================================="
echo "Quick Fix Commands"
echo "=========================================="
echo ""
echo "If port forwarding is not working, try:"
echo ""
echo "aws ssm start-session \\"
echo "  --target $INSTANCE_ID \\"
echo "  --region $REGION \\"
echo "  --document-name AWS-StartPortForwardingSession \\"
echo "  --parameters '{\"portNumber\":[\"18789\"],\"localPortNumber\":[\"18789\"]}'"
echo ""
# Get token from SSM Parameter Store
TOKEN=$(aws ssm get-parameter \
    --name "/openclaw/openclaw-bedrock-*/gateway-token" \
    --region $REGION \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text 2>/dev/null || echo "<TOKEN_NOT_FOUND>")

echo "Then open: http://localhost:18789/?token=$TOKEN"
echo ""
echo "=========================================="
