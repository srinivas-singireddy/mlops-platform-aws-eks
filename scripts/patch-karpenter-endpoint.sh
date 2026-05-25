#!/bin/bash
# Run after terraform apply on cluster, before git push to deploy repo

ENDPOINT=$(aws eks describe-cluster \
  --name mlops-lab \
  --region eu-central-1 \
  --profile mlops-platform \
  --query 'cluster.endpoint' \
  --output text)

DEPLOY_REPO="../mlops-platform-deploy"
FILE="$DEPLOY_REPO/apps/karpenter/application.yaml"

sed -i '' "s|clusterEndpoint:.*|clusterEndpoint: \"${ENDPOINT}\"|" "$FILE"

echo "✅ Patched clusterEndpoint to: $ENDPOINT"
echo "👉 Now commit and push mlops-platform-deploy before applying platform"