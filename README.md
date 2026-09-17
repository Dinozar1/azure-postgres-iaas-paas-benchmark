# Azure PostgreSQL: IaaS vs PaaS Benchmark

Repozytorium wspierające pracę inżynierską *"Analiza porównawcza wydajności, kosztów i wykorzystania zasobów chmurowych w relacyjnych systemach bazodanowych w modelach IaaS oraz PaaS"* (Politechnika Poznańska, Wydział Informatyki i Telekomunikacji).

Kod automatyzuje wdrożenie i benchmarking czterech konfiguracji PostgreSQL na Microsoft Azure:

| # | Model | Konfiguracja |
|---|-------|--------------|
| 1 | IaaS | `Standard_D2s_v5` + Standard SSD E10 (128 GB) |
| 2 | IaaS | `Standard_D2s_v5` + Premium SSD P10 (128 GB) |
| 3 | PaaS | PostgreSQL Flexible Server — Burstable B1ms |
| 4 | PaaS | PostgreSQL Flexible Server — General Purpose D2s |

## Wymagania

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.7
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), zalogowane (`az login`)
- Aktywna subskrypcja Azure z uprawnieniami do tworzenia zasobów
- `psql` / `pgbench` — opcjonalnie, do lokalnego debugowania (benchmark właściwy uruchamia się zdalnie, z osobnej VM-klienta)

## Struktura repozytorium

.
├── bootstrap/ # jednorazowo: Storage Account pod remote state Terraforma
├── modules/
│ ├── network/ # VNet, subnet, NSG — wspólne dla wszystkich wariantów
│ ├── iaas-vm/ # VM + parametryzowany typ dysku (IaaS)
│ ├── paas-postgres/ # Flexible Server + parametryzowany tier (PaaS)
│ └── client-vm/ # VM-klient do uruchamiania pgbench
├── environments/
│ ├── iaas-standard-ssd/
│ ├── iaas-premium-ssd/
│ ├── paas-burstable/
│ └── paas-general-purpose/
├── scripts/ # inicjalizacja bazy i uruchamianie testów pgbench
└── .github/workflows/ # (opcjonalnie) automatyzacja CI



Każda konfiguracja w `environments/` ma **własny, izolowany stan Terraforma** — pozwala to na niezależne `apply`/`destroy` pojedynczego wariantu bez ryzyka dla pozostałych.

## Uruchomienie

### 1. Bootstrap (jednorazowo)

Tworzy Storage Account do przechowywania stanu Terraforma (remote backend, poza repozytorium):

```bash
cd bootstrap
terraform init
terraform apply
```

### 2. Wdrożenie wybranej konfiguracji

```bash
cd environments/iaas-standard-ssd   # lub inny wariant
terraform init
terraform apply
```

### 3. Uruchomienie benchmarku

```bash
./scripts/init-db.sh <adres-serwera-bazy>        # jednorazowo dla danej konfiguracji: pgbench -i -s 1000
./scripts/run-benchmark.sh <adres-serwera-bazy>   # warm-up 2 min + pomiar 12 min + VACUUM
./scripts/collect-results.sh                      # zbiera logi/wyniki lokalnie
```

### 4. Zniszczenie zasobów (kluczowe dla budżetu)

```bash
terraform destroy
```

> **Uwaga:** budżet projektu to $100 (grant uczelniany). Pozostawiona na noc maszyna `Standard_D2s_v5` lub instancja PaaS General Purpose potrafi zauważalnie nadgryźć budżet. Zawsze uruchamiaj `terraform destroy` natychmiast po zakończeniu pomiarów danej konfiguracji.

## Plan eksperymentu

Pełny opis metodyki (scale factor, parametry pgbench, plan statystyczny, randomizacja) — patrz `CLAUDE.md` oraz rozdział 4 pracy.

## Kontekst

Repozytorium powstało jako część pracy inżynierskiej, Politechnika Poznańska, 2026/2027.