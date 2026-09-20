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
- Chmura: Microsoft Azure, region **Belgium Central** (`belgiumcentral`), budżet $100 (grant uczelniany)
- Baza danych: PostgreSQL
- IaC: Terraform
- Benchmark: pgbench (wbudowany w PostgreSQL, workload domyślny tpcb-like)
- Wymóg promotora: żadnych wniosków z pojedynczego pomiaru — wyniki wyłącznie jako średnia ± przedział ufności

Region wybrany metodą prób realnego tworzenia zasobów po tym, jak Poland Central i Germany West Central okazały się niedostępne dla tej subskrypcji — pełna historia decyzji niżej.

## Macierz eksperymentu (4 konfiguracje, jeden typ obciążenia)
1. IaaS: VM `Standard_B2s_v2` (2 vCPU / 8 GB, burstable) + Standard SSD E10 (128 GB)
2. IaaS: VM `Standard_B2s_v2` (2 vCPU / 8 GB, burstable) + Premium SSD P10 (128 GB)

   > Originally planned as `Standard_D2s_v5`. The Azure for Students subscription blocks the
   > entire D-series family here (Dsv5: quota=0, not increasable via `az quota update` —
   > `ResourceNotAvailableForOffer`; older Dsv3/v4: quota exists but size itself returns
   > `NotAvailableForSubscription`). `Standard_B2s_v2` is the confirmed-available substitute
   > with matching 2 vCPU / 8 GB spec and Premium Storage support. Trade-off: B-series uses a
   > CPU credit model (throttles to ~40% baseline once credits exhaust) — affects both disk
   > variants identically, so the Standard-vs-Premium SSD comparison stays valid; the direct
   > IaaS-vs-PaaS absolute performance comparison is weakened and should be disclosed as a
   > stated limitation in Rozdział 6. CPU utilization is already a required USOS metric, so any
   > throttling will be visible in the collected data rather than hidden.

### Decyzja: region — Belgium Central

Pierwotnie planowany Poland Central okazał się niedostępny, i to na trzech różnych poziomach
błędów napotkanych po kolei:
1. Azure Policy `sys.regionrestriction` (przypisana per-subskrypcja) ogranicza wdrożenia do listy:
   `belgiumcentral`, `francecentral`, `germanywestcentral`, `swedencentral`, `norwayeast`
   (Poland Central poza listą → `RequestDisallowedByAzure` przy realnym tworzeniu zasobu;
   komendy informacyjne typu `list-skus`/`list-usage` tego NIE wykrywają, bo nie próbują nic
   faktycznie stworzyć — trzeba testować realnym `create`).
2. Germany West Central (pierwszy kandydat z listy) — VM `Standard_B2s_v2`: `SkuNotAvailable`
   z powodu chwilowego braku pojemności fizycznej. PaaS `GeneralPurpose D2s_v3`: "location is
   restricted from performing this operation" (prawdopodobnie utrzymujące się ograniczenie
   Flexible Servera w tym regionie do klientów EA/EA Premium).
3. Belgium Central — potwierdzone działającym, realnym utworzeniem OBU zasobów (VM `B2s_v2`
   i PaaS `GeneralPurpose D2s_v3`), zweryfikowane skryptem `probe-regions.sh` (testuje kolejne
   regiony z listy realnym `create`+`delete`, nie samym listowaniem). **Finalny region: `belgiumcentral`.**

To trzeci punkt do jawnego udokumentowania w Rozdziale 3 jako ograniczenie wynikające z darmowej
subskrypcji studenckiej (obok samej zamiany VM), razem z metodą weryfikacji (realne tworzenie
zasobu jako jedyny wiarygodny test, bo dokumentacja/listy SKU nie odzwierciedlają rzeczywistych
ograniczeń danej subskrypcji).
3. PaaS: PostgreSQL Flexible Server, tier Burstable (`B_Standard_B1ms`)
4. PaaS: PostgreSQL Flexible Server, tier General Purpose (`GP_Standard_D2s_v3`)

Uzasadnienie: warianty 1-2 pokazują wpływ warstwy dyskowej (rozdz. 2.4 pracy), warianty 3-4 pokazują kompromis tańszy/wolniejszy vs droższy/wydajniejszy w modelu zarządzanym.

**Ważne:** dokładne nazwy SKU dla Flexible Server bywają zależne od regionu — zawsze zweryfikuj przed `apply`:
`az postgres flexible-server list-skus --location belgiumcentral`

## Architektura testowa
- **Osobna mała VM-klient** (`Standard_B2s_v2`) uruchamia pgbench — celowo odseparowana od serwera bazy, żeby nie zaburzać pomiaru CPU/RAM serwera (kluczowa metryka z USOS)
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
│                                # UWAGA: .terraform.lock.hcl NIE jest ignorowany —
│                                # commitowany per-environment (reprodukowalność)
├── bootstrap/                  # jednorazowo: Storage Account pod remote state
│   └── main.tf
├── modules/
│   ├── network/                 # VNet, subnet, NSG — wspólne dla wszystkich wariantów
│   ├── linux-vm/                 # BAZOWY moduł: public IP + NIC + VM (locals.common_tags)
│   ├── iaas-vm/                   # komponuje linux-vm + dysk danych + cloud-init PostgreSQL
│   ├── client-vm/                 # komponuje linux-vm + cloud-init pgbench/psql
│   ├── paas-postgres/             # Flexible Server + parametryzowany tier
│   ├── iaas-environment/          # KOMPOZYCJA: network + client-vm + iaas-vm → pełne środowisko IaaS
│   └── paas-environment/          # KOMPOZYCJA: network + client-vm + paas-postgres → pełne środowisko PaaS
├── environments/                 # każdy folder to CIENKI wrapper: terraform{}, provider{},
│   │                              # jedno wywołanie modułu *-environment, backend.tf, tfvars
│   ├── iaas-standard-ssd/
│   ├── iaas-premium-ssd/
│   ├── paas-burstable/
│   └── paas-general-purpose/
├── scripts/                      # NIEROZPOCZĘTE — init-db.sh, run-benchmark.sh, collect-results.sh
│   │                              # (planowane: wspólny scripts/lib/common.sh z parametrami benchmarku)
└── .github/workflows/             # opcjonalnie: terraform fmt -check + validate jako CI gate
```

Każda konfiguracja w `environments/` ma **własny, izolowany stan Terraforma** (backend `azurerm`, NIE Git — patrz niżej) — pozwala to na niezależne `apply`/`destroy` pojedynczego wariantu bez ryzyka dla pozostałych.

### Konwencje techniczne (ustalone podczas refaktoryzacji)
- **Tagowanie:** `locals { common_tags = { project = "thesis-iaas-paas-postgres", environment = var.environment_name } }` w modułach, gdzie ten sam blok tagów powtarzał się 2+ razy w pliku (`linux-vm`, `network`, `bootstrap`). Tam gdzie tagi występują raz — zostają inline.
- **Kompozycja modułów:** `linux-vm` to wspólny budulec dla `iaas-vm` i `client-vm` (unika duplikacji public IP + NIC + VM). `iaas-environment`/`paas-environment` to moduły spinające całe środowisko — dzięki temu pary `environments/iaas-*` i `environments/paas-*` (wcześniej bajtowo identyczne poza jedną zmienną) są teraz kilkunastolinijkowymi wrapperami.
- **Znana granica Terraforma (do wzmianki w pracy, nie do naprawy w kodzie):** blok `terraform{}`/`provider{}` musi być zadeklarowany w każdym root module osobno (bootstrap + 4 environments = 5×) — to ograniczenie narzędzia, nie przeoczenie. To samo dotyczy `backend "azurerm" {}` (nie przyjmuje zmiennych, różni się tylko `key`).
- **Formatowanie:** `terraform fmt -recursive` odpalane po większych zmianach, `terraform fmt -check -recursive` powinno zawsze wychodzić czysto.

Storage Account pod remote state: `sttfstatepgbench01` (do potwierdzenia dostępności — nazwa musi być globalnie unikalna w Azure). Wszystkie zasoby (bootstrap + 4 environments) w regionie `belgiumcentral`.

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
- **Faza 0 — ZAMKNIĘTA**: projekt eksperymentu
- **Faza 1 — W TRAKCIE**: moduły Terraform napisane, zrefaktoryzowane (base module + kompozycje), sformatowane, zwalidowane. SSH key + Azure CLI gotowe, providery zarejestrowane, subskrypcja: Azure for Students (`szymon.tomczak@student.put.poznan.pl`). NAPOTKANO i ROZWIĄZANO: (a) rodzina D-series zablokowana → `vm_size` = `Standard_B2s_v2`; (b) Poland Central i Germany West Central niedostępne dla tej subskrypcji → region = `belgiumcentral` (potwierdzone realnym `create` dla VM i PaaS GeneralPurpose, patrz sekcja "Decyzja: region" wyżej). Wszystkie 5 plików (`bootstrap/main.tf` + 4× `terraform.tfvars.example`) zaktualizowane. Zostało: wypełnić prawdziwe `terraform.tfvars` ×4 (sekrety), pierwszy realny `terraform apply`, `scripts/*.sh`.
- Faza 2 (równolegle z 1): pisanie rozdziału 2
- Faza 3: pilotaż (5×4 przebiegi) → wyliczenie N
- Faza 4: właściwe pomiary (N×4, randomizacja)
- Faza 5: analiza wyników + rozdział 5
- Faza 6: rozdział 6 (wnioski)
- Faza 7: redakcja, poprawki promotora, złożenie w APD

## Zasady pracy
- Przy modyfikacji plików zawsze podawaj pełną, gotową do wklejenia zawartość pliku (nie tylko diff/fragment).
- Terraform ma być zrobiony porządnie: remote state, moduły parametryzowane, automatyczne `destroy` po teście — to element odróżniający pracę "zbliżoną do naukowej" od zwykłego postawienia serwera.
- README i komentarze w kodzie repo — po angielsku. Sama praca (LaTeX) — po polsku.