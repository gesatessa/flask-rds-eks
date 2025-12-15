#!/usr/bin/env bash
set -euo pipefail

########################################
# Validate required environment variables
########################################
REQUIRED_VARS=(
  AWS_REGION
  CLUSTER_NAME
  RDS_DB_NAME
  RDS_USERNAME
  RDS_PASSWORD
  RDS_INSTANCE_CLASS        # e.g. db.t3.micro
  RDS_DB_SUBNET_GROUP_NAME  # e.g. my-db-subnet-group
  RDS_SG_NAME               # e.g. my-rds-sg
)

for VAR in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!VAR:-}" ]]; then
    echo "ERROR: Environment variable '$VAR' is not set."
    exit 1
  fi
done

########################################
# 1. Get VPC of the EKS cluster
########################################
echo "🔍 Fetching VPC ID from EKS cluster..."
VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)
echo "➡️  VPC ID: $VPC_ID"
echo

########################################
# 2. Get private subnets in this VPC
########################################
echo "🔍 Fetching private subnets..."
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[?MapPublicIpOnLaunch==\`false\`].SubnetId" \
  --output text \
  --region "$AWS_REGION")

echo "➡️  Private Subnet IDs:"
for s in $PRIVATE_SUBNET_IDS; do
  echo "   - $s"
done
echo

########################################
# 3. Create DB Subnet Group
########################################
echo "🛠 Creating DB Subnet Group '$RDS_DB_SUBNET_GROUP_NAME'..."
aws rds create-db-subnet-group \
  --db-subnet-group-name "$RDS_DB_SUBNET_GROUP_NAME" \
  --db-subnet-group-description "Private subnet group for RDS PostgreSQL" \
  --subnet-ids $PRIVATE_SUBNET_IDS \
  --region "$AWS_REGION"

echo "➡️  DB Subnet Group created."
echo

########################################
# 4. Create Security Group for RDS
########################################
echo "🛠 Creating RDS Security Group '$RDS_SG_NAME'..."
aws ec2 create-security-group \
  --group-name "$RDS_SG_NAME" \
  --description "Security group for RDS PostgreSQL" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION" >/dev/null || true

# Fetch SG ID
RDS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$RDS_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text \
  --region "$AWS_REGION")

echo "➡️  RDS Security Group ID: $RDS_SG_ID"
echo

########################################
# 5. Allow EKS Nodes to connect to RDS
########################################
echo "🔍 Fetching EKS Cluster Security Group..."

EKS_NODE_SG=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" \
  --output text)

echo "➡️  EKS Node SG: $EKS_NODE_SG"
echo

echo "🔐 Adding inbound rule: allow EKS → RDS on port 5432..."
aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --source-group "$EKS_NODE_SG" \
  --region "$AWS_REGION" || true

echo "➡️  Ingress rule added."
echo

########################################
# 6. Create the RDS PostgreSQL instance
########################################
echo "🛠 Creating PostgreSQL RDS instance '$RDS_DB_NAME'..."
aws rds create-db-instance \
  --db-instance-identifier "$RDS_DB_NAME" \
  --db-instance-class "$RDS_INSTANCE_CLASS" \
  --engine postgres \
  --engine-version 17.6 \
  --allocated-storage 20 \
  --master-username "$RDS_USERNAME" \
  --master-user-password "$RDS_PASSWORD" \
  --db-subnet-group-name "$RDS_DB_SUBNET_GROUP_NAME" \
  --vpc-security-group-ids "$RDS_SG_ID" \
  --no-publicly-accessible \
  --backup-retention-period 0 \
  --multi-az \
  --storage-type gp3 \
  --region "$AWS_REGION"

echo "⏳ Waiting for RDS instance to become available..."
aws rds wait db-instance-available \
  --db-instance-identifier "$RDS_DB_NAME" \
  --region "$AWS_REGION"

echo "🎉 RDS PostgreSQL instance is ready!"
echo

########################################
# 7. Fetch and print RDS connection details
########################################
echo "🔍 Fetching RDS endpoint..."
ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_DB_NAME" \
  --region "$AWS_REGION" \
  --query "DBInstances[0].Endpoint.Address" \
  --output text)

PORT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_DB_NAME" \
  --region "$AWS_REGION" \
  --query "DBInstances[0].Endpoint.Port" \
  --output text)

echo "============================================="
echo "            RDS CONNECTION DETAILS"
echo "============================================="
echo "DB Identifier:     $RDS_DB_NAME"
echo "Security Group ID: $RDS_SG_ID"
echo "Subnet Group:      $RDS_DB_SUBNET_GROUP_NAME"
echo
echo "Endpoint:          $ENDPOINT"
echo "Port:              $PORT"
echo
echo "🔗 Connection String:"
echo "postgresql://$RDS_USERNAME:$RDS_PASSWORD@$ENDPOINT:$PORT/postgres"
echo "============================================="
echo

echo "✅ RDS creation complete!"
