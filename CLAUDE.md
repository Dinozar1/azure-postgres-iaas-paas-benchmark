# Kontekst projektu: praca inżynierska — IaaS vs PaaS dla PostgreSQL na Azure

## Dane formalne
- Autor: Szymon Tomczak, nr albumu 160399
- Kierunek: Teleinformatyka, studia I stopnia (inżynierskie), Wydział Informatyki i Telekomunikacji, Politechnika Poznańska
- Promotor: dr hab. inż. Sławomir Hanczewski
- Termin obrony: orientacyjnie luty (rok do potwierdzenia — w `main.tex` obecnie ustawione `\ppyear{2027}`)
- Praca pisana w LaTeX/Overleaf, szablon `ppfcmthesis` (nieoficjalny szablon PP)

## Tytuł pracy
PL: Analiza porównawcza wydajności, kosztów i wykorzystania zasobów chmurowych w relacyjnych systemach bazodanowych w modelach IaaS oraz PaaS
EN: Comparative analysis of performance, costs, and utilization of cloud resources in relational database systems in IaaS and PaaS models

## Oficjalny opis z USOS (wiążący, nie do zmiany)
> Celem pracy inżynierskiej jest przeprowadzenie kompleksowej analizy porównawczej relacyjnych systemów bazodanowych wdrażanych w chmurze obliczeniowej w modelach Infrastructure as a Service (IaaS) oraz Platform as a Service (PaaS).
> W ramach części badawczej zostaną zaprojektowane i zautomatyzowane dwa warianty środowisk, z wykorzystaniem podejścia Infrastructure as Code (IaC). Pierwszy z nich opierać się będzie na samodzielnej konfiguracji bazy danych na maszynach wirtualnych (z uwzględnieniem wpływu warstwy dyskowej na wydajność), natomiast drugi wykorzysta chmurowe usługi zarządzane.
> Głównym elementem pracy jest przeprowadzenie testów obciążeniowych obu architektur w celu zebrania kluczowych metryk, takich jak operacje wejścia/wyjścia na sekundę (IOPS), opóźnienia oraz wykorzystanie zasobów obliczeniowych (CPU/RAM). Zebrane dane posłużą do identyfikacji wad i zalet obu systemów oraz wykonania analizy efektywności finansowej, łączącej wydajność z kosztami utrzymania.

Terminologia w pracy ma być spójna z tym opisem (np. "efektywność finansowa", nie "kosztowa").

## Stos technologiczny
- Chmura: Microsoft Azure, budżet $100 (grant uczelniany)
- Baza danych: PostgreSQL
- IaC: Terraform
- Benchmark: pgbench (wbudowany w PostgreSQL, workload domyślny tpcb-like)
- Wymóg promotora: żadnych wniosków z pojedynczego pomiaru — wyniki wyłącznie jako średnia ± przedział ufności

## Macierz eksperymentu (4 konfiguracje, jeden typ obciążenia)
1. IaaS: VM `Standard_D2s_v5` (2 vCPU / 8 GB) + Standard SSD E10 (128 GB)
2. IaaS: VM `Standard_D2s_v5` (2 vCPU / 8 GB) + Premium SSD P10 (128 GB)
3. PaaS: PostgreSQL Flexible Server, tier Burstable B1ms
4. PaaS: PostgreSQL Flexible Server, tier General Purpose D2s

Uzasadnienie: warianty 1-2 pokazują wpływ warstwy dyskowej (rozdz. 2.4 pracy), warianty 3-4 pokazują kompromis tańszy/wolniejszy vs droższy/wydajniejszy w modelu zarządzanym.

## Architektura testowa
- **Osobna mała VM-klient** (np. `Standard_B2s`) uruchamia pgbench — celowo odseparowana od serwera bazy, żeby nie zaburzać pomiaru CPU/RAM serwera (kluczowa metryka z USOS)
- Ta sama VM-klient używana dla wszystkich 4 konfiguracji

## Parametry pgbench (ustalone)
- Scale factor: **1000** (~15 GB bazy — celowo > 8 GB RAM serwera, żeby wymusić realne I/O na dysk zamiast operowania z cache)
- Warm-up: 2 min, nieliczone do wyników
- Pomiar właściwy: 12 min → `pgbench -c 25 -j 2 -T 720 -P 60 -l`
- Klienci: `-c 25 -j 2`
- Reset stanu: `VACUUM ANALYZE` po każdym powtórzeniu w obrębie tej samej konfiguracji; pełna reinicjalizacja (`pgbench -i -s 1000`) tylko przy zmianie konfiguracji

## Plan statystyczny
1. Pilotaż: 5 przebiegów na każdą z 4 konfiguracji → policz odchylenie standardowe TPS/latencji
2. Na tej podstawie wylicz wymaganą liczbę powtórzeń N dla sensownego przedziału ufności (spodziewane 15-25)
3. Randomizacja kolejności konfiguracji i pory dnia pomiarów (rozłożone na różne dni — argument na zmienność chmury w czasie)
4. Raportowanie: średnia ± CI, nigdy pojedyncze liczby

## Budżet
Realny koszt obliczeniowy przy efemerycznych środowiskach (stawianych na czas testu i niszczonych zaraz po) to raczej kilkanaście-kilkadziesiąt dolarów, nie $100. Główne ryzyko: zapomnienie o `terraform destroy` — automatyzacja niszczenia zasobów jest priorytetem.

## Struktura repozytorium Terraform
Nazwa repo: `azure-postgres-iaas-paas-benchmark`

```
azure-postgres-iaas-paas-benchmark/
├── README.md
├── .gitignore                  # *.tfstate, *.tfvars z sekretami, .terraform/
├── bootstrap/                  # jednorazowo: Storage Account pod remote state
│   └── main.tf
├── modules/
│   ├── network/                 # VNet, subnet, NSG — wspólne
│   ├── iaas-vm/                 # VM + parametryzowany typ dysku
│   ├── paas-postgres/           # Flexible Server + parametryzowany tier
│   └── client-vm/               # mała VM do pgbencha
├── environments/
│   ├── iaas-standard-ssd/
│   ├── iaas-premium-ssd/
│   ├── paas-burstable/
│   └── paas-general-purpose/
│       (każdy: main.tf wołający moduły + client-vm, variables.tf, terraform.tfvars, backend.tf)
├── scripts/
│   ├── init-db.sh               # pgbench -i -s 1000
│   ├── run-benchmark.sh         # warm-up 2min + pomiar 12min + vacuum
│   └── collect-results.sh
└── .github/workflows/
    └── run-benchmark.yml         # opcjonalnie: automatyzacja
```

Ważne: **stan Terraforma (`.tfstate`) NIE trafia do Git** — backend `azurerm` (kontener w osobnym Storage Account), nie plik w repo. Każda z 4 konfiguracji w `environments/` ma własny, izolowany stan (łatwiej odpalić `destroy` na jednym wariancie bez ryzyka dla pozostałych).

Storage Account pod remote state: `sttfstatepgbench01` (nazwa robocza, do sprawdzenia dostępności — musi być globalnie unikalna w Azure).

## Struktura pracy (LaTeX, Overleaf)
`main.tex` → `\input{chapters/...}`:
1. `01-wstep.tex` — Wstęp (cel, pytanie badawcze/teza, zakres, struktura pracy)
2. `02-przeglad-technologii.tex` — Podstawy teoretyczne (IaaS/PaaS, IaC/Terraform, PostgreSQL, metryki, metodologia)
3. `03-projekt-srodowiska.tex` — Projekt środowiska badawczego i automatyzacja wdrożenia
4. `04-metodyka.tex` — Scenariusze badawcze, metodyka pomiarowa, model kosztowy
5. `05-wyniki.tex` — Analiza wyników, utylizacji zasobów, efektywności kosztowej
6. `06-podsumowanie.tex` — Podsumowanie i wnioski końcowe
7. `zalacznik.tex` — link do repo zamiast wklejania kodu

Rozdziały 3-4 pisane na bieżąco podczas budowy infrastruktury (Faza 1/3/4 planu), rozdział 2 równolegle z Fazą 1 (nie zależy od infry).

## Plan działania (fazy)
- **Faza 0 — ZAMKNIĘTA**: projekt eksperymentu (ten dokument to jej wynik)
- **Faza 1 — W TRAKCIE**: budowa modułów Terraform (bootstrap, network, iaas-vm, paas-postgres, client-vm, environments)
- Faza 2 (równolegle z 1): pisanie rozdziału 2
- Faza 3: pilotaż (5×4 przebiegi) → wyliczenie N
- Faza 4: właściwe pomiary (N×4, randomizacja)
- Faza 5: analiza wyników + rozdział 5
- Faza 6: rozdział 6 (wnioski)
- Faza 7: redakcja, poprawki promotora, złożenie w APD

## Zasady pracy
- Przy modyfikacji plików zawsze podawaj pełną, gotową do wklejenia zawartość pliku (nie tylko diff/fragment).
- Terraform ma być zrobiony porządnie: remote state, moduły parametryzowane, automatyczne `destroy` po teście — to element odróżniający pracę "zbliżoną do naukowej" od zwykłego postawienia serwera.