
## EKS

```sh
export CLUSTER_NAME=flask-rds-eks
export AWS_REGION=us-east-1
export CLUSTER_NS=flaskapp
export NODEGROUP_NAME=standard-workers

eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --version 1.33 \
  --nodegroup-name $NODEGROUP_NAME \
  --node-type t3.small \
  --nodes 1 \
  --nodes-min 1 \
  --nodes-max 4 \
  --managed

# verify
aws eks list-clusters

# configure the kubeconfig
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

kubectl config current-context

# create namespace
kubectl create namespace $CLUSTER_NS

```


## RDS

```sh
export DB_SUBNET_GRP_NAME=flaskapp-rds-subnet-grp
export DB_SG_NAME=pg-flaskapp-sg
export DB_NAME=pg-flaskapp
export DB_INSTANCE_CLS=db.t3.small
export DB_USERNAME=localadmin
export DB_PASSWORD=SuperSecretDBPass2731

# gt the VPC_ID associated with the cluster
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)
echo $VPC_ID

# Find private subnets (subnets without a route to an internet gateway)
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[?MapPublicIpOnLaunch==\`false\`].SubnetId" \
  --output text \
  --region $AWS_REGION)

echo $PRIVATE_SUBNET_IDS

# Create a db subnet group using only private subnet
aws rds create-db-subnet-group \
  --db-subnet-group-name $DB_SUBNET_GRP_NAME \
  --db-subnet-group-description "Private subnet group for PostgreSQL RDS" \
  --subnet-ids $PRIVATE_SUBNET_IDS \
  --region $AWS_REGION

# create the security group
aws ec2 create-security-group \
  --group-name $DB_SG_NAME \
  --description "SG for RDS" \
  --vpc-id $VPC_ID \
  --region $AWS_REGION


# Store the security group ID
DB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$DB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text \
  --region $AWS_REGION)
echo $DB_SG_ID
# sg-094c8d45d6a498604

# get the SG attached with cluster nodes:
# ++++ this does NOT work (check debug section) ++++
NODE_SG_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
  --query "cluster.resourcesVpcConfig.securityGroupIds[0]" --output text)
echo $NODE_SG_ID

# Allow cluster to reach rds on port 5432
aws ec2 authorize-security-group-ingress \
  --group-id $DB_SG_ID \
  --protocol tcp \
  --port 5432 \
  --source-group $NODE_SG_ID \
  --region $AWS_REGION

# create the PostgreSQL RDS instance in the private subnet group
aws rds create-db-instance \
  --db-instance-identifier $DB_NAME \
  --db-instance-class $DB_INSTANCE_CLS \
  --engine postgres \
  --engine-version 17.6 \
  --allocated-storage 20 \
  --master-username $DB_USERNAME \
  --master-user-password $DB_PASSWORD \
  --db-subnet-group-name $DB_SUBNET_GRP_NAME \
  --vpc-security-group-ids $DB_SG_ID \
  --no-publicly-accessible \
  --backup-retention-period 0 \
  --multi-az \
  --storage-type gp3 \
  --region $AWS_REGION


aws rds wait db-instance-available \
  --db-instance-identifier $DB_NAME \
  --region $AWS_REGION

# get the rds endpoint
DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier $DB_NAME \
  --region $AWS_REGION \
  --query "DBInstances[0].Endpoint.Address" \
  --output text)

echo "RDS endpoint: $DB_ENDPOINT"
# pg-flaskapp.ccq3nwlgmksx.us-east-1.rds.amazonaws.com

# store DB creds in k8s secrets
kubectl create secret generic rds-postgres-secret \
  --from-literal=host=$DB_ENDPOINT \
  --from-literal=username=$DB_USERNAME \
  --from-literal=password=$DB_PASSWORD \
  --from-literal=port=5432
```

### test db
Verify networking, SG rules, subnets, and DNS are correct.
```sh
# run a temporary pod with psql installed:
kubectl run psql-client --image=postgres:17 --restart=Never -- sh -c "sleep 3600"

# exec into the pod
# kubectl exec -it psql-client -- bash
kubectl exec -it psql-client -- env DB_ENDPOINT=$DB_ENDPOINT DB_USER=$DB_USERNAME DB_PASS=$DB_PASSWORD bash

# from inside the pod run:
# note: the prompt will have changed to `root@psql-client:/# `
psql -h $DB_ENDPOINT -U $DB_USERNAME -d postgres

# or simply:
PGPASSWORD="$DB_PASS" psql -h "$DB_ENDPOINT" -U "$DB_USER" -d postgres


\l

# above we set: DB_NAME = pg-flaskapp
# also, used in `aws rds describe-db-instances --db-instance-identifier $DB_NAME ...`
# @TODO: investigate this:
CREATE DATABASE "pg-flaskapp";

```
We should see sth like this: 👇
```md

 List of databases
    Name     |   Owner    | Encoding | Locale Provider |   Collate   |    Ctype    |
-------------+------------+----------+-----------------+-------------+-------------+
 pg-flaskapp | localadmin | UTF8     | libc            | en_US.UTF-8 | en_US.UTF-8 |

# 👉 If this works, your networking is good.
# 🎉 Success — your EKS cluster can now reach your RDS PostgreSQL instance!
```

You can connect to the `pg-flaskapp` like so `\c pg-flaskapp`:
```sql
postgres=> \c pg-flaskapp;
psql (17.7 (Debian 17.7-3.pgdg13+1), server 17.6)
SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, compression: off, ALPN: postgresql)
You are now connected to database "pg-flaskapp" as user "localadmin".
pg-flaskapp=> 

```
If you've run **migrations** already, you should see `topics` table when you run `\dt` (assuming you're connected to `pg-flaskapp`)

### debug db connection
A connection timeout (not "connection refused") means a routing or security-group problem, not credentials.

```sh
aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $AWS_REGION

# investigate why this returns "null"?
aws eks describe-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name $NODEGROUP_NAME \
  --region $AWS_REGION \
  --query "nodegroup.resources.securityGroups"

# instead we tried this:
NODE_REAL_SG=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" \
  --output text)

echo "Node SG = $NODE_REAL_SG"

# add ingress rule on the RDS SG
# aws ec2 authorize-security-group-ingress \
#   --group-id $DB_SG_ID \
#   --protocol tcp \
#   --port 5432 \
#   --source-group $NODEGROUP_SG_ID$ \
#   --region $AWS_REGION

aws ec2 authorize-security-group-ingress \
  --group-id $DB_SG_ID \
  --protocol tcp \
  --port 5432 \
  --source-group $NODE_REAL_SG \
  --region $AWS_REGION

```

## app

```sh
# kubectl create secret generic db-secrets \
#   --from-literal=DATABASE_URL="$DB_ENDPOINT" \
#   --from-literal=SECRET_KEY="change_this_secret_later" \
#   -n $CLUSTER_NS

kubectl create secret generic db-secrets \
  --from-literal=DATABASE_URL="postgresql://$DB_USERNAME:$DB_PASSWORD@$DB_ENDPOINT:5432/$DB_NAME" \
  --from-literal=SECRET_KEY="change_this_secret_later" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  -n $CLUSTER_NS

kubectl apply -f app-config.yaml
kubectl apply -f backend.yaml

```

Getting the logs, `k logs backend-55644cbb5c-74jxq -n $NS`, we should see sth like: 👇
```md
[2025-12-04 19:49:53 +0000] [1] [INFO] Starting gunicorn 21.2.0
[2025-12-04 19:49:53 +0000] [1] [INFO] Listening at: http://0.0.0.0:8000 (1)
[2025-12-04 19:49:53 +0000] [1] [INFO] Using worker: sync
[2025-12-04 19:49:53 +0000] [7] [INFO] Booting worker with pid: 7
```
### migration

```sh
# exec into the backend pod:
kubectl exec -it backend-57f76d96f-7l6ph -n $NS -- sh

# inside the pod
chmod +x migrate.sh
./migrate.sh

```

#### migration job

```sh
kubectl delete job backend-migration -n $NS
kubectl apply -f migration-job.yaml

k logs job/backend-migration -n $NS
```

If migration job succeeds you should see 👇
```md
# k logs job/backend-migration -n $NS
Starting migrations...
INFO  [alembic.runtime.migration] Context impl PostgresqlImpl.
INFO  [alembic.runtime.migration] Will assume transactional DDL.
INFO  [alembic.runtime.migration] Running upgrade  -> 853e54f9ad49, Auto-generated migration
Checking if seed data is needed...
Data seeded successfully!
```

### debug

```sh
# e.g., if config map is not correct (e.g., DEBUG="false")
# fix cm & run:
kubectl rollout restart deploy backend -n $NS

k logs backend-5d99fdd944-hx5gg -n $NS
k exec -it backend-57f76d96f-7l6ph -n $NS -- printenv | grep DATABASE_URL

# DATABASE_URL: ""
k get secret db-secrets -n $NS -o yaml
kubectl get secret db-secrets -n $NS -o jsonpath="{.data.DATABASE_URL}" | base64 -d; echo

kubectl delete secret db-secrets -n $CLUSTER_NS
# re-create the secret with proper value for `DATABASE_URL`
kubectl rollout restart deploy backend -n $CLUSTER_NS


kubectl exec -it backend-57f76d96f-7l6ph -n $NS -- curl -I http://backend:8000

# --------------- if everything works out well: 👇
kubectl run curlpod -n $NS --rm -it --image=curlimages/curl -- sh
# curl -I http://backend:8000

curl http://backend:8000/api/topics

curl -X POST -H "Content-Type: application/json" \
     -d '{"name":"Git","description":"Git basics","slug":"git"}' \
     http://backend:8000/api/topics


```


```sh

k apply -f k8s/db-svc.yml
# <service_name>.<namespace>.svc.cluster.local

kubectl run -it --rm --restart=Never dns-test --image=tutum/dnsutils \
 -- dig postgres-db.flaskapp.svc.cluster.local


# echo 'postgresadmin' | base64
# echo 'YourStrongPassword123!' | base64
# echo 'postgresql://localadmin:SuperSecretDBPass2731@postgres-db.flaskapp.svc.cluster.local:5432/postgres' | base64

```

## clean up the resources
### DB

```sh
# --db-instance-identifier $DB_INSTANCE_IDENTIFIER \
aws rds delete-db-instance \
  --db-instance-identifier $DB_NAME \
  --skip-final-snapshot \
  --region $AWS_REGION

aws rds wait db-instance-deleted \
  --db-instance-identifier $DB_NAME \
  --region $AWS_REGION


aws rds delete-db-subnet-group \
  --db-subnet-group-name $DB_SUBNET_GRP_NAME \
  --region $AWS_REGION

aws ec2 delete-security-group \
  --group-id $DB_SG_ID \
  --region $AWS_REGION
```

### EKS

```sh
eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION

```
