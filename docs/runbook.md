# MLOps Platform — Operational Runbook

Quick reference for daily operations and troubleshooting.

## Daily rhythm

### Morning: bring everything up
\`\`\`bash
cd terraform/network && terraform apply
cd ../cluster && terraform apply
aws eks update-kubeconfig --name mlops-lab --region eu-central-1 --profile mlops-platform
cd ../platform && terraform apply
kubectl get nodes
\`\`\`

### Evening: tear it all down
\`\`\`bash
cd terraform/platform && terraform destroy
cd ../cluster && terraform destroy
cd ../network && terraform destroy

# Sanity check — no orphan EIPs
aws ec2 describe-addresses --profile mlops-platform --region eu-central-1 \\
  --query 'Addresses[?AssociationId==null].PublicIp' --output table
\`\`\`

## Verification commands

### After cluster apply
\`\`\`bash
kubectl get nodes
kubectl get pods -n kube-system
kubectl describe sa ebs-csi-controller-sa -n kube-system | grep role-arn
\`\`\`

### After platform apply
\`\`\`bash
kubectl get pods -n cert-manager
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl get pods -n argocd
kubectl get pods -n external-secrets
helm list -A
\`\`\`

### Important Commands

cd ~/code 
cd mlops-platform-aws-eks

git status
git add terraform/network/
git add docs/adr/0002-nat-instance-vs-gateway.md

git commit -m "<Commit message>"

git push
git tag v0.1-network
git push --tags

### AWS Commands
aws sts get-caller-identity --profile mlops-platform
aws configure --profile mlops-platform
aws configure get region --profile mlops-platform
aws configure set region eu-central-1 --profile mlops-platform
aws configure set output json --profile mlops-platform


aws sts get-caller-identity --profile mlops-platform
aws sts get-caller-identity --profile mlops-platform-aws-eks

aws configure list-profiles
cat ~/.aws/credentials
cat ~/.aws/config

aws iam list-mfa-devices --user-name USERNAME --profile mlops-platform
# Replace USERNAME with the actual IAM username you see in the ARN

grep "^\[" ~/.aws/credentials 2>/dev/null

# 2: Refers to the Standard Error (stderr) data stream. In your computer's terminal, standard output (the normal data you expect to see) is assigned the number 1, while error messages are assigned the number 2.>: This is the redirection operator. It tells the computer to take whatever data is flowing through stream 2 and point it somewhere else./dev/null: This is a special, virtual file in Unix-like operating systems known as the "null device" or the "black hole." Any data written to it is instantly and permanently destroyed by the system.

# Confirm the OIDC provider exists
aws iam list-open-id-connect-providers --profile mlops-platform

# Describe the EBS CSI driver's ServiceAccount — it should have the role annotation
kubectl describe sa ebs-csi-controller-sa -n kube-system | grep role-arn
# Expected: eks.amazonaws.com/role-arn: arn:aws:iam::...:role/mlops-lab-ebs-csi

# A quick IRSA test

kubectl run awscli-test --rm -it --restart=Never \
  --image=amazon/aws-cli \
  --serviceaccount=ebs-csi-controller-sa \
  --namespace=kube-system \
  --command -- sh
# Inside the pod:
aws sts get-caller-identity
aws s3 ls
exit

# Any dangling Elastic IPs?
aws ec2 describe-addresses --profile mlops-platform --region eu-central-1 \
  --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output table
# If you see orphan EIPs, release them:
aws ec2 release-address --allocation-id <id> --profile mlops-platform --region eu-central-1


# Any running instances?
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=mlops-platform" \
            "Name=instance-state-name,Values=running" \
  --profile mlops-platform --region eu-central-1 \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime]' --output table

# Checking if Cluster is Active
aws eks describe-cluster --name mlops-lab \
  --profile mlops-platform --region eu-central-1 \
  --query 'cluster.{Status:status,Endpoint:endpoint,Version:version}'

# Now the most useful command — read the system log from one of the failed instances:
aws ec2 get-console-output \
  --instance-id i-00a44b5d3d1d794f1 \
  --profile mlops-platform --region eu-central-1 \
  --output text > /tmp/node-console.log

# Look for the bootstrap script execution
grep -A 5 -i "bootstrap\|kubelet\|apiserver\|unreachable\|timed out\|failed" /tmp/node-console.log | tail -100



# Kubectl commands
# Helpful tip while you work
# Set up a shell alias for context awareness — useful when you have multiple Kubernetes # contexts:

# Add to your ~/.zshrc
alias k=kubectl
alias kctx='kubectl config current-context'
alias kns='kubectl config set-context --current --namespace'

# Reload: 
source ~/.zshrc


kubectl get pods -n kube-system

kubectl logs -n kube-system deployment/ebs-csi-controller -c ebs-plugin
# Look for "WebIdentityErr" or "InvalidIdentityToken"

kubectl get sa ebs-csi-controller-sa -n kube-system -o yaml | grep role-arn
# Confirm the annotation is set and the ARN matches what's in Terraform

# In another terminal
kubectl get pods --all-namespaces --field-selector=status.phase!=Succeeded
# Look for stuck pods, especially PDB-blocked ones

# Nuclear option — delete node group manually via AWS CLI
aws eks delete-nodegroup --cluster-name mlops-lab \
  --nodegroup-name default \
  --profile mlops-platform --region eu-central-1





# K9s

k9s
# Press ':' then type 'ns' to list namespaces
# Press ':' then type 'po' for pods
# Esc to navigate back, Ctrl-C to quit

# Git commands

# Assuming you've already renamed to srinivas-singireddy
cd ~/code  # or wherever you keep projects
gh repo create srinivas-singireddy/mlops-platform-aws-eks \
    --public \
    --description "Production-grade MLOps platform on AWS EKS — reference architecture with Terraform, ArgoCD, observability, and model serving" \
    --clone
cd mlops-platform-aws-eks

# Starter structure
mkdir -p terraform/{bootstrap,network,cluster,platform}
mkdir -p k8s/{apps,charts}
mkdir -p docs/adr
mkdir -p .github/workflows
touch README.md .gitignore docs/ARCHITECTURE.md docs/COST.md

# Terraform-focused gitignore
cat > .gitignore <<'EOF'
# Terraform
**/.terraform/*
*.tfstate
*.tfstate.*
*.tfplan
*.tfvars
!example.tfvars
.terraform.lock.hcl

# macOS
.DS_Store

# IDE
.vscode/
.idea/

# Secrets
*.pem
*.key
credentials.csv
EOF

git add .
git commit -m "chore: initial project structure"
git push origin main