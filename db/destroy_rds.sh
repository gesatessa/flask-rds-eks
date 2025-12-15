#!/usr/bin/env bash
set -euo pipefail

INFO_FILE=".rds-info"

########################################
# Validate .rds-info exists
########################################
# if [[ ! -f "$INFO_FILE" ]]; then
#   echo "❌ ERROR: $INFO_FILE not found."
#   echo "You must run create_rds.sh first."
#   exit 1
# fi

# echo "📄 Loading metadata from $INFO_FILE..."
# source "$INFO_FILE"

########################################
# Validate required fields loaded
########################################
REQUIRED_VARS=(
  AWS_REGION
  RDS_DB_NAME
  RDS_SG_ID
  RDS_DB_SUBNET_GROUP_NAME
)

for VAR in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!VAR:-}" ]]; then
    echo "❌ ERROR: Missing required variable '$VAR' inside $INFO_FILE"
    exit 1
  fi
done

echo "============================================="
echo "        DELETING RDS RESOURCES"
echo "============================================="
echo "AWS Region:            $AWS_REGION"
echo "RDS Identifier:        $RDS_DB_NAME"
echo "RDS Security Group ID: $RDS_SG_ID"
echo "RDS Subnet Group:      $RDS_DB_SUBNET_GROUP_NAME"
echo "============================================="
echo

########################################
# 1. Delete the RDS instance
########################################
echo "🗑 Deleting RDS instance '$RDS_DB_NAME' ..."

aws rds delete-db-instance \
  --db-instance-identifier "$RDS_DB_NAME" \
  --skip-final-snapshot \
  --region "$AWS_REGION"

echo "⏳ Waiting for RDS instance to be deleted..."
aws rds wait db-instance-deleted \
  --db-instance-identifier "$RDS_DB_NAME" \
  --region "$AWS_REGION"

echo "✔️  RDS instance deleted."
echo

########################################
# 2. Delete DB Subnet Group
########################################
echo "🗑 Deleting DB Subnet Group '$RDS_DB_SUBNET_GROUP_NAME'..."

aws rds delete-db-subnet-group \
  --db-subnet-group-name "$RDS_DB_SUBNET_GROUP_NAME" \
  --region "$AWS_REGION"

echo "✔️  Subnet group deleted."
echo

########################################
# 3. Delete Security Group
########################################
echo "🗑 Deleting Security Group '$RDS_SG_ID'..."

aws ec2 delete-security-group \
  --group-id "$RDS_SG_ID" \
  --region "$AWS_REGION"

echo "✔️  Security group deleted."
echo

########################################
# 4. Cleanup metadata file
########################################
echo "🧹 Removing metadata file $INFO_FILE..."
rm -f "$INFO_FILE"

echo "============================================="
echo "     🎉 RDS teardown completed successfully!"
echo "============================================="
