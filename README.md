# Terraform AWS ECS Infrastructure

Terraform configuration for deploying containerized applications to AWS ECS Fargate with RDS PostgreSQL.

## Architecture

```
Internet --> CloudFront (HTTPS) --> Internal ALB (HTTP) --> ECS Containers (port 8080)
                                                                |
                                                          RDS PostgreSQL
```

Two identical environments (staging and prod) are created, each with its own VPC, database, ECS cluster, and service.

## Directory Structure

```
terraform/
├── backend.tf              # S3 state storage
├── main.tf                 # Creates staging + prod environments
├── providers.tf            # AWS provider (~> 5.0)
├── locals.tf               # Shared variables (bastion IP whitelist)
└── module/
    ├── environment/        # Orchestrator - wires everything together
    ├── network/            # VPC, subnets, security groups, bastion
    ├── database/           # RDS PostgreSQL
    ├── cluster/            # ECS cluster, ALB, CloudFront, autoscaling
    └── service/            # ECS task definition + service
```

## How the Pieces Fit Together

### Root (`terraform/main.tf`)

The entry point creates two instances of the `environment` module:

```hcl
module "staging" {
  source = "./module/environment"
  name   = "staging"
}

module "prod" {
  source = "./module/environment"
  name   = "prod"
}
```

The `name` variable flows down and is used everywhere to name and tag resources.

### Network Module

Creates the foundational networking:

- **VPC** with `10.0.0.0/16` CIDR across 3 availability zones (us-west-2a/b/c)
- **5 subnet tiers**: public, private, intra, database, and elasticache — each with different CIDR sizes
- **NAT Gateway** (single, for cost savings) so private subnets can reach the internet
- **Security groups** controlling traffic: bastion SG, private SG, database SG (only port 5432 from private SG), elasticache SG
- **Bastion host** (t3a.micro) in a public subnet for SSH access. SSH key stored in SSM Parameter Store

Uses the `terraform-aws-modules/vpc/aws` community module.

### Database Module

Creates an **RDS PostgreSQL 17.2** instance:

- Instance type: `db.t4g.micro`
- 50GB storage with autoscaling up to 100GB
- Lives in database subnets (not publicly accessible)
- Password: random 32-char string stored in SSM Parameter Store at `/{env}/database/password`

### Cluster Module

The most complex module:

- **ECS Cluster** with Container Insights enabled
- **Capacity providers** using spot `t3a.medium` instances (cost optimization)
- **Auto Scaling Groups** (min 1, max 5) with CPU-based autoscaling targeting 50%
- **Internal ALB** in private subnets — default action returns 404
- **CloudFront distribution** providing public HTTPS access via a VPC origin

Traffic flow: **Internet -> CloudFront (HTTPS) -> Internal ALB (HTTP) -> ECS containers**

### Service Module

Deploys the actual application container:

- **Task definition**: 256 CPU / 512MB memory, container port 8080, image from ECR
- **ECS Service** with spot capacity provider strategy
- **Target group + listener rule** routing `/*` to the container
- **3 IAM roles**: execution (pulls images, reads secrets), task (app permissions), service (ALB integration)
- **Secrets** loaded from SSM Parameter Store at runtime
- **CloudWatch Logs** with 7-day retention

## Variable Flow

```
Root (name, bastion_ingress)
  -> Environment (orchestrator)
    -> Network (VPC, subnets, security groups)
      outputs: vpc_id, subnets, security_groups
        -> Database (uses DB subnets + DB security group)
        -> Cluster (uses private subnets + private security group)
          outputs: cluster_arn, listener_arn, cloudfront_domain
            -> Service (uses cluster, listener, VPC)
```

## Resource Dependency Chain

```
VPC + Subnets
  -> Security Groups
    -> RDS (in DB subnets, behind DB SG)
    -> ECS Cluster + ASG (in private subnets, behind private SG)
      -> ALB (in private subnets)
        -> CloudFront (public edge)
          -> ECS Service + Task Definition (routes through ALB)
```

## Key Patterns

- **Module composition**: The `environment` module orchestrates all others, passing outputs from one as inputs to the next
- **Dynamic resources with `for_each`**: Cluster module creates launch templates, ASGs, and capacity providers from a map — adding a new capacity provider type is just adding a map entry
- **Secrets management**: SSM Parameter Store parameters are created with placeholder values. Fill in real values after `terraform apply`. ECS injects them at container start
- **State storage**: `backend.tf` stores Terraform state in S3 for team collaboration

## GitHub Actions

### `terraform.yaml`

Runs on PRs and pushes to main:

1. **check**: `terraform fmt -check`, `init`, `validate`
2. **plan**: generates and uploads a plan artifact
3. **apply**: (main branch only, requires `prod` environment approval) applies the saved plan

## Supporting Scripts

### `deploy.sh`

Deployment script that:

1. Runs database migrations via a one-off ECS task (using `goose`)
2. Waits for the migration task to complete and checks its exit code
3. Forces a new deployment of the ECS service
4. Waits for the service to stabilize

### `makefile`

Build and deploy targets:

- `build-image` / `build-image-push` / `build-image-pull`: Docker image lifecycle via ECR
- `build-image-promote`: Tags and pushes an image for a specific environment
- `deploy`: Runs `deploy.sh` with AWS environment variables

## Review Findings

Assessment of the Terraform code against best practices. The architecture and traffic flow are sound, and the module decomposition follows standard patterns. However, there are issues to address before using this for production workloads.

### What's Good

- Module decomposition (network/database/cluster/service) is a natural, conventional split
- Lock file (`.terraform.lock.hcl`) is committed
- Community modules used for VPC and RDS (`terraform-aws-modules/*`)
- Dynamic `for_each` on capacity providers is a solid pattern
- Secrets stored in SSM Parameter Store rather than in code

### Critical for Production

1. **No state locking** — `backend.tf` has no `dynamodb_table`. Concurrent `terraform apply` runs will corrupt state. Needs:
   ```hcl
   dynamodb_table = "terraform-locks"
   encrypt        = true
   ```

2. **Database is not production-safe** (`terraform/module/database/main.tf`):
   - `skip_final_snapshot = true` — data lost on destroy
   - No `deletion_protection`
   - No `storage_encrypted = true`
   - No `backup_retention_period` (defaults to 1 day)
   - No `multi_az` — single point of failure
   - `db.t4g.micro` is hardcoded and tiny

3. **Database module has no outputs** — nothing exposes the DB endpoint or connection info. Other modules can't reference it programmatically.

4. **No Terraform version constraint** — `providers.tf` pins the AWS provider but there's no `required_version` for Terraform itself. Different versions can produce incompatible state.

### Structural Issues

5. **The `environment` module is a pass-through** — it hardcodes values (AZs, CIDR, port 8080, image name) and calls 4 other modules without true abstraction. Options:
   - Expose those as variables on the environment module
   - Or flatten it — call the modules directly from root with explicit values

6. **Hardcoded values everywhere** — region, AZs, CIDR blocks, instance types, port numbers, and image repository name are buried in module code rather than exposed as variables. Can't reuse for a different project without editing module internals.

7. **Security group duplication** — `terraform/module/network/security_group.tf` defines 4 nearly identical security groups that could be a single `for_each` loop.

### Security Concerns

8. **All security groups allow unrestricted egress** (`rule = "all-all"`) — production should restrict outbound traffic to known destinations.

9. **ALB deletion protection is off**. EBS volumes use `gp2` instead of `gp3` (same cost, better performance).

10. **Variable typing is loose** — `capacity_providers = map(any)` should be a proper `map(object({...}))` so Terraform catches misconfigurations at plan time.

## Post-Apply Setup

After `terraform apply`, you need to:

1. **Fill SSM parameters** with real values:
   - `/{env}/service/google-client-id`
   - `/{env}/service/google-client-secret`
   - `/{env}/service/goose-dbstring`
   - `/{env}/service/postgres-url`
2. **Push a container image** to ECR tagged with the environment name
3. **Configure OAuth** redirect URL with the CloudFront distribution domain
# terraform-lab
