# Azure PostgreSQL: IaaS vs PaaS Benchmark

Repository supporting the engineering thesis *"Comparative analysis of performance, costs, and utilization of cloud resources in relational database systems in IaaS and PaaS models"* (Poznan University of Technology, Faculty of Computing and Telecommunication).

The code automates the deployment and benchmarking of four PostgreSQL configurations on Microsoft Azure:

| # | Model | Configuration |
|---|-------|--------------|
| 1 | IaaS | `Standard_D2s_v5` + Standard SSD E10 (128 GB) |
| 2 | IaaS | `Standard_D2s_v5` + Premium SSD P10 (128 GB) |
| 3 | PaaS | PostgreSQL Flexible Server — Burstable B1ms |
| 4 | PaaS | PostgreSQL Flexible Server — General Purpose D2s |

## Requirements

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.7
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), logged in (`az login`)
- An active Azure subscription with permissions to create resources
- `psql` / `pgbench` — optional, for local debugging (the actual benchmark runs remotely, from a separate client VM)

## Repository structure

.
├── bootstrap/ # one-time: Storage Account for Terraform remote state
├── modules/
│ ├── network/ # VNet, subnet, NSG — shared across all variants
│ ├── iaas-vm/ # VM + parameterized disk type (IaaS)
│ ├── paas-postgres/ # Flexible Server + parameterized tier (PaaS)
│ └── client-vm/ # client VM for running pgbench
├── environments/
│ ├── iaas-standard-ssd/
│ ├── iaas-premium-ssd/
│ ├── paas-burstable/
│ └── paas-general-purpose/
├── scripts/ # database initialization and pgbench test runners
└── .github/workflows/ # (optional) CI automation


Each configuration under `environments/` has its **own, isolated Terraform state** — this allows independent `apply`/`destroy` of a single variant without risk to the others.

## Usage

### 1. Bootstrap (one-time)

Creates the Storage Account used to hold Terraform state (remote backend, kept out of the repository):

```bash
cd bootstrap
terraform init
terraform apply
```

### 2. Deploy a chosen configuration

```bash
cd environments/iaas-standard-ssd   # or another variant
terraform init
terraform apply
```

### 3. Run the benchmark

```bash
./scripts/init-db.sh <db-server-address>        # once per configuration: pgbench -i -s 1000
./scripts/run-benchmark.sh <db-server-address>   # 2 min warm-up + 12 min measured run + VACUUM
./scripts/collect-results.sh                      # collects logs/results locally
```

### 4. Destroy resources (critical for the budget)

```bash
terraform destroy
```

> **Note:** the project budget is $100 (university grant). Leaving a `Standard_D2s_v5` VM or a General Purpose PaaS instance running overnight can noticeably eat into the budget. Always run `terraform destroy` immediately after finishing measurements for a given configuration.

## Context

This repository was created as part of an engineering thesis, Poznan University of Technology, 2026/2027.

