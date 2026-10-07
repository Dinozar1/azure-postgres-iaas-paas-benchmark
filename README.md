# azure-postgres-iaas-paas-benchmark

Infrastructure and benchmark automation for an engineering thesis (Poznań
University of Technology) comparing the performance, cost and cloud-resource
utilisation of PostgreSQL on Microsoft Azure deployed as IaaS (self-managed on
a VM) and as PaaS (Azure Database for PostgreSQL Flexible Server).

Each configuration is an ephemeral, isolated environment defined in Terraform:
created for a measurement session, benchmarked with `pgbench` from a separate
client VM, and destroyed straight afterwards.

## Configuration matrix

All four run PostgreSQL 16 in `belgiumcentral` with 512 GiB of storage, under
the same `pgbench` workload (TPC-B-like, scale 1000, 25 clients).

| Environment            | Model | Compute                               | Storage                     |
|------------------------|-------|---------------------------------------|-----------------------------|
| `iaas-standard-ssd`    | IaaS  | VM `Standard_B2s_v2` (2 vCPU / 8 GiB) | Standard SSD E20, no host caching |
| `iaas-premium-ssd`     | IaaS  | VM `Standard_B2s_v2` (2 vCPU / 8 GiB) | Premium SSD P20, no host caching  |
| `paas-burstable`       | PaaS  | Flexible Server `B_Standard_B1ms`     | Premium SSD P20 (managed)   |
| `paas-general-purpose` | PaaS  | Flexible Server `GP_Standard_D2s_v3`  | Premium SSD P20 (managed)   |

The IaaS servers carry over the PostgreSQL configuration Azure applies to the
General Purpose server, so both arms run the same engine settings
(`modules/iaas-vm`, variable `postgresql_settings`).

## Layout

```
bootstrap/      one-off: storage account for remote state + "results" archive container
modules/        network, linux-vm, iaas-vm, client-vm, paas-postgres, *-environment
environments/   one thin root module per configuration, each with its own state
scripts/        benchmark orchestration, run locally over SSH to the client VM
results/        raw output per run (git-ignored except results/<env>/summary.csv)
```

## Usage

Prerequisites: Terraform >= 1.7, Azure CLI (logged in), Python 3, and the SSH
key `~/.ssh/id_rsa_pgbench`. `bootstrap/` must have been applied once. Copy
`terraform.tfvars.example` to `terraform.tfvars` in the environment and set
`admin_source_ip` to your current public IP (`curl ifconfig.me`).

A whole measurement session is one command (run it inside tmux or screen):

```sh
scripts/run-session.sh <env> <repetitions> [--phase pilot|main]
```

It sets `admin_source_ip`, applies the environment, waits for cloud-init,
loads the data, burns in, runs the repetitions back to back and tears the
environment down. On any error, Ctrl+C, SIGTERM or SIGHUP a trap runs
`teardown.sh --force`, so nothing is left running. Runs are marked `pilot`
unless `--phase main` is given; only `main` runs make the final dataset.

The same steps by hand:

```sh
terraform -chdir=environments/<env> init
terraform -chdir=environments/<env> apply
scripts/init-db.sh <env>                 # pgbench -i -s 1000, once per environment
scripts/run-benchmark.sh <env> --burn-in # burn-in (>= 60 min), then the first measured run
scripts/run-benchmark.sh <env>           # each further repetition
scripts/teardown.sh <env>                # collect metrics, archive results, terraform destroy
```

`teardown.sh` must be what ends every session: Azure Monitor metrics are
readable only while the resources exist, so it collects them before
destroying anything, and refuses to destroy while required metric columns of
the latest run are still empty.

## Methodology

The experimental design — why each SKU, disk size and parameter was chosen,
burst credits as a confounding factor, the statistical plan, and the findings
of the sanity checks — is documented in [CLAUDE.md](CLAUDE.md) (in Polish).
