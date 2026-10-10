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
1. IaaS: VM `Standard_B2s_v2` (2 vCPU / 8 GB) + Standard SSD E20 (512 GB)
2. IaaS: VM `Standard_B2s_v2` (2 vCPU / 8 GB) + Premium SSD P20 (512 GB)
3. PaaS: PostgreSQL Flexible Server, tier Burstable (`B_Standard_B1ms`), 512 GiB storage
4. PaaS: PostgreSQL Flexible Server, tier General Purpose (`GP_Standard_D2s_v3`), 512 GiB storage

Uzasadnienie: warianty 1-2 pokazują wpływ warstwy dyskowej (rozdz. 2.4 pracy), warianty 3-4 pokazują kompromis tańszy/wolniejszy vs droższy/wydajniejszy w modelu zarządzanym.

Konfiguracja PostgreSQL na IaaS jest przeniesiona z serwera PaaS GP (sekcja "Parytet konfiguracji PostgreSQL" niżej). Wariant IaaS na ustawieniach domyślnych świadomie **nie** jest częścią macierzy.

Poza macierzą: **eksperyment wyjaśniający** `iaas-premium-ssd-readcache` (Premium P20 z cache odczytu hosta) — sekcja "Eksperyment wyjaśniający: cache odczytu na IaaS" niżej. Nie wchodzi do głównego porównania 4 konfiguracji.

Rozmiar dysku 512 GB nie jest arbitralny — patrz sekcja "Decyzja: rozmiar dysku 512 GB" niżej. Przy pierwotnie planowanych 128 GB oba tiery mają identyczne 500 IOPS i porównanie warstwy dyskowej nie miałoby czego mierzyć.

## Decyzja: rozmiar dysku 512 GB

Azure provisionuje IOPS według progu pojemności, nie według samego tieru. Zmierzone **empirycznie na tej subskrypcji** (`az disk create` + `az disk show`, region `belgiumcentral`):

| Rozmiar | Standard SSD | Premium SSD | Stosunek IOPS |
|---|---|---|---|
| 128 GB (E10/P10) | 500 IOPS, 100 MB/s | 500 IOPS, 100 MB/s | **1,0× — identyczne** |
| 256 GB (E15/P15) | 500 IOPS, 100 MB/s | 1100 IOPS, 125 MB/s | 2,2× |
| **512 GB (E20/P20)** | **500 IOPS, 100 MB/s** | **2300 IOPS, 150 MB/s** | **4,6×** |
| 1024 GB (E30/P30) | 500 IOPS, 100 MB/s | 5000 IOPS, 200 MB/s | powyżej limitu VM |

Limity samej VM `Standard_B2s_v2` (`az vm list-skus`): **3750 IOPS / 85 MB/s** dla dysków bez cache (a dysk danych ma świadomie `caching = "None"`, żeby pomiar odzwierciedlał tier dysku, nie warstwę cache hosta).

Stąd wybór 512 GB:
- **Największy rozmiar, przy którym Premium (2300 IOPS) nie dobija do sufitu VM (3750 IOPS)** — maszyna nie maskuje różnicy między tierami. Przy 1024 GB wąskim gardłem byłaby VM (5000 > 3750), nie dysk, i porównanie straciłoby sens.
- Przy 128 GB różnica wynosiłaby 1,0× — nie byłoby czego mierzyć.
- **Uwaga dla rozdz. 5:** przy MB/s wąskim gardłem jest VM (85 MB/s), nie dysk (100–150 MB/s), więc *przepustowość sekwencyjna* wyjdzie podobna w obu wariantach. Różnica ujawni się w **IOPS i latencji** — czyli dokładnie w metrykach, które wymienia opis z USOS. Workload `tpcb-like` jest losowy i drobnotransakcyjny, więc IOPS jest tu metryką wiodącą.
- Rozmiar dysku jest **zmienną kontrolowaną**: identyczny w wariantach 1 i 2, różni się tylko tier. Parytet po stronie PaaS: `storage_mb = 524288` (512 GiB) w `modules/paas-postgres`.
- Koszt: dyski są rozliczane od pojemności provisionowanej, nie użytej, ale przy środowiskach efemerycznych to ~$0,05–0,10/h za dysk — kilka dolarów w skali całej kampanii pomiarowej.

## Bursting jako czynnik zakłócający (threat to validity, rozdz. 6)

Każdy SKU w macierzy mierzy coś na saldzie kredytów, więc wynik przebiegu zależy od stanu **sprzed** jego rozpoczęcia. Zmierzone w pierwszym przebiegu testowym (Azure Monitor, VM bazy):

- **Kredyty burst dysku: realny problem.** `Data Disk Used Burst IO Credits Percentage` rosło 0% → 9% → 17% w trakcie 12-minutowego pomiaru. Dysk startuje z pełną pulą kredytów, zużywa je pod obciążeniem i odbudowuje w bezczynności — więc pierwszy przebieg po utworzeniu środowiska mierzy dysk *burstujący*, a nie stan ustalony danego tieru.
  - **Jeden standardowy przebieg NIE drenuje puli.** ~14 min obciążenia (warm-up + pomiar) to za mało: pula wystarcza na ~30 min przy maksymalnym burście, a pierwszy test zużył 17% na 12 min.
  - **Zasada ogólna (ustalona 2026-10-07): burn-in trwa, aż wyczerpią się wszystkie pule kredytów, które pod tym obciążeniem się wyczerpują; minimum 60 min.** Uzasadnienie: mierzymy stan, który konfiguracja utrzyma **bez końca** pod tym obciążeniem. Na IaaS CPU w stanie ustalonym pracuje poniżej poziomu bazowego, więc „kredyty CPU > 0” trwa dowolnie długo, a jedyną wyczerpującą się pulą jest pula dysku; na B1ms CPU (31–38%) pracuje powyżej poziomu bazowego, więc „kredyty > 0” to stan przejściowy, a utrzymywalny jest dopiero stan po ich wyczerpaniu.
  - **Protokół `run-benchmark.sh --burn-in`** (pierwszy przebieg po `init-db.sh`): ciągły pgbench — bez warm-upu, bez `-l`, bez VACUUM, nieliczony do wyników — i **od razu, w tym samym wywołaniu**, pierwszy przebieg pomiarowy. GP: stałe **60 min** (`BURN_IN_SECONDS`) — nie ma puli, która by się wyczerpywała. Pozostałe konfiguracje: **burn-in adaptacyjny** (`burn_in_pools` w `scripts/lib/common.sh`) — pgbench startuje z limitem bezpieczeństwa **4 h** (`BURN_IN_MAX_SECONDS`), a co **5 min** (bez przerywania obciążenia) skrypt czyta pule z Azure Monitor:
    - **B1ms (`paas-burstable`), tryb `until_spent`:** `cpu_credits_remaining` zawsze się wyczerpuje — burn-in trwa, aż odczyt pokaże **≤ 1** (ten sam próg co kryterium; po wyczerpaniu kredytów metryka zatrzymuje się na 1,0, nie na 0 — poprawione 2026-10-09 po sesji 4 pilotażu).
    - **IaaS (wszystkie środowiska `iaas-*`), tryb `while_draining`:** pula dysku (`Data Disk Used Burst IO Credits Percentage`, wyczerpana przy ≥ 99) i kredyty CPU VM (`CPU Credits Remaining`, wyczerpane przy **≤ 2** od 2026-10-10 — podłoga metryki, sekcja "Kryterium ważności") — burn-in trwa, dopóki któraś z nich wciąż się wyczerpuje (zmiana w stronę wyczerpania w ostatnich 15 min większa niż 1 p.p. dla dysku / 0,5 kredytu dla CPU), aż każda będzie wyczerpana albo się ustabilizuje. Przy wyższym CPU (np. z cache odczytu) `B2s_v2` może zacząć zużywać kredyty CPU — wtedy burn-in ciągnie się do ich wyczerpania; na głównych konfiguracjach IaaS kredyty CPU w stanie ustalonym rosną, więc burn-in kończy się po ~60 min (P20 drenuje dysk po ~46 min; 35 min nie wystarczyło, sanity check `iaas-premium-ssd`).
    - Pula odczytana jako wyczerpana dostaje jeszcze **10 min** zapasu na lag metryki; burn-in kończy się po co najmniej 60 min, gdy wszystkie pule są „wyczerpane” lub „stabilne”. `meta.env` burn-inu zapisuje `BURN_IN_STOP=done|limit` i `BURN_IN_POOLS` (końcowy stan każdej puli). Log postępu burn-inu (`-P 60`, `summary.txt` w katalogu `burnin-*`) jest zachowywany i archiwizowany — to dane o fazie burstu do osobnego opisu w rozdz. 5. Między burn-inem a pomiarem nie może być bezczynności, bo właśnie w bezczynności dysk odbudowuje kredyty: E20 (500 bazowo / 600 burst) ma pulę ~180 tys. IO odnawianą tempem ~500 IO/s, więc jest pełna po ~6 min; 300 s czekania na Azure Monitor odbudowałoby ~80% puli (P20: ~30%). Dlatego raport burn-inu (tabela per minuta, `burnin-metrics.txt`) liczy się **w tle** po lagu ingestii (300 s), a wypisuje na końcu wywołania. IaaS: `Data Disk Used Burst IO Credits Percentage` obok IOPS odczytu/zapisu (i ich sumy), `Data Disk IOPS Consumed Percentage` oraz `CPU Credits Remaining` i `Percentage CPU` — przy wyższym TPS na Premium VM może dojść do granicy CPU, a `B2s_v2` ma kredyty CPU.
  - **Burn-in na wszystkich 4 konfiguracjach** — jednolity protokół, także tam, gdzie dysk nie burstuje; na B1ms drenuje kredyty CPU.
  - **Zmiany protokołu z 2026-10-08** (po sesji 1 pilotażu; uzasadnienie: przebiegi 2 i 5 tej sesji, sekcja "Pilotaż — sesja 1"):
    - **Burn-in kończy się resetem** (`TRUNCATE pgbench_history` + `VACUUM ANALYZE`, ten sam co między przebiegami) — na wszystkich konfiguracjach, także GP. Bez tego przebieg 1 startował z bazy po 60–100 min obciążenia bez VACUUM, a przebiegi 2–5 z bazy po VACUUM — dwa różne stany; do tego pierwszy, długi VACUUM (397 s) odbudowywał ~14% puli P20 tuż przed przebiegiem 2.
    - **Warm-up adaptacyjny przed każdym przebiegiem:** minimum 2 min (`WARMUP_SECONDS`), potem dalej, dopóki każda pula, którą burn-in doprowadził do wyczerpania (`BURN_IN_SPENT_POOLS` w `meta.env` burn-inu), nie zostanie znów odczytana jako wyczerpana — **odczytem z chwili po starcie warm-upu**, co jest zapasem na opóźnienie metryki (pod obciążeniem wyczerpana pula zostaje wyczerpana). Na B1ms dotyczy kredytów CPU, na IaaS puli dysku (przebieg 5 pokazał, że zwykły reset odnawia 1–3% puli); na GP nic się nie wyczerpuje, więc warm-up zostaje 2 min. Limit bezpieczeństwa 40 min (`WARMUP_MAX_SECONDS`). pgbench warm-upu zatrzymywany po PID (`warmup.pid`), bez ryzyka dla pomiaru. Czas warm-upu: `WARMUP_S` i `WARMUP_STOP=fixed|done|limit` w `meta.env`, kolumna `warmup_s` w `summary.csv`.
    - Reset po przebiegu 1 i kolejnych jest teraz krótki (VACUUM sprząta tylko 12–15 min obciążenia), a resztę odnowienia pul zjada adaptacyjny warm-up.
  - Raport burn-inu zapisuje też surowe minutowe serie wszystkich metryk z okna burn-inu (`burnin-azure-metrics.json`) — razem z logiem `-P 60` to materiał do opisu fazy burstu w rozdz. 5.
  - **PaaS: brak bezpośredniego dowodu.** Flexible Server nie publikuje metryki kredytów storage, a `cpu_credits_remaining` wypełnia się tylko na Burstable — dlatego tabela pokazuje `cpu_credits_remaining`, `cpu_percent`, `iops`, `read_iops` + `write_iops` i `disk_iops_consumed_percentage`. Odczyty idą w dużej części z cache hosta (patrz "Sanity check"), więc o obciążeniu samego dysku mówi `disk_iops_consumed_percentage`, nie `iops`. Interpretacja: IOPS najpierw powyżej ~2300 (poziom bazowy przy 512 GiB), potem spadek do niego → pula się opróżniła; IOPS od początku poniżej 2300 → dysk nie jest wąskim gardłem i bursting nie wpływa na tę konfigurację. Flexible Server nie ma też metryki latencji dysku — latencja I/O po stronie PaaS pochodzi wyłącznie z `pg_stat_io` (`track_io_timing`).
  - Per przebieg: `disk_burst_io_pct_min` (stan puli na początku okna pomiaru) i `disk_burst_io_pct_max` (na końcu) w CSV; w `meta.env` `PREV_RUN_END` (koniec poprzedniego obciążenia — przebiegu, burn-inu albo `init-db.sh`) i `IDLE_GAP_S`. Konsekwencja dla Fazy 4: *odstęp między przebiegami wpływa na stan kredytów*, więc jest raportowany (kolumna `idle_gap_s`).
- **Kredyty CPU: dużo mniej istotne, niż zakładano — zweryfikowane dla Standard SSD 128 GB i Premium 512 GB.** Na Premium P20 (sanity check 2026-10-07) kredyty CPU schodzą tylko **w czasie burstu dysku** (CPU ~46–55%, spadek ~0,17 kredytu/min); w stanie ustalonym (2300 IOPS) CPU spada do 31–36%, poniżej poziomu bazowego `B2s_v2`, i kredyty rosną. W długiej sesji z wieloma przebiegami w burście kredyty starczają na ~6 h. `Percentage CPU` na VM bazy wynosiło **~9–10%**, a `CPU Credits Remaining` **rosło** (76 → 79) w trakcie pomiaru. Obciążenie jest I/O-bound, więc model kredytowy CPU `B2s_v2` praktycznie nie działa jako ograniczenie — to koryguje wcześniejsze założenie, że throttling CPU będzie głównym zagrożeniem trafności przy zamianie `D2s_v5` → `B2s_v2`. Nadal warto to raportować, ale jako zweryfikowane (na razie dla jednej konfiguracji), nie jako domniemane.
- **VM-klient nie jest wąskim gardłem:** CPU ~3%, co potwierdza sens odseparowanej maszyny klienckiej.
- Tier Burstable Flexible Servera (wariant 3) mierzy CPU na kredytach analogicznie — do sprawdzenia przy pierwszym wdrożeniu PaaS.

`collect-results.sh` pobiera te metryki z Azure Monitor dla **okna czasowego samego pomiaru** (bez warm-upu i vacuum) i zapisuje obok wyników pgbench, żeby analiza mogła pokazać, czy dany przebieg był w stanie burstującym czy ustalonym. **Musi być uruchomiony przed `terraform destroy`** — Azure nie udostępnia metryk usuniętego zasobu. W praktyce robi to `teardown.sh` (patrz niżej), który odmawia `destroy`, dopóki wymagane kolumny metryk ostatniego przebiegu są puste. Metryki kompletne i starsze niż lag ingestii są cache'owane per przebieg (`metrics.env` + surowe minutowe serie w `azure-metrics.json`), więc ponowne `collect-results.sh` po zniszczeniu środowiska ich nie traci.

**Ważne:** dokładne nazwy SKU dla Flexible Server bywają zależne od regionu — zawsze zweryfikuj przed `apply`:
`az postgres flexible-server list-skus --location belgiumcentral`

## Pilotaż — sesja 1: `iaas-premium-ssd` (2026-10-08)

`run-session.sh iaas-premium-ssd 5` (10:04–13:34): init-db 7 min 17 s; **burn-in adaptacyjny 100 min** — pula dysku drenowała się wolniej niż w sanity checku (~1,3 p.p./min wobec ~2), wyczerpana ok. 90. minuty, kredyty CPU spadały w czasie burstu i ustabilizowały się po nim (`BURN_IN_POOLS`: dysk 100% spent, CPU 57,2 level). Dane: `results/iaas-premium-ssd/summary.csv` (faza `pilot`).

| przebieg | TPS | latencja śr. [ms] | p99 [ms] | `disk_burst_io_pct_min` | reset przed przebiegiem | `steady_state` |
|---|---|---|---|---|---|---|
| 1 | 951,4 | 26,27 | 66,6 | 100 | — (burn-in) | true |
| 2 | 1095,2 | 22,82 | 65,2 | **86** | **397 s** | **false** |
| 3 | 953,8 | 26,20 | 66,4 | 99 | 213 s | true |
| 4 | 968,2 | 25,81 | 65,6 | 100 | 210 s | true |
| 5 | 955,5 | 26,16 | 65,2 | **97** | 272 s | **false** |

Przebiegi `true` (n = 3): **TPS średnia 957,8; SD 9,1; 95% CI ±22,7 (t, df = 2)**; latencja średnia 26,09 ms, SD 0,25, 95% CI ±0,61; CPU ~38–39%, IOPS ~2350 (poziom bazowy P20), latencja dysku z Azure ~8–9 ms. Wszystkie 5 (analiza wrażliwości): TPS średnia 984,8; SD 62,0; 95% CI ±77,0. Liczby pilotażu służą wyłącznie do wyliczenia N. **Sesja przeszła według protokołu sprzed zmian z 2026-10-08 i zostaje w pilotażu w tej formie.**

- **Reset między przebiegami odnawia pulę dysku.** W czasie `TRUNCATE` + `VACUUM ANALYZE` dysk robi mniej IOPS niż bazowe 2300, więc pula się odbudowuje. Pierwszy reset po burn-inie jest długi (397 s — VACUUM sprząta martwe krotki ze 100 min burn-inu, który VACUUM nie robi) i odbudował ~14% puli: przebieg 2 mierzył dysk burstujący (IOPS 2500–3450, +15% TPS). Kolejne resety (~210–270 s) odbudowują ~1–3%; 2-minutowy warm-up nie zawsze to zjada przed pierwszym punktem metryki (przebieg 5: 97%, choć TPS bez śladu burstu). Kryterium zadziałało zgodnie z projektem — oba przebiegi oznaczone `false`.
- **Błąd w redukcji metryk (naprawiony):** dla minuty bez danych Azure zwraca brak `average`, ale `minimum` = 0,0 — przebieg 4 dostał przez to `cpu_credits_remaining_min` = 0,00 i fałszywe `false`. Redukcja liczy teraz tylko minuty z danymi i działa na zapisanej surowej serii (`azure-metrics.json`), więc poprawka objęła już zebrane przebiegi (offline, po destroy).
- **Rozstrzygnięte 2026-10-08:** (a) reset na końcu burn-inu + ponowny drenaż pul przed przebiegiem 1 — wszystkie konfiguracje; (b) adaptacyjny warm-up przed każdym przebiegiem, jednolicie (pule wyczerpane w burn-inie) — sekcja "Bursting"; (c) przebieg 5 zostaje `false`, próg bez zmian, analiza wrażliwości; (d) format statystyk: średnia, SD, 95% CI z t, podpisane.

## Pilotaż — sesja 2: `paas-general-purpose` (2026-10-08)

`run-session.sh paas-general-purpose 5` (14:03–17:08), **pierwsza sesja według protokołu z 2026-10-08**: init-db 6 min 44 s; burn-in stały 60 min (GP nie ma pul) zakończony resetem (~8 min); warm-up przed każdym przebiegiem stały 120 s. Dane: `results/paas-general-purpose/summary.csv` (faza `pilot`, `steady_state` = `n/a` — brak kryterium dla GP).

| przebieg | TPS | latencja śr. [ms] | p99 [ms] | CPU śr. | `iops` śr. | dysk % limitu |
|---|---|---|---|---|---|---|
| 1 | 1395,7 | 17,90 | 47,6 | 81% | 3718 | 76% |
| 2 | 1382,0 | 18,08 | 48,1 | 83% | 3680 | 68% |
| 3 | 1381,9 | 18,08 | 47,0 | 84% | 3705 | 68% |
| 4 | 1377,2 | 18,15 | 47,8 | 84% | 3694 | 68% |
| 5 | 1381,6 | 18,09 | 48,2 | 83% | 3697 | 70% |

Wszystkie 5 (n = 5): **TPS średnia 1383,7; SD 7,0; 95% CI ±8,7 (t, df = 4)**; latencja średnia 18,06 ms, SD 0,09, 95% CI ±0,12; p99 średnia 47,8 ms, SD 0,5, 95% CI ±0,6. Wąskie gardło jak w sanity checku: CPU (~83%), dysk na ~70% limitu. Obserwacja do analizy: w każdym przebiegu TPS z pierwszych 3 min jest o ~1,5% wyższy niż z ostatnich 3 min (np. 1404,6 → 1381,1) — mały, powtarzalny dryf wewnątrz przebiegu.

## Pilotaż — sesja 3: `iaas-standard-ssd` (2026-10-08)

`run-session.sh iaas-standard-ssd 5` (17:08–21:56): init-db 10 min 19 s; burn-in 60 min (pula E20 wyczerpana po ~35 min); **reset po burn-inie 40 min** — VACUUM ograniczony przez IOPS dysku (zapisy ~500–520 IOPS, równo na poziomie bazowym E20, więc pula się nie odnowiła); warm-upy adaptacyjne 246–555 s; wszystkie 5 przebiegów spełnia kryterium. Dane: `results/iaas-standard-ssd/summary.csv`.

| przebieg | warm-up [s] | TPS | latencja śr. [ms] | p99 [ms] | checkpointy w oknie | TPS pierwsze / ostatnie 3 min |
|---|---|---|---|---|---|---|
| 1 | 247 | 176,2 | 141,8 | 409,9 | 1 | 269 / 171 |
| 2 | 246 | 184,6 | 135,4 | 397,8 | 1 | 274 / 184 |
| 3 | 493 | 155,1 | 161,1 | 409,7 | 2 | 142 / 140 |
| 4 | 246 | 168,2 | 148,6 | 444,1 | 1 | 272 / 144 |
| 5 | 555 | 158,4 | 157,8 | 401,2 | 2 | 143 / 150 |

n = 5: **TPS średnia 168,5; SD 12,3; 95% CI ±15,2 (t, df = 4)**; latencja średnia 149,0 ms, SD 10,8, 95% CI ±13,3; p99 średnia 412,6 ms, SD 18,4, 95% CI ±22,9. CPU ~9% — czysto dyskowe ograniczenie.

- **Checkpoint dominuje rozrzut na E20** (rozstrzygnięte — sekcja "Okno pomiaru = jeden cykl checkpointu"). Checkpoint czasowy (co 10 min, ~900 MB zapisu) zabiera ~360 z ~500 IOPS dysku: odczyty spadają z ~460 do ~195 IOPS, TPS z ~330 do ~130 na ~9 min. Faza cyklu względem startu pomiaru zależy od długości warm-upu: przebiegi z długim warm-upem (493 i 555 s) zaczęły się w trakcie checkpointu i miały w oknie 2 checkpointy (155 i 158 TPS), pozostałe 1 (168–185 TPS). Rozrzut wynika więc w dużej mierze z fazy checkpointu, nie z platformy. Na P20 i GP tego efektu nie widać (checkpoint nie wyczerpuje tam budżetu I/O). Rozważany `CHECKPOINT` przed pomiarem odrzucony; zamiast niego okno 600 s = jeden cykl checkpointu.

## Pilotaż — sesja 4: `paas-burstable` (2026-10-09)

`run-session.sh paas-burstable 5` (10:57–18:22): init-db 24 min 49 s; **burn-in 240 min (limit bezpieczeństwa)** — kredyty CPU wyczerpały się ok. 214. minuty, ale metryka zatrzymała się na **1,0**, a burn-in czekał na 0 (niespójność z kryterium ≤ 1 — błąd w kodzie, poprawiony: burn-in B1ms kończy się teraz przy ≤ 1). Moment wyczerpania widać w danych: TPS ~230 → ~110, `cpu_percent` ~30% → ~90% (liczone względem przyciętej mocy). **Reset po burn-inie 61 min** — VACUUM ograniczony przez przycięte CPU (88–100%), kredyty się w tym czasie nie odnawiały. Warm-upy stałe 120 s (przez niespójność progów burn-in nie zapisał puli jako wyczerpanej), ale kredyty stały na 1,0 przez wszystkie okna pomiaru, więc **wszystkie 5 przebiegów spełnia kryterium**. Kolejne resety ~6 min. Dane: `results/paas-burstable/summary.csv`.

| przebieg | TPS | latencja śr. [ms] | p99 [ms] | CPU śr. | `iops` śr. |
|---|---|---|---|---|---|
| 1 | 119,9 | 208,3 | 1040,7 | 78% | 539 |
| 2 | 127,8 | 195,5 | 999,2 | 77% | 547 |
| 3 | 121,2 | 206,3 | 1019,3 | 81% | 494 |
| 4 | 132,8 | 188,1 | 980,2 | 77% | 546 |
| 5 | 111,3 | 224,5 | 1050,2 | 82% | 496 |

n = 5: **TPS średnia 122,6; SD 8,2; 95% CI ±10,2 (t, df = 4)**; latencja średnia 204,5 ms, SD 13,8, 95% CI ±17,2; p99 średnia 1017,9 ms, SD 28,9, 95% CI ±35,9. Obserwacja: w każdym przebiegu jedna minuta z krótkim zrywem (~190–280 TPS) w przypadkowym momencie — najpewniej kredyt odkładany i od razu zużywany w stanie wyczerpanym; to część stanu utrzymywalnego B1ms.

## Pilotaż — podsumowanie i liczba powtórzeń N (2026-10-09)

| konfiguracja | n | TPS średnia | SD | CV | N dla 95% CI ≤ ±2% / ±3% / ±5% średniej |
|---|---|---|---|---|---|
| iaas-premium-ssd | 3 | 957,8 | 9,1 | 0,95% | 4 / 3 / 3 |
| paas-general-purpose | 5 | 1383,7 | 7,0 | 0,51% | 3 / 3 / 2 |
| iaas-standard-ssd | 5 | 168,5 | 12,3 | 7,28% | 54 / 26 / 11 |
| paas-burstable | 5 | 122,6 | 8,2 | 6,67% | 46 / 22 / 10 |

N wyliczone z SD pilotażu jako najmniejsze n, przy którym t(0,975; n − 1)·SD/√n ≤ cel·średnia. Konfiguracje ograniczone przez CPU (GP) i przez dysk z zapasem I/O (P20) mają rozrzut < 1%, ograniczone przez mały budżet zasobu (E20 — checkpoint; B1ms — przycięte CPU) ~7%.
- **Rozstrzygnięte 2026-10-09:** tabela wyżej liczy przebiegi jako niezależne próby, a nimi nie są — jednostką statystyczną jest **sesja** (sekcja "Jednostka statystyczna: sesja"), więc N z tabeli opisuje tylko rozrzut wewnątrz jednej sesji i nie wyznacza liczby powtórzeń. Liczbę sesji wyznacza reguła zatrzymania (sekcja "Plan kampanii"). `CHECKPOINT` przed pomiarem odrzucony, okno 600 s (sekcja "Okno pomiaru = jeden cykl checkpointu"); osobnego ponownego pilotażu E20 nie ma — pokrywa to reguła zatrzymania.

## Kampania — runda 1 (2026-10-10)

`run-campaign.sh --last-round 1` po sesji readcache, wszystko bez przerw i z kodem 0 (`campaign/sessions.csv`). Czasy (PL): P20 02:52–05:55, E20 05:55–10:19, B1ms 10:19–17:53 (burn-in 235 min, zakończony przy kredytach ≤ 1 — przed limitem 4 h), GP 17:53–20:50. Wszystkie 20 przebiegów w stanie ustalonym. Jedna sesja na konfigurację, więc CI po sesjach jeszcze nie istnieje — poniżej średnia i SD **wewnątrz sesji**, opisowo.

| konfiguracja | TPS śr. | SD w sesji | latencja śr. [ms] | p99 [ms] | CPU | `checkpoint_aligned` | warm-up [s] |
|---|---|---|---|---|---|---|---|
| iaas-premium-ssd | 917,5 | 13,6 | 27,24 | 66,4 | 37–38% | 5/5 | 246–370 |
| iaas-standard-ssd | 177,4 | 12,0 | 141,37 | 396,9 | 11–12% | 4/5 (20%, nie „ponad 20%”) | 185–369 |
| paas-burstable | 120,0 | 12,0 | 209,73 | 950,5 | 82–90% | 5/5 | 308–495 |
| paas-general-purpose | 1343,2 | 4,7 | 18,60 | 47,1 | 84–86% | 5/5 | 120 |

- Między sesjami (pilotaż → runda 1, inny protokół, więc tylko sygnał): P20 957,8 → 917,5 (−4%), GP 1383,7 → 1343,2 (−3%), E20 168,5 → 177,4, B1ms 122,6 → 120,0.
- **E20, przebieg 1 rundy 1:** 0 checkpointów w oknie (`aligned = false`), TPS 195,8 (pierwsze 3 min 317, ostatnie 134) — okno między dwoma startami checkpointu odległymi o więcej niż 600 s. Na E20 zapis checkpointu jest ograniczony IOPS, więc realny cykl bywa dłuższy niż `checkpoint_timeout` — dokładnie przypadek przewidziany w decyzji o `checkpoint_aligned`.
- **Raport trendu w obrębie sesji (2026-10-10, tylko raport; decyzja przed rundą 2)** — `summarize.py --trend`: nachylenie MNK TPS względem numeru przebiegu (1–5), przebiegi w stanie ustalonym, 95% CI z t (df = n − 2):

| konfiguracja | pilotaż [% średniej / przebieg] | runda 1 [% średniej / przebieg] |
|---|---|---|
| iaas-premium-ssd | +0,52 (n = 3, CI obejmuje 0) | +0,61 (CI obejmuje 0) |
| paas-general-purpose | −0,24 (CI obejmuje 0) | +0,04 (CI obejmuje 0) |
| iaas-standard-ssd | −3,09 (CI obejmuje 0) | **−4,12, 95% CI [−11,25; −3,37] TPS/przebieg — wyklucza 0** |
| paas-burstable | −0,99 (CI obejmuje 0) | −2,19 (CI obejmuje 0) |

  E20 w rundzie 1: 195,8 / 182,8 / 173,4 / 169,1 / 166,1 — spadek także bez przebiegu 1 (~−5,4 TPS/przebieg), TPS z pierwszych 3 min maleje 317 → 231 → 219 → 214 → 202. W pilotażu ten sam kierunek, ale zamaskowany fazą checkpointu (okno 720 s). Kandydat na mechanizm: przyrost `pgbench_accounts` między przebiegami (martwe krotki, VACUUM nie oddaje miejsca) — dlatego od rundy 2 `pg_total_relation_size('pgbench_accounts')` przed i po każdym pomiarze (kolumny `accounts_bytes_before` / `accounts_bytes_after`).

## Okno pomiaru = jeden cykl checkpointu (decyzja 2026-10-08, wdrożona 2026-10-09)

- **Okno pomiaru 600 s** (`MEASURE_SECONDS`) = `checkpoint_timeout` (600 s, przeniesiony z PaaS GP — parytet). Okno obejmuje dokładnie jeden pełny cykl checkpointu, więc każda faza cyklu (zrzut brudnych stron, przerwa między checkpointami) jest w oknie dokładnie raz, a średnia z okna nie zależy od tego, w którym miejscu cyklu pomiar wystartował. Przy 720 s okno miało 1 albo 2 checkpointy zależnie od długości warm-upu (sesja 3 pilotażu: 2 checkpointy → 155–158 TPS, 1 → 168–185 TPS).
- **Kontrola: kolumna `checkpoint_aligned`** w `summary.csv` = `true`, gdy między snapshotami `pg_stat_bgwriter` przed i po pomiarze Δ`checkpoints_timed` = 1 i Δ`checkpoints_req` = 0. `false` znaczy, że założenie nie zaszło (checkpoint wymuszony, np. przez `max_wal_size`, albo granica okna wypadła na start checkpointu → 0 lub 2 w oknie).
- **`checkpoint_aligned = false` zostaje w głównej analizie** (decyzja 2026-10-09), plus osobna analiza wrażliwości bez tych przebiegów (`summarize.py`: „steady-state runs without checkpoint_aligned=false”). Uzasadnienie: `steady_state` wyklucza stan sztucznie wytworzony przez nasz protokół (kredyty odnowione w czasie resetu), a niezgodność z cyklem wynika z zachowania samego systemu (checkpoint dłuższy niż 600 s albo wymuszony przez wolumen WAL) albo z pomijalnego efektu brzegowego przy snapshotach. Wykluczanie przesunęłoby wynik w stronę jednej fazy cyklu.
- **Sygnał ostrzegawczy:** jeśli w którejś konfiguracji `false` ma **ponad 20%** przebiegów (fazy z oknem 600 s: `main`, `explanatory`), zatrzymać się i zgłosić — prawdopodobnie realny okres cyklu ≠ 600 s. `summarize.py` wypisuje ten odsetek per konfiguracja i faza; `run-campaign.sh` sprawdza go po każdej sesji (`summarize.py --alignment-check main <env>`, kod 3) i sam zatrzymuje kampanię.
- **Sprawdzenie na starcie sesji:** `init-db.sh` przed załadowaniem danych czyta `checkpoint_timeout` z `pg_settings` i przerywa (sesja idzie w teardown), jeśli wartość ≠ `MEASURE_SECONDS`; odczyt zapisany w `init-*.env` (`CHECKPOINT_TIMEOUT_S`).
- **Nie wymuszamy `CHECKPOINT` przed pomiarem:** ustawiałby każdy przebieg w sztucznej fazie (tuż po zrzuceniu wszystkich brudnych stron), której przy ciągłej pracy nie ma — pomiar opisywałby stan, którego konfiguracja nie utrzymuje, wbrew zasadzie, na której stoi burn-in i kryterium stanu ustalonego.
- Pilotaż (okno 720 s) przeliczony z nową kolumną, informacyjnie: `checkpoint_aligned` premium t/t/f/t/t, GP f/f/t/t/t, E20 t/t/f/t/f (przebiegi 3 i 5 to te z 2 checkpointami), B1ms f/f/t/t/t.

## Jednostka statystyczna: sesja (decyzja 2026-10-09)

- **Sesja** = jedno wcielenie środowiska (`apply` → … → `destroy`): inny host fizyczny, inny dysk, inny serwer PaaS. Przebiegi w sesji dzielą to wcielenie, więc nie są niezależnymi próbami konfiguracji — ich rozrzut mierzy powtarzalność pomiaru na jednej instancji, nie zmienność konfiguracji w chmurze. Przedział ufności z przebiegów byłby za wąski (pseudoreplikacja).
- Sygnał z danych: GP w pilotażu 1383,7 TPS z 95% CI w sesji ±8,7, a sanity check (inne wcielenie, ten sam SKU) 1346,0 — poza tym przedziałem. Protokół sanity checku był inny (burn-in 35 min, jeden przebieg), więc to sygnał, nie dowód.
- **Analiza** (`scripts/summarize.py`): średnia przebiegów w sesji → średnie sesji → średnia konfiguracji, SD średnich sesji i 95% CI z rozkładu t po sesjach (**df = k − 1**, k = liczba sesji). SD wewnątrz sesji raportowane wyłącznie opisowo. Osobno przebiegi w stanie ustalonym i wszystkie (analiza wrażliwości).
- **`session_id`** w `summary.csv` (i `SESSION_ID` w `meta.env`) = znacznik czasu UTC `init-db.sh` danego wcielenia (`results/<env>/init-<session_id>.env`); dla przebiegów sprzed tej zmiany wyprowadzany z najnowszego `init-*.env` sprzed startu obciążenia. Jest zarazem zapisem startu sesji (pora dnia).

## Plan kampanii (Faza 4) — ustalony 2026-10-09, przed startem

Doprecyzowania (reguła zatrzymania na TPS, dolosowanie dodatkowych sesji tym samym skryptem, raport osiągniętej precyzji po 6 sesjach) zaakceptowane 2026-10-09.

- **Cel:** 95% CI średniego TPS każdej konfiguracji (po sesjach) w granicach **±5% średniej**. Najmniejsza różnica między konfiguracjami to ~30–40% (pilotaż: P20 o 31% poniżej GP, B1ms o 27% poniżej E20), więc ±5% rozstrzyga każde porównanie z dużym zapasem. Średnia latencja przy stałych 25 klientach to 25/TPS (prawo Little'a), więc jej względny CI jest praktycznie ten sam co TPS.
- **Start:** 4 rundy × 4 konfiguracje = 16 sesji, każda `scripts/run-session.sh <env> 5 --phase main`.
- **Kolejność:** w rundzie losowa, wylosowana przed startem skryptem `scripts/draw-campaign.py --seed 20261009 --rounds 4` i zapisana w `campaign/round-order.csv` (z ziarnem, datą losowania i metodą). Metoda: losowy kwadrat łaciński — każda konfiguracja raz na każdej pozycji w rundzie, więc efekt pozycji (i pory dnia) rozkłada się równo. Skrypt odmawia ponownego losowania istniejących rund.

| runda | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| 1 | iaas-premium-ssd | iaas-standard-ssd | paas-burstable | paas-general-purpose |
| 2 | paas-general-purpose | paas-burstable | iaas-standard-ssd | iaas-premium-ssd |
| 3 | iaas-standard-ssd | paas-general-purpose | iaas-premium-ssd | paas-burstable |
| 4 | paas-burstable | iaas-premium-ssd | paas-general-purpose | iaas-standard-ssd |

- **Pory dnia rotowane** między rundami; start każdej sesji jest zapisany (`session_id`, log `session-<czas>.log`, `measure_start` każdego przebiegu). Jeśli B1ms (najdłuższa sesja — w pilotażu ~7,5 h, burn-in do 4 h) w praktyce zawsze idzie nocą, zapisać to jako ograniczenie (rozdz. 6).
- **Reguła zatrzymania:** po 4 rundach każda konfiguracja, której 95% CI TPS jest szerszy niż ±5% średniej, dostaje kolejne sesje — maksymalnie do **6 sesji**. Decyzja **wyłącznie na podstawie szerokości CI** (`summarize.py` wypisuje „within” / „WIDER than ±5%”), nigdy wartości średnich. Kolejność dodatkowych rund losowana tym samym skryptem i dopisywana do tego samego pliku: `draw-campaign.py --seed <nowe ziarno> --first-round 5 --rounds 1 --envs <konfiguracje>`. Jeśli po 6 sesjach CI nadal jest szerszy, raportujemy osiągniętą precyzję.
- Rachunek pomocniczy: przy k = 4 (t = 3,182) ±5% wymaga CV średnich sesji ≤ 3,1%, przy k = 6 (t = 2,571) ≤ 4,8%. Rozrzutu między sesjami nie znamy (pilotaż ma jedną sesję na konfigurację) — to właśnie mierzy kampania.
- **Pilotaż** (okno 720 s, inny protokół) **nie wchodzi do danych ani do analizy** — faza `pilot`, `summarize.py` raportuje fazy osobno.
- **Bez osobnego ponownego pilotażu E20** — reguła zatrzymania to pokrywa.
- **Przed kampanią:** sesja eksperymentu wyjaśniającego `scripts/run-session.sh iaas-premium-ssd-readcache 5` (faza `explanatory`, już z oknem 600 s).
- **Wykonanie:** `scripts/run-campaign.sh [--last-round N]` puszcza sesje jedna po drugiej w kolejności z `campaign/round-order.csv` (`run-session.sh <env> 5 --phase main`) i dopisuje każdą zakończoną do `campaign/sessions.csv` (runda, pozycja, konfiguracja, `session_id`, start, koniec, kod wyjścia) — to zapis faktycznych pór sesji. Sesje z kodem 0 są pomijane przy ponownym uruchomieniu. Zatrzymuje się: po nieudanej sesji (ponowne uruchomienie ją powtarza), po przekroczeniu progu 20% `checkpoint_aligned = false`, przed kolejną sesją, jeśli istnieje `results/.campaign-stop` (łagodne zatrzymanie: `touch`), i po bieżącej sesji na SIGTERM/SIGHUP.

## Eksperyment wyjaśniający: cache odczytu na IaaS (zaprojektowany 2026-10-07, przed pomiarem)

**Uzasadnienie — zestawienie z sanity checków (pojedyncze przebiegi, nie wnioski):**

| | PaaS GP (`GP_Standard_D2s_v3`) | IaaS Premium P20 (`Standard_B2s_v2`, `caching = "None"`) |
|---|---|---|
| TPS | **1346**, bez dryfu (1349 → 1341) | **~862** w stanie ustalonym (ostatnie 3 min; 1247 w burście) |
| CPU | **87%** średnio | **31–36%** w stanie ustalonym |
| IOPS | ~3600 `iops`, z tego dysk ~75–89% limitu 2300 | **~2345** — równo na poziomie bazowym P20 |
| Wąskie gardło | CPU | dysk (IOPS P20) |

Konfiguracja PostgreSQL jest wyrównana (15/15 parametrów), klasa maszyny ta sama (2 vCPU / 8 GiB). Najbardziej prawdopodobne źródło różnicy to **cache hosta**: na PaaS odczyty omijają limit dysku (`disk_iops_consumed_percentage` ≈ `write_iops` / 2300), na IaaS (`caching = "None"`) nie. Bez sprawdzenia tego porównanie IaaS vs PaaS mierzyłoby w dużej mierze ustawienie cache, a nie model wdrożenia.

**Hipoteza (zapisana przed pomiarem):** z cache odczytu IaaS Premium zbliża się do PaaS GP, a wąskim gardłem staje się CPU. Hipotezę podważy TPS pozostający w okolicy ~860 (cache nie pomaga — różnica leży gdzie indziej) albo przepustowość ograniczona nadal przez IOPS dysku przy niskim CPU.

**Projekt:**
- Środowisko `environments/iaas-premium-ssd-readcache`: Premium P20 512 GB, `data_disk_caching = "ReadOnly"`, wszystko inne identyczne z `iaas-premium-ssd` (ta sama konfiguracja PostgreSQL, VM, sieć, klient). `data_disk_caching` przechodzi przez `iaas-environment` (domyślnie `"None"`, walidacja: `None` | `ReadOnly`). Osobny klucz stanu: `iaas-premium-ssd-readcache.tfstate`.
- **Poza główną macierzą:** jedna sesja, 5 przebiegów, okno 600 s jak w kampanii: `scripts/run-session.sh iaas-premium-ssd-readcache 5` — przed startem kampanii. Faza `explanatory` jest dla tego środowiska domyślna i wymuszona.
- `Standard_B2s_v2` ma cache hosta (`az vm list-skus`): z cache 9000 IOPS / 125 MB/s wobec 3750 IOPS / 85 MB/s bez cache. **Rozmiaru cache Azure nie publikuje** (brak `CachedDiskBytes`), więc przy bazie 14,6 GiB trafienia w cache są niewiadomą — to część tego, co eksperyment mierzy.
- Burn-in: adaptacyjny dla IaaS (sekcja "Bursting") — przy wyższym CPU kredyty CPU `B2s_v2` mogą zacząć schodzić, wtedy burn-in trwa do ich wyczerpania.
- Kryterium stanu ustalonego według tej samej zasady (wyczerpane wszystkie pule, które pod obciążeniem się wyczerpują): dla każdej puli — wyczerpana albo nie wyczerpuje się w oknie pomiaru (tabela w "Kryterium ważności przebiegu"). Do tego kolumny `*_first` / `*_last` (pierwszy i ostatni odczyt puli w oknie), bo min/max nie mówią, w którą stronę pula się ruszała.

## Eksperyment wyjaśniający — sesja 1 (2026-10-09/10)

`run-session.sh iaas-premium-ssd-readcache 5` (23:01–02:52 czasu PL): init-db 8 min 53 s; burn-in 125 min — kredyty CPU VM spadały ~0,8/min (63 → ~1,8 w 90. min), potem krążyły na 1,2–2,0; pula dysku doszła do 32% i wróciła do 0%, gdy CPU zostało przycięte (dysk przestał burstować). **Wszystkie 5 przebiegów `steady_state = false`**, `checkpoint_aligned` 5/5. Przyczyna: próg „wyczerpane” dla kredytów CPU VM był 0, więc burn-in uznał pulę za „stabilną”, nie „wyczerpaną”, a warm-upy (stałe 120 s) nie drenowały jej ponownie; w czasie resetu kredyty odrastały do 2,3–3,9, każde okno zaczynało się krótkim burstem CPU i kończyło przycięciem (spadek kredytów w oknie 0,7–1,9 > 0,5). Rozwiązanie: próg 2 (sekcja "Kryterium ważności przebiegu"), **powtórka sesji po rundzie 1, przed rundą 2** (decyzja 2026-10-10).

Opisowo, bez wniosków (przebiegi poza stanem ustalonym): z kredytami CPU TPS do ~1860 (pierwsze 3 min przebiegu 1 — powyżej GP), po ich wyczerpaniu ~975–995 (ostatnie 3 min przebiegów 2–5) wobec ~917 na P20 bez cache; latencja dysku 1,2–1,6 ms (P20 bez cache ~9 ms), dysk na 56–70% limitu IOPS (P20 bez cache 99%), CPU 44–53%. Cache usuwa wąskie gardło dyskowe, ale stan utrzymywalny ogranicza poziom bazowy CPU `B2s_v2` — do potwierdzenia powtórką.

## Kryterium ważności przebiegu (ustalone 2026-10-07, przed pilotażem)

Przebieg pomiarowy liczy się do zbioru „stan ustalony” tylko, jeśli spełnia kryterium swojej konfiguracji. Kryterium zapisane **przed** pilotażem, żeby nie dobierać go pod wyniki.

| Konfiguracja | Kryterium stanu ustalonego |
|---|---|
| IaaS (`iaas-standard-ssd`, `iaas-premium-ssd`) | `disk_burst_io_pct_min >= 99` **oraz** `cpu_credits_remaining_min > 2` (do 2026-10-10: `> 0`) |
| PaaS GP (`paas-general-purpose`) | brak kryterium — sanity check: dysk nie jest wąskim gardłem |
| Eksperyment wyjaśniający (`iaas-premium-ssd-readcache`) | każda pula wyczerpana **albo** nie wyczerpuje się w oknie pomiaru: (`disk_burst_io_pct_min >= 99` lub `disk_burst_io_pct_last − disk_burst_io_pct_first <= 1`) **oraz** (`cpu_credits_remaining_max <= 2` lub `cpu_credits_remaining_first − cpu_credits_remaining_last <= 0,5`) — ustalone przed pomiarem; próg 2 (wcześniej 1) od 2026-10-10 |
| PaaS Burstable (`paas-burstable`) | `cpu_credits_remaining_max <= 1` w oknie pomiaru (kredyty CPU wyczerpane) — ustalone po sanity checku B1ms, przed pilotażem |

- Wszystkie kryteria wynikają z tej samej zasady co burn-in: stan, który konfiguracja utrzyma bez końca pod tym obciążeniem. Stąd na IaaS „kredyty CPU > 0” (CPU poniżej poziomu bazowego), a na B1ms odwrotnie „kredyty wyczerpane” (CPU powyżej bazowego). Dla B1ms odrzucono wariant „burst I/O wyczerpany i kredyty > 0” z progiem na IOPS: opisywałby stan przejściowy, a opierałby się na pośrednim progu z metryki `iops`, która (jak na GP) liczy też odczyty z cache hosta; wariant B opiera się na publikowanej metryce `cpu_credits_remaining`.
- `summary.csv` ma kolumnę `steady_state`: `true` / `false` / `n/a` (brak kryterium) / puste (brak metryk potrzebnych do oceny). Liczy ją `collect-results.sh` (`steady_state` w `scripts/lib/common.sh`, progi `STEADY_*`).
- Przebiegów niespełniających kryterium **nie usuwamy**: zostają w CSV z `false`, analiza je wyklucza i raportuje osobno.
- Próg wolno skorygować **tylko na podstawie krzywej kredytów z burn-inu, nigdy na podstawie wyników TPS**.
- **Decyzja 2026-10-10: próg wyczerpania kredytów CPU VM = 2.** Podstawa: krzywa kredytów z burn-inu readcache (sesja 1) — kredyty spadały ~0,8/min z 63 do ~1,8 w 90. minucie, potem przez 35 min krążyły na **1,2–2,0** (CPU przycięte do poziomu bazowego), nigdy nie schodząc do 0. To podłoga metryki, analogicznie do 1,0 na B1ms. Jedna definicja w obie strony (`STEADY_VM_CPU_CREDITS_SPENT_MAX` w `scripts/lib/common.sh`): „wyczerpane” (burn-in, warm-up, kryterium readcache) = ≤ 2; „nieprzycięte” w kryterium głównych IaaS = `cpu_credits_remaining_min > 2` (dotychczasowe > 0 nie wykrywało przycięcia, bo metryka nie schodzi do 0; na P20/E20 bez praktycznego znaczenia — kredyty w oknach 57–103). Przeliczenie wszystkich zebranych przebiegów (offline) nie zmieniło żadnego `steady_state`; 5 przebiegów readcache z sesji 1 zostaje z `false`. B1ms bez zmian (≤ 1, `STEADY_B1MS_CPU_CREDITS_SPENT_MAX`).
- **Decyzja 2026-10-08:** przebieg 5 sesji 1 (`disk_burst_io_pct_min` = 97 < 99) zostaje jako niespełniający kryterium — progu nie zmieniamy, bo jego TPS jest już znany i zmiana byłaby decyzją po fakcie. W analizie: **analiza wrażliwości** — wyniki z przebiegami wykluczonymi przez kryterium i bez wykluczania (`scripts/summarize.py` liczy oba warianty).
- Zastrzeżenie: `Data Disk Used Burst IO Credits Percentage` ma granulację 5 min, więc `disk_burst_io_pct_min` to pierwszy punkt w oknie pomiaru (do 5 min po jego starcie), a nie stan dokładnie w chwili startu.

## Sanity check `paas-general-purpose` (2026-10-07)

Pełny łańcuch na PaaS: apply → `init-db.sh` (**6 min 59 s**) → `--burn-in` (35 min, 1255 TPS) → 1 przebieg → `teardown.sh` → weryfikacja, że w Azure nic nie zostało. Przebieg: **1346,0 TPS, 18,56 ± 7,79 ms**, p50/p95/p99/p99,9 = 16,1/33,4/45,4/90,9 ms, 0 nieudanych. PostgreSQL **16.15** (ta sama wersja minor co Ubuntu 24.04 na IaaS), połączenie **TLSv1.3** (`TLS_AES_256_GCM_SHA384`). Nazwy metryk Azure Monitor zweryfikowane dla obu typów zasobów (VM ma też `Data Disk Latency`; Flexible Server nie ma metryki latencji dysku ani kredytów storage).

Wyniki tego przebiegu (i pilotażu 128 GB z Fazy 1) są w `results/_archive/` — poza katalogami środowisk, poza zbiorem danych; w kontenerze `results` sanity checki też leżą pod `_archive/`. Ustalenia do rozdz. 4–6:
- **PaaS dostarcza więcej IOPS niż provisionowany tier.** Storage P20 = 2300 IOPS (`az postgres flexible-server show`), a `iops` trzymało ~3400–3650 przez 35 min burn-inu i cały pomiar, bez spadku. `disk_iops_consumed_percentage` ≈ `write_iops` / 2300 w każdej minucie → odczyty (~1800/s) idą najpewniej z cache hosta i nie obciążają dysku. Zgodne z dokumentacją Flexible Server: host caching dla dysków < 4 TiB. **Decyzja:** to cecha usługi zarządzanej i tak ją opisujemy (rozdz. 5–6); IaaS zostaje na `caching = "None"`, bo porównanie Standard vs Premium ma mierzyć warstwę dyskową, nie cache hosta. Dysk PaaS pracował na 72–89% swojego limitu, więc na GP burn-in nie ma czego drenować w storage — zostaje dla jednolitości protokołu.
- **Na PaaS GP wąskim gardłem jest CPU**, nie dysk: `cpu_percent` śr. 87%, maks. 91,5% (2 vCore).
- **Konfiguracja PostgreSQL nie była parytetowa** — Azure stroi serwer (`results/_archive/paas-general-purpose-sanity-20261007/pg_settings-nondefault.csv`). **Decyzja:** parametry wydajnościowe przeniesione na IaaS, patrz "Parytet konfiguracji PostgreSQL".
- **Oczekiwanie na lag ingestii po burn-inie było bezczynnością odbudowującą kredyty** (idle gap 352 s w tym przebiegu). **Decyzja:** raport burn-inu w tle, pomiar startuje od razu (protokół wyżej). Skuteczność do potwierdzenia kolumną `disk_burst_io_pct_min` pierwszego przebiegu na IaaS.
- **Wariant 3 (`B_Standard_B1ms`) ma limit 640 IOPS po stronie obliczeniowej** (`list-skus`) — poniżej 2300 z P20, więc tam IOPS dławi SKU, nie storage.

## Sanity check `iaas-premium-ssd` (2026-10-07)

Łańcuch: apply → cloud-init bez błędów → `init-db.sh` (**7 min 4 s**, 14,6 GiB) → `run-benchmark.sh --burn-in` (burn-in 35 min, 1197,6 TPS, i od razu pomiar — idle gap 6 s) → zrzut `pg_settings` → `teardown.sh` → w Azure nic nie zostało. Przebieg: **1104,0 TPS, 22,63 ± 16,96 ms**, p50/p95/p99/p99,9 = 12,8/52,0/66,6/101,9 ms, 0 nieudanych. PostgreSQL 16.15, TLSv1.3 z tym samym szyfrem co PaaS. **Parytet konfiguracji potwierdzony: 15/15 przeniesionych parametrów identycznych z PaaS GP.** Wyniki w `results/_archive/iaas-premium-ssd-sanity-20261007/` (lokalnie i w kontenerze `results` pod `_archive/`).

- **35-minutowy burn-in nie drenuje puli P20** — rozstrzygnięte: burn-in 60 min na wszystkich konfiguracjach. `Data Disk Used Burst IO Credits Percentage`: 0% na starcie burn-inu → 60% po 30 min → ~75% na jego końcu → **100% o 11:16–11:19, po ~9,5 min z 12-minutowego okna pomiaru**. Od tej chwili IOPS stoją płasko na ~2345 (poziom bazowy P20), TPS spada z ~1250 do ~850: `tps_first3m` = 1247, `tps_last3m` = 862 (−31%). Przebieg pomiarowy jest więc mieszanką burstu i stanu ustalonego. Przyczyna: obciążenie burstuje do ~2800–3500 IOPS, a nie stale do maksymalnych 3500, więc nadwyżka ponad 2300 (~850 IOPS) jest mniejsza niż ta, na którą liczona jest 30-minutowa pula — przy tym obciążeniu P20 drenuje się dopiero po **~46 min**. Ten przebieg nie spełniłby kryterium stanu ustalonego (`disk_burst_io_pct_min` = 86 < 99).
- `disk_burst_io_pct_min` ma granulację 5 min, więc to pierwszy punkt w oknie, nie dokładny stan na jego początku (tu 86% o 11:09, podczas gdy o 11:04 było 75%).
- `Data Disk IOPS Consumed Percentage` = 100% w czasie burstu i ~99% w stanie ustalonym — nie odróżnia jednego od drugiego; rozstrzyga metryka kredytów.
- `vm_uncached_iops_consumed_pct_max` = 86% — limit VM (3750 IOPS) nieosiągnięty nawet w burście, co potwierdza wybór 512 GB.
- Latencja dysku z Azure Monitor (`disk_latency_ms_avg`) = 7,51 ms; kolumna wypełnia się, więc jest teraz wymagana.

## Sanity check `paas-burstable` (2026-10-07) — zatrzymany przed pomiarem

Łańcuch: apply → `init-db.sh` (**25 min 6 s** — ~3,5× dłużej niż GP/IaaS: generowanie danych 826 s, klucze główne 644 s, vacuum 35 s; 14,6 GiB) → burn-in 60 min (233,9 TPS, 106,9 ms, 0 nieudanych) → **zatrzymany na granicy burn-in/pomiar** (pgbench warm-upu zabity 4 s po starcie), bo `cpu_credits_remaining` po 60 min nie zbliżało się do zera. Przebiegu pomiarowego nie ma.

- **Kredyty CPU:** 29 na starcie serwera, 27 na początku burn-inu → **18 po 60 min** (~0,15/min przy CPU 31–38%). Do zera brakowałoby jeszcze ~2 h obciążenia.
- **Burst I/O po stronie obliczeniowej, niewidoczny w metrykach kredytów:** przez pierwsze ~30 min obciążenia IOPS stały płasko na **~1018**, o 12:41 spadły skokowo do **~810** i tak zostały do końca; TPS ~255 → ~212, latencja ~98 → ~118 ms (log `-P 60` burn-inu). Płaskie plateau i skok po ~30 min pasują do kredytowego limitu I/O; Flexible Server nie publikuje dla niego metryki. Katalogowe 640 IOPS z `list-skus` nie odpowiada żadnemu z poziomów. 60-minutowy burn-in ten burst drenuje.
- `disk_iops_consumed_percentage` ≈ `write_iops` / 2300 (22% → 16%), jak na GP — dysk P20 nie jest wąskim gardłem, ogranicza warstwa obliczeniowa.
- **Obserwacja z logów burn-inu (do rozdz. 5):** przy kredytach CPU > 0 B1ms przechodzi przez dwie fazy przejściowe — najpierw burst I/O (~1018 IOPS, ~255 TPS), potem plateau ~810 IOPS / ~212 TPS — a stan utrzymywalny (kredyty wyczerpane) zaczyna się dopiero po nich.
- **Rozstrzygnięte:** kryterium B1ms = kredyty CPU wyczerpane (`cpu_credits_remaining_max <= 1`), burn-in B1ms adaptacyjny do wyczerpania kredytów (sekcja "Bursting").
- Wyniki: `results/_archive/paas-burstable-sanity-20261007/` (lokalnie i w kontenerze; burn-in z `burnin-metrics.txt`, surowymi metrykami `burnin-azure-metrics.json` i logiem `-P 60`, `init-*.env`).

## Parytet konfiguracji PostgreSQL

Punkt odniesienia: `pg_settings` serwera PaaS `GP_Standard_D2s_v3` (te same 2 vCPU / 8 GiB co `Standard_B2s_v2`). Na IaaS przeniesiony jest **każdy parametr wpływający na wydajność** (pamięć, WAL, checkpointy, autovacuum, koszty planera, zapis w tle) — w `modules/iaas-vm`, zmienna `postgresql_settings`, ustawiana przez `pg_conftool` w cloud-init przed pierwszym startem, plus `--data-checksums` w `pg_createcluster`. Nie przenosimy parametrów specyficznych dla Azure, logowania, certyfikatów ani rozszerzeń. Zrzut `pg_settings` na IaaS przy sanity checku ma potwierdzić, że wartości faktycznie się zastosowały. Kolumna "IaaS domyślnie" = PostgreSQL 16 na Ubuntu 24.04 bez strojenia.

| Parametr | IaaS domyślnie | PaaS (GP) | Przeniesiony? | Uzasadnienie |
|---|---|---|---|---|
| `shared_buffers` | 128 MiB | 2 GiB | tak | pamięć: bufor stron w PostgreSQL, główny czynnik cache hit ratio |
| `effective_cache_size` | 4 GiB | 6 GiB | tak | koszt planera: zakładany rozmiar cache (PG + OS) |
| `maintenance_work_mem` | 64 MiB | 211 MiB (216064 kB) | tak | pamięć VACUUM i budowy indeksów — czas resetu i `init-db.sh` |
| `wal_buffers` | auto (4 MiB przy 128 MiB `shared_buffers`) | 16 MiB | tak | WAL: bufor przed zapisem na dysk |
| `wal_compression` | off | pglz | tak | WAL: mniej bajtów (full-page images) kosztem CPU |
| `max_wal_size` | 1 GiB | 25 GiB | tak | checkpointy: przy 1 GiB wymuszane (`checkpoints_req`) w trakcie pomiaru |
| `checkpoint_timeout` | 5 min | 10 min | tak | checkpointy: częstość i rozmiar zrzutów brudnych stron |
| `bgwriter_delay` | 200 ms | 20 ms | tak | zapis w tle: częstość rund background writera |
| `backend_flush_after` | 0 | 2 MiB | tak | zapis: wymuszony writeback z backendów, mniejsze piki I/O |
| `vacuum_cost_page_miss` | 2 | 10 | tak | autovacuum: koszt odczytu strony spoza cache (throttling) |
| `random_page_cost` | 4 | 2 | tak | koszt planera: losowy odczyt vs sekwencyjny |
| `jit` | on | off | tak | wykonanie zapytań (pgbench nie przekracza progów JIT — dla parytetu) |
| `default_toast_compression` | pglz | lz4 | tak | CPU kompresji TOAST (pgbench prawie nie używa — dla parytetu) |
| `data_checksums` | off | on | tak (`--data-checksums`) | narzut CPU na każdy odczyt/zapis strony; integralność danych |
| `track_io_timing` | off | on | tak (oba ramiona) | pomiar, nie strojenie: czasy I/O w `pg_stat_io` |
| `archive_mode` / `archive_command` / `archive_timeout` | off / — / 0 | always / `BlobLogUpload.sh` / 300 s | **nie** | wbudowany backup PaaS (PITR): narzut po stronie PaaS i zarazem zaleta modelu — opisać w pracy |
| `wal_keep_size` | 0 | 400 MB | nie | retencja WAL dla replikacji/odtwarzania PaaS, poza ścieżką zapisu |
| `shared_preload_libraries` | — | `pg_cron`, `pg_stat_statements`, `azure`, `pg_qs`, … | nie | rozszerzenia Azure (narzut po stronie PaaS; `pg_stat_statements.track = none`) |
| `temp_tablespaces`, `azure.enable_temp_tablespaces_on_local_ssd` | — | lokalny SSD | nie | specyficzne dla Azure; pgbench nie tworzy plików tymczasowych |
| `max_connections`, `reserved_connections`, `superuser_reserved_connections` | 100 / 0 / 3 | 859 / 5 / 10 | nie | limity pojemności i dostęp administracyjny; 25 klientów |
| `ssl`, `ssl_ciphers`, `ssl_*_file` | on (certyfikat snakeoil) / `HIGH:MEDIUM:+3DES:!aNULL` | on / ECDHE + AES-GCM/ChaCha20 | nie | szyfrowanie włączone na obu; TLS 1.3 negocjuje szyfr niezależnie od `ssl_ciphers` — potwierdza `pg_stat_ssl` |
| `log_*`, `tcp_keepalives_*`, `authentication_timeout` | domyślne | zmienione | nie | logowanie i obsługa połączeń, poza ścieżką transakcji |
| `lc_*`, kodowanie, `TimeZone`, `default_text_search_config` | domyślne | zmienione | nie | lokalizacja |
| huge pages | `try`, brak zarezerwowanych stron w OS | nieznane (`shared_memory_size_in_huge_pages` to tylko wyliczenie) | nie | poziom OS, niewidoczne w `pg_settings` |

## Architektura testowa
- **Osobna mała VM-klient** (`Standard_B2s_v2`) uruchamia pgbench — celowo odseparowana od serwera bazy, żeby nie zaburzać pomiaru CPU/RAM serwera (kluczowa metryka z USOS)
- Ta sama VM-klient używana dla wszystkich 4 konfiguracji
- **Ubuntu 24.04 (noble) na obu VM = parytet wersji PostgreSQL 16 z PaaS.** Repozytoria 22.04 (jammy) mają PostgreSQL 14 — cloud-init z `postgresql-16` w ogóle nie postawiłby bazy, a nawet z 14 porównanie IaaS vs PaaS mieszałoby wersję silnika z modelem wdrożenia. Noble ma 16 natywnie, tak jak Flexible Server (`version = 16`). Klient przypięty do `postgresql-16`, żeby pgbench miał tę samą wersję główną.

## Historia decyzji: region i rozmiar VM

Pierwotny plan (`polandcentral` + `Standard_D2s_v5`) okazał się niewykonalny na subskrypcji Azure for Students. Zdiagnozowane systematycznie (CLI: `az vm list-usage`, `az vm list-skus --all`, `az quota update`) na ~20 rozmiarach VM w ~6 regionach UE:

1. **`Standard_D2s_v5` niedostępny.** Rodzina DSv5 (i wszystkie nowsze generacje: v6, v7) ma quota = 0 na tej subskrypcji, a samoobsługowe zwiększenie (`az quota update`) kończy się `ResourceNotAvailableForOffer` — kategoryczna odmowa, nie "spróbuj ponownie". Starsze generacje (`D2s_v3`, `D2s_v4`, `D2as_v4`) mają niezerową quotę (4 vCPU), ale sam rozmiar VM jest zablokowany dla subskrypcji (`NotAvailableForSubscription`) niezależnie od quoty. Jedyny sprawdzony rozmiar dostępny **i** z niezerową quotą: `Standard_B2s_v2` (2 vCPU / 8 GB, Premium Storage capable — spełnia oryginalną specyfikację).
2. **`Poland Central` całkowicie zablokowany.** Azure Policy (`sys.regionrestriction`) na tej subskrypcji dopuszcza tylko 5 regionów: `belgiumcentral`, `francecentral`, `germanywestcentral`, `swedencentral`, `norwayeast` (ten ostatni dodatkowo access-restricted). Nie wykrywalne komendami informacyjnymi (`list-skus`/`list-usage`) — ujawnia się dopiero przy próbie realnego utworzenia zasobu.
3. **`Germany West Central` też odpadł** — dwa niezależne błędy: chwilowy brak pojemności fizycznej dla `Standard_B2s_v2` (`SkuNotAvailable`) i osobno ograniczenie Flexible Server PaaS w tym regionie ("location is restricted from performing this operation", prawdopodobnie limit dla klientów spoza EA).
4. **`Belgium Central` przeszedł testy realnym tworzeniem+kasowaniem zasobu** (VM `Standard_B2s_v2` i PaaS General Purpose) → finalny wybór.

Wniosek metodologiczny do rozdziału 3: dostępność zasobów w chmurze dla subskrypcji promocyjnych/studenckich nie jest w pełni przewidywalna z dokumentacji ani z komend informacyjnych — wymaga systematycznej, empirycznej weryfikacji (realny apply/destroy), nie tylko sprawdzenia quoty.

## Parametry pgbench (ustalone)
- Scale factor: **1000** (**15,69 GB = 14,6 GiB** bazy — `pg_database_size` po `init-db.sh`; wcześniejsze "13 GB" było odczytem w trakcie budowy klucza głównego; w pracy jednostki binarne (GiB); celowo > 8 GiB RAM serwera, żeby wymusić realne I/O na dysk zamiast operowania z cache). `init-db.sh` zapisuje rozmiar i czas inicjalizacji w `results/<env>/init-*.env`.
- Warm-up: minimum 2 min, nieliczony do wyników; od 2026-10-08 adaptacyjny — trwa, dopóki pule wyczerpane w burn-inie nie wrócą do wyczerpania (patrz "Bursting jako czynnik zakłócający")
- Pomiar właściwy: 10 min (600 s = `checkpoint_timeout`, jeden cykl checkpointu — sekcja "Okno pomiaru") → `pgbench -c 25 -j 2 -T 600 -P 60 -l`; pilotaż mierzył 12 min (`-T 720`)
- Klienci: `-c 25 -j 2`
- Reset stanu: `TRUNCATE pgbench_history` + `VACUUM ANALYZE` po każdym powtórzeniu w obrębie tej samej konfiguracji; pełna reinicjalizacja (`pgbench -i -s 1000`) tylko przy zmianie konfiguracji
- Burn-in: ciągły pgbench raz po inicjalizacji, do wyczerpania pul kredytów, minimum 60 min (B1ms adaptacyjnie, limit 4 h), nieliczony, bez przerwy przed pierwszym pomiarem (patrz "Bursting jako czynnik zakłócający")
- Pomiar z wnętrza PostgreSQL (te same zapytania na IaaS i PaaS): snapshoty `pg_stat_io`, `pg_stat_database` (`pgbench_db`) i `pg_stat_bgwriter` tuż przed i tuż po pomiarze właściwym; raz na przebieg `version()` i `pg_stat_ssl` dla własnego połączenia. `track_io_timing = on` na obu ramionach (IaaS: `pg_conftool` w cloud-init, PaaS: `azurerm_postgresql_flexible_server_configuration`)

## Plan statystyczny
1. Pilotaż: 5 przebiegów na każdą z 4 konfiguracji → policz odchylenie standardowe TPS/latencji. **Przebiegi pilotażu nie trafiają do końcowego zbioru**: każdy przebieg ma w `meta.env` i w `summary.csv` kolumnę `phase` (`pilot` / `main` / `explanatory` — ta ostatnia wyłącznie dla eksperymentu wyjaśniającego i dla niego obowiązkowa; skrypty pilnują tego w obie strony). Domyślnie `pilot` — fazę `main` trzeba podać jawnie (`--phase main`), więc pomyłka może najwyżej wykluczyć przebieg, nigdy wmieszać pilotaż do danych.
2. Pilotaż zakończony. Jednostką statystyczną jest **sesja**, nie przebieg (sekcja "Jednostka statystyczna: sesja"); liczba sesji: 4 na konfigurację, z regułą zatrzymania do 6 (sekcja "Plan kampanii").
3. Randomizacja kolejności konfiguracji (`campaign/round-order.csv`, kwadrat łaciński) i rotacja pory dnia — rundy rozłożone na różne dni, argument na zmienność chmury w czasie
4. Raportowanie: średnia ± CI, nigdy pojedyncze liczby.
5. **Format każdego podsumowania (od 2026-10-08):** średnia, odchylenie standardowe (SD) i 95% przedział ufności średniej z rozkładu t-Studenta, **każde podpisane** — „± SD” i „± 95% CI” to różne wielkości (przy n = 3: 957,8 TPS, SD 9,1, 95% CI ±22,7). Od 2026-10-09 liczone po średnich sesji (df = k − 1). Liczy to `scripts/summarize.py <env>` (kwantyl t wyliczany dokładnie, bez tablic), osobno dla przebiegów w stanie ustalonym i dla wszystkich.

## Budżet
Realny koszt obliczeniowy przy efemerycznych środowiskach (stawianych na czas testu i niszczonych zaraz po) to raczej kilkanaście-kilkadziesiąt dolarów, nie $100. Główne ryzyko: zapomnienie o `terraform destroy` — automatyzacja niszczenia zasobów jest priorytetem.

**Rzeczywiste koszty (odczyt 2026-10-10 wieczorem):**
- Źródło kosztów: Cost Management przez `az rest` (`POST /subscriptions/<id>/providers/Microsoft.CostManagement/query?api-version=2023-03-01`, `ActualCost`, grupowanie `TagKey` `environment`). `az consumption usage list` na tej subskrypcji zwraca rekordy bez kwot (`pretaxCost` = None) — bezużyteczne. Dane z ~1-dniowym opóźnieniem: koszty z 2026-10-10 niepełne (GP z rundy 1 jeszcze nie widoczny).
- Stan kredytu: billing API (`billingAccounts/<ba>/billingProfiles/<bp>/providers/Microsoft.Consumption/credits/balanceSummary?api-version=2023-03-01`, konto MCA Individual): **current $99,76, estimated $91,44, pending eligible charges $8,32**.
- Koszty per środowisko (EUR, łącznie z sanity checkami i pilotażem, do 2026-10-10 częściowo): iaas-standard-ssd 2,42; iaas-premium-ssd 2,23; paas-burstable 1,39; iaas-premium-ssd-readcache 1,07; paas-general-purpose 0,42; razem **7,53 €**. Per sesja (pełne dni): P20 ~0,85–0,98 €, E20 ~1,03–1,19 €, B1ms ~0,68 €, readcache ~1,07 €, GP ~0,29 € — koszt sesji wyznaczają głównie dwie VM `B2s_v2` i czas sesji. Szacunek całej kampanii (16–24 sesje + powtórka readcache): ~15–25 $, w granicach kredytu.

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
│   ├── paas-general-purpose/
│   └── iaas-premium-ssd-readcache/ # eksperyment wyjaśniający (cache odczytu), poza macierzą
├── scripts/
│   ├── lib/common.sh              # wspólna konfiguracja (parametry pgbench, SSH, .pgpass) + helpery
│   ├── init-db.sh <env>           # pgbench -i -s 1000 (raz na środowisko, przed pierwszym run-benchmark.sh)
│   ├── run-benchmark.sh <env>     # warm-up + pomiar 10 min + snapshoty pg_stat_* + TRUNCATE/VACUUM ANALYZE;
│   │                              # --burn-in: najpierw burn-in (≥ 60 min, adaptacyjny); ściąga wyniki do results/
│   ├── collect-results.sh <env>   # agreguje results/<env>/<run>/ → results/<env>/summary.csv
│   ├── teardown.sh <env>          # collect → check metryk → gzip → upload → terraform destroy
│   ├── run-session.sh <env> <N>   # cała sesja: IP → apply → init-db → burn-in → N przebiegów → teardown (pułapka: --force)
│   ├── summarize.py <env>         # średnie sesji → k, średnia, SD, 95% CI (t, df = k − 1) — stan ustalony i wszystkie
│   ├── draw-campaign.py           # losowanie kolejności rund kampanii → campaign/round-order.csv
│   ├── run-campaign.sh            # sesje kampanii jedna po drugiej według round-order.csv → campaign/sessions.csv
│   └── lib/run_stats.py           # percentyle latencji, TPS 3 min, delty pg_stat_* (dla collect-results)
├── campaign/                     # round-order.csv: wylosowana kolejność rund (ziarno, data, metoda);
│                                  # sessions.csv: faktyczny przebieg kampanii (run-campaign.sh)
├── tests/dry-run/                # run.sh + fałszywe ssh/terraform/az/psql/pgbench: całe sesje bez Azure
├── results/                      # surowe wyniki per przebieg (gitignored); wyjątek: results/*/summary.csv
│   └── _archive/                  # pilotaż 128 GB i sanity checki — poza zbiorem danych
└── .github/workflows/             # CI: terraform fmt -check, validate, bash -n, py_compile, dry run
```

### Jak działają `scripts/*.sh`
- Uruchamiane **lokalnie** (nie na VM), łączą się przez SSH (`~/.ssh/id_rsa_pgbench` — RSA, bo provider azurerm 3.x odrzuca ed25519 w `admin_ssh_key`) do VM-klienta i tam zdalnie odpalają `pgbench`/`psql` — sama VM bazy nigdy nie jest dotykana bezpośrednio (dla IaaS: prywatny IP w tej samej podsieci; dla PaaS: publiczny FQDN Flexible Servera).
- Hasło do bazy nigdy nie trafia do argumentów `ssh`/wiersza poleceń (ryzyko re-parsowania przez zdalną powłokę) — zamiast tego skrypt zapisuje `~/.pgpass` na VM-kliencie (`chmod 600`) przed każdym uruchomieniem, `pgbench`/`psql` czytają je automatycznie.
- Kolejność użycia: `terraform apply` w danym `environments/<env>` → `init-db.sh <env>` (raz) → `run-benchmark.sh <env> --burn-in` (raz: burn-in + pierwszy przebieg pomiarowy) → `run-benchmark.sh <env>` (kolejne przebiegi, łącznie N per plan statystyczny) → `teardown.sh <env>`.
- **W praktyce całą sesję robi `run-session.sh <env> <N> [--phase pilot|main]`:** aktualizacja `admin_source_ip` w `terraform.tfvars` środowiska → `terraform init` + `apply` → czekanie na cloud-init (klient; dla IaaS też VM bazy) → `init-db.sh` → `run-benchmark.sh --burn-in` → N−1 kolejnych przebiegów jeden po drugim → `teardown.sh`. **Obowiązkowa pułapka:** przy błędzie, Ctrl+C (SIGINT), SIGTERM i SIGHUP (zamknięcie terminala) wywołuje `teardown.sh --force` — celem jest, żeby nic nie zostało włączone; drugi Ctrl+C nie przerwie tego teardownu. Log całej sesji: `results/<env>/session-<czas>.log` (na końcu wgrywany też do kontenera). Długie sesje i tak uruchamiać w `tmux`/`screen`.
- Ctrl+C lub błąd w `run-benchmark.sh` zatrzymuje też pgbench na kliencie (`pkill -x pgbench` przez SSH) — przerwany lokalny `ssh` sam go nie zatrzymuje.
- `teardown.sh` kończy sesję w jedynej kolejności, która nic nie gubi: odczekuje lag ingestii → `collect-results.sh` → sprawdza, że ostatni przebieg ma wypełnione wymagane kolumny metryk (inaczej przerywa **przed** `destroy`; `--force` świadomie to pomija) → gzip surowych logów `-l` → upload `results/<env>/` do kontenera `results` w `sttfstatepgbench01` → `terraform destroy -auto-approve` → sprawdzenie, że resource group zniknęła. Nieudany upload nie blokuje `destroy` (dane zostają lokalnie; zostawienie środowiska jest droższą porażką).
- `summary.csv` (jeden wiersz na przebieg pomiarowy): `phase`, `session_id`, `steady_state` (patrz "Kryterium ważności przebiegu"), `checkpoint_aligned`, `warmup_s`, TPS, średnia latencja, p50/p95/p99/p99.9 latencji i liczba nieudanych transakcji (z logów `-l`), TPS z pierwszych i ostatnich 3 min (dryf, np. koniec kredytów w trakcie pomiaru), cache hit ratio, odczyty/zapisy i ich czasy z `pg_stat_io`, checkpointy timed/req, `measure_start`, `server_version`, `idle_gap_s` oraz metryki Azure Monitor (IOPS odczyt/zapis, queue depth, % zużycia IOPS dysku, CPU, pamięć, kredyty). Nazwy kolumn wspólne dla IaaS i PaaS tam, gdzie wielkość jest ta sama.
- Login/hasło do bazy dla PaaS pobierane z outputów Terraforma (`db_admin_login`, `db_name`, `db_fqdn`) — brak zahardkodowanych wartości mogących się rozjechać z `terraform.tfvars`. Dla IaaS `postgres`/`pgbench_db` są zahardkodowane w skrypcie zgodnie z `modules/iaas-vm/cloud-init.tpl` (tam też nie są parametryzowane).

Każda konfiguracja w `environments/` ma **własny, izolowany stan Terraforma** (backend `azurerm`, NIE Git — patrz niżej) — pozwala to na niezależne `apply`/`destroy` pojedynczego wariantu bez ryzyka dla pozostałych.

### Konwencje techniczne (ustalone podczas refaktoryzacji)
- **Tagowanie:** `locals { common_tags = { project = "thesis-iaas-paas-postgres", environment = var.environment_name } }` w modułach, gdzie ten sam blok tagów powtarzał się 2+ razy w pliku (`linux-vm`, `network`, `bootstrap`). Tam gdzie tagi występują raz — zostają inline.
- **Kompozycja modułów:** `linux-vm` to wspólny budulec dla `iaas-vm` i `client-vm` (unika duplikacji public IP + NIC + VM). `iaas-environment`/`paas-environment` to moduły spinające całe środowisko — dzięki temu pary `environments/iaas-*` i `environments/paas-*` (wcześniej bajtowo identyczne poza jedną zmienną) są teraz kilkunastolinijkowymi wrapperami.
- **Znana granica Terraforma (do wzmianki w pracy, nie do naprawy w kodzie):** blok `terraform{}`/`provider{}` musi być zadeklarowany w każdym root module osobno (bootstrap + 4 environments = 5×) — to ograniczenie narzędzia, nie przeoczenie. To samo dotyczy `backend "azurerm" {}` (nie przyjmuje zmiennych, różni się tylko `key`).
- **Formatowanie:** `terraform fmt -recursive` odpalane po większych zmianach, `terraform fmt -check -recursive` powinno zawsze wychodzić czysto.

Storage Account pod remote state: `sttfstatepgbench01` — potwierdzony (utworzony przez `bootstrap/`, trzyma stan wszystkich 4 środowisk). Kontener `results` w tym samym koncie (też z `bootstrap/`) to archiwum wyników uploadowanych przez `teardown.sh`.

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
- **Faza 1 — ZAMKNIĘTA** (2026-09-27): pierwszy realny przebieg end-to-end na `iaas-standard-ssd` (apply → cloud-init → `init-db.sh` → pomiar → `collect-results.sh` → destroy). 7 poprawek z pierwszego testu: Ubuntu 24.04 zamiast 22.04, bez `postgresql-contrib-16`, klient przypięty do `postgresql-16`, `pg_conftool` zamiast `sed`, klucz RSA zamiast ed25519, SSH keepalive, dyski 512 GB zamiast 128 GB. Wynik referencyjny (206,6 TPS, 121,0 ms, Standard SSD **128 GB**) to wyłącznie test pipeline'u — konfiguracja porzucona, nie wchodzi do zbioru danych. Jego katalog przeniesiony do `results/_archive/iaas-standard-ssd-128gb-pilot-20260927/`.
- Faza 2 (równolegle z 1): pisanie rozdziału 2
- **Faza 3 — ZAMKNIĘTA (2026-10-07 – 2026-10-09)**: pilotaż (5×4 przebiegi); wnioski 2026-10-09: okno pomiaru 600 s, sesja jako jednostka statystyczna, plan kampanii z regułą zatrzymania. Kolejność konfiguracji wylosowana z ziarnem `20261007` (`random.Random(20261007).sample([iaas-standard-ssd, iaas-premium-ssd, paas-burstable, paas-general-purpose], 4)`): **iaas-premium-ssd → paas-general-purpose → iaas-standard-ssd → paas-burstable**. Każda konfiguracja = jedna sesja `run-session.sh <env> 5` (faza `pilot`). Eksperyment wyjaśniający (`iaas-premium-ssd-readcache`, 5 przebiegów) osobno, poza tą kolejnością.
- **Faza 4 — W TOKU (start 2026-10-09 wieczorem):** readcache sesja 1 (wszystkie `false`, powtórka przed rundą 2) i runda 1 zakończone 2026-10-10; dalej powtórka readcache, decyzja o dryfie E20, rundy 2–4. Kampania 4 rundy × 4 konfiguracje (+ do 2 sesji z reguły zatrzymania) według `campaign/round-order.csv` — sekcja "Plan kampanii".
- Faza 5: analiza wyników + rozdział 5
- Faza 6: rozdział 6 (wnioski)
- Faza 7: redakcja, poprawki promotora, złożenie w APD

## Zasady pracy
- Przy modyfikacji plików zawsze podawaj pełną, gotową do wklejenia zawartość pliku (nie tylko diff/fragment).
- Terraform ma być zrobiony porządnie: remote state, moduły parametryzowane, automatyczne `destroy` po teście — to element odróżniający pracę "zbliżoną do naukowej" od zwykłego postawienia serwera.
- README i komentarze w kodzie repo — po angielsku. Sama praca (LaTeX) — po polsku.