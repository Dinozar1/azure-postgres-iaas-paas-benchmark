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
- Chmura: Microsoft Azure, region **Belgium Central** (`belgiumcentral`), budżet $100 (grant uczelniany, subskrypcja Azure for Students)
- Baza danych: PostgreSQL
- IaC: Terraform
- Benchmark: pgbench (wbudowany w PostgreSQL, workload domyślny tpcb-like)
- Wymóg promotora: żadnych wniosków z pojedynczego pomiaru — wyniki wyłącznie jako średnia ± przedział ufności

Region i rozmiar VM wymuszone przez realne ograniczenia subskrypcji studenckiej — pełna historia decyzji: patrz sekcja "Historia decyzji: region i rozmiar VM" niżej. W skrócie: `Poland Central` i VM `Standard_D2s_v5` (pierwotny plan) okazały się niedostępne dla tej subskrypcji; finalnie `belgiumcentral` + `Standard_B2s_v2`.

## Macierz eksperymentu (4 konfiguracje, jeden typ obciążenia)
1. IaaS: VM `Standard_B2s_v2` (2 vCPU / 8 GB) + Standard SSD E10 (128 GB)
2. IaaS: VM `Standard_B2s_v2` (2 vCPU / 8 GB) + Premium SSD P10 (128 GB)
3. PaaS: PostgreSQL Flexible Server, tier Burstable (`B_Standard_B1ms`)
4. PaaS: PostgreSQL Flexible Server, tier General Purpose (`GP_Standard_D2s_v3`)

Uzasadnienie: warianty 1-2 pokazują wpływ warstwy dyskowej (rozdz. 2.4 pracy), warianty 3-4 pokazują kompromis tańszy/wolniejszy vs droższy/wydajniejszy w modelu zarządzanym.

**Ograniczenie do opisania w Rozdziale 6:** `Standard_B2s_v2` ma model kredytowy CPU (throttling po wyczerpaniu kredytów baseline), inny niż `Standard_D2s_v5` (brak throttlingu, stały performance). Wpływa symetrycznie na oba warianty dyskowe (1 i 2), więc porównanie Standard SSD vs Premium SSD w ramach IaaS zostaje ważne — ale osłabia wprost porównanie IaaS vs PaaS (PaaS SKU nie mają tego typu throttlingu na tym poziomie), bo część różnicy w wynikach może pochodzić z modelu CPU, nie z samej architektury IaaS/PaaS. Do jawnego zaznaczenia jako threat to validity.

**Ważne:** dokładne nazwy SKU dla Flexible Server bywają zależne od regionu — zawsze zweryfikuj przed `apply`:
`az postgres flexible-server list-skus --location belgiumcentral`

## Architektura testowa
- **Osobna mała VM-klient** (`Standard_B2s_v2`) uruchamia pgbench — celowo odseparowana od serwera bazy, żeby nie zaburzać pomiaru CPU/RAM serwera (kluczowa metryka z USOS)
- Ta sama VM-klient używana dla wszystkich 4 konfiguracji

## Historia decyzji: region i rozmiar VM

Pierwotny plan (`polandcentral` + `Standard_D2s_v5`) okazał się niewykonalny na subskrypcji Azure for Students. Zdiagnozowane systematycznie (CLI: `az vm list-usage`, `az vm list-skus --all`, `az quota update`) na ~20 rozmiarach VM w ~6 regionach UE:

1. **`Standard_D2s_v5` niedostępny.** Rodzina DSv5 (i wszystkie nowsze generacje: v6, v7) ma quota = 0 na tej subskrypcji, a samoobsługowe zwiększenie (`az quota update`) kończy się `ResourceNotAvailableForOffer` — kategoryczna odmowa, nie "spróbuj ponownie". Starsze generacje (`D2s_v3`, `D2s_v4`, `D2as_v4`) mają niezerową quotę (4 vCPU), ale sam rozmiar VM jest zablokowany dla subskrypcji (`NotAvailableForSubscription`) niezależnie od quoty. Jedyny sprawdzony rozmiar dostępny **i** z niezerową quotą: `Standard_B2s_v2` (2 vCPU / 8 GB, Premium Storage capable — spełnia oryginalną specyfikację).
2. **`Poland Central` całkowicie zablokowany.** Azure Policy (`sys.regionrestriction`) na tej subskrypcji dopuszcza tylko 5 regionów: `belgiumcentral`, `francecentral`, `germanywestcentral`, `swedencentral`, `norwayeast` (ten ostatni dodatkowo access-restricted). Nie wykrywalne komendami informacyjnymi (`list-skus`/`list-usage`) — ujawnia się dopiero przy próbie realnego utworzenia zasobu.
3. **`Germany West Central` też odpadł** — dwa niezależne błędy: chwilowy brak pojemności fizycznej dla `Standard_B2s_v2` (`SkuNotAvailable`) i osobno ograniczenie Flexible Server PaaS w tym regionie ("location is restricted from performing this operation", prawdopodobnie limit dla klientów spoza EA).
4. **`Belgium Central` przeszedł testy realnym tworzeniem+kasowaniem zasobu** (VM `Standard_B2s_v2` i PaaS General Purpose) → finalny wybór.

Wniosek metodologiczny do rozdziału 3: dostępność zasobów w chmurze dla subskrypcji promocyjnych/studenckich nie jest w pełni przewidywalna z dokumentacji ani z komend informacyjnych — wymaga systematycznej, empirycznej weryfikacji (realny apply/destroy), nie tylko sprawdzenia quoty.

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
├── scripts/
│   ├── lib/common.sh              # wspólna konfiguracja (parametry pgbench, SSH, .pgpass) + helpery
│   ├── init-db.sh <env>           # pgbench -i -s 1000 (raz na środowisko, przed pierwszym run-benchmark.sh)
│   ├── run-benchmark.sh <env>     # warm-up + pomiar 12min + VACUUM ANALYZE; ściąga wyniki do results/
│   └── collect-results.sh <env>   # agreguje results/<env>/*/summary.txt → results/<env>/summary.csv
├── results/                      # (gitignored) surowe wyniki pgbench per przebieg, ściągane z VM-klienta
└── .github/workflows/             # opcjonalnie: terraform fmt -check + validate jako CI gate
```

### Jak działają `scripts/*.sh`
- Uruchamiane **lokalnie** (nie na VM), łączą się przez SSH (`~/.ssh/id_ed25519_pgbench`) do VM-klienta i tam zdalnie odpalają `pgbench`/`psql` — sama VM bazy nigdy nie jest dotykana bezpośrednio (dla IaaS: prywatny IP w tej samej podsieci; dla PaaS: publiczny FQDN Flexible Servera).
- Hasło do bazy nigdy nie trafia do argumentów `ssh`/wiersza poleceń (ryzyko re-parsowania przez zdalną powłokę) — zamiast tego skrypt zapisuje `~/.pgpass` na VM-kliencie (`chmod 600`) przed każdym uruchomieniem, `pgbench`/`psql` czytają je automatycznie.
- Kolejność użycia: `terraform apply` w danym `environments/<env>` → `init-db.sh <env>` (raz) → `run-benchmark.sh <env>` (N razy, per plan statystyczny) → `collect-results.sh <env>` (po serii przebiegów).
- Login/hasło do bazy dla PaaS pobierane z outputów Terraforma (`db_admin_login`, `db_name`, `db_fqdn`) — brak zahardkodowanych wartości mogących się rozjechać z `terraform.tfvars`. Dla IaaS `postgres`/`pgbench_db` są zahardkodowane w skrypcie zgodnie z `modules/iaas-vm/cloud-init.tpl` (tam też nie są parametryzowane).

Każda konfiguracja w `environments/` ma **własny, izolowany stan Terraforma** (backend `azurerm`, NIE Git — patrz niżej) — pozwala to na niezależne `apply`/`destroy` pojedynczego wariantu bez ryzyka dla pozostałych.

### Konwencje techniczne (ustalone podczas refaktoryzacji)
- **Tagowanie:** `locals { common_tags = { project = "thesis-iaas-paas-postgres", environment = var.environment_name } }` w modułach, gdzie ten sam blok tagów powtarzał się 2+ razy w pliku (`linux-vm`, `network`, `bootstrap`). Tam gdzie tagi występują raz — zostają inline.
- **Kompozycja modułów:** `linux-vm` to wspólny budulec dla `iaas-vm` i `client-vm` (unika duplikacji public IP + NIC + VM). `iaas-environment`/`paas-environment` to moduły spinające całe środowisko — dzięki temu pary `environments/iaas-*` i `environments/paas-*` (wcześniej bajtowo identyczne poza jedną zmienną) są teraz kilkunastolinijkowymi wrapperami.
- **Znana granica Terraforma (do wzmianki w pracy, nie do naprawy w kodzie):** blok `terraform{}`/`provider{}` musi być zadeklarowany w każdym root module osobno (bootstrap + 4 environments = 5×) — to ograniczenie narzędzia, nie przeoczenie. To samo dotyczy `backend "azurerm" {}` (nie przyjmuje zmiennych, różni się tylko `key`).
- **Formatowanie:** `terraform fmt -recursive` odpalane po większych zmianach, `terraform fmt -check -recursive` powinno zawsze wychodzić czysto.

Storage Account pod remote state: `sttfstatepgbench01` (do potwierdzenia dostępności — nazwa musi być globalnie unikalna w Azure).

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
- **Faza 1 — PRAWIE ZAMKNIĘTA**: moduły Terraform napisane, zrefaktoryzowane (base module + kompozycje), sformatowane (`fmt` czyste), zwalidowane (`terraform validate` OK na wszystkich 4 environments). `bootstrap/` zaaplikowany (remote state istnieje). `scripts/*.sh` napisane i sprawdzone składniowo/logicznie (dry-run lokalny z podstawionymi `pgbench`/`psql`), ale **jeszcze bez realnego przebiegu end-to-end** — świadomie odłożone do momentu pierwszego `terraform apply` na środowisku. Zostało: pierwszy realny `terraform apply` na jednym środowisku + pierwszy prawdziwy przebieg `init-db.sh`/`run-benchmark.sh` jako potwierdzenie end-to-end.
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