#!/usr/bin/env bash
# ticketbench.sh: pobiera ticketbench z GitHuba, stawia środowisko i uruchamia
# benchmarki PostgreSQL / MariaDB / MongoDB / Valkey.
#
# Samodzielnie (sklonuje repozytorium ticketbench z submodułami do ./ticketbench):
#   curl -fsSLO https://raw.githubusercontent.com/ryczek02/ticketbench/main/ticketbench.sh
#   chmod +x ticketbench.sh && ./ticketbench.sh all
# Albo z wnętrza klonu:
#   git clone --recursive https://github.com/ryczek02/ticketbench && cd ticketbench
#   ./ticketbench.sh all
#
# Działa na macOS (bash 3.2) i Linuksie. Wymaga: git, curl, tar, docker z compose v2.
set -euo pipefail

GH_OWNER=${TB_GH_OWNER:-ryczek02}
GLUE_URL=https://github.com/$GH_OWNER/ticketbench.git
SUBMODULES="contracts services cli infra"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# Inside a clone of the glue repository the clone itself is the workspace.
if [ -z "${TB_HOME:-}" ] && [ -f "$here/report/sprawozdanie.tex" ]; then TB_HOME=$here; fi
TB_HOME=${TB_HOME:-$PWD/ticketbench}
TB_UPDATE=${TB_UPDATE:-0}               # 1 = submoduły na najnowszy main zamiast przypiętych commitów
TB_VERSION=${TB_VERSION:-latest}        # tag obrazów w GHCR: latest, 0.1.0, sha-abc1234
TB_CHANNEL=${TB_CHANNEL:-latest}        # wydanie tbench: latest, edge albo v0.1.0
TB_RUNNER_PORT=${TB_RUNNER_PORT:-7070}
TB_PROJECT=${TB_PROJECT:-ticketbench}   # nazwa projektu docker compose
TB_SOURCE=${TB_SOURCE:-0}               # 1 = budowanie obrazów i tbench ze źródeł

BIN=$TB_HOME/bin
TBENCH=$BIN/tbench
INFRA=$TB_HOME/infra
RESULTS=$TB_HOME/results

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=; G=; Y=; R=; N=; fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sbłąd:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

compose() {
  local files=(-f "$INFRA/docker-compose.yml")
  if [ "$TB_SOURCE" = 1 ]; then files+=(-f "$INFRA/docker-compose.dev.yml"); fi
  TB_VERSION=$TB_VERSION TB_RUNNER_PORT=$TB_RUNNER_PORT docker compose -p "$TB_PROJECT" "${files[@]}" "$@"
}

tb() {
  [ -x "$TBENCH" ] || die "brak $TBENCH, uruchom najpierw: $0 install"
  OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4317} \
  OTEL_EXPORTER_OTLP_INSECURE=true \
    "$TBENCH" --runner "localhost:$TB_RUNNER_PORT" "$@"
}

platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;; Linux) os=linux ;; MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) die "nieobsługiwany system $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;;
    *) die "nieobsługiwana architektura $(uname -m)" ;;
  esac
  echo "${os}_${arch}"
}

port_busy() {
  if have lsof; then lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  elif have ss; then ss -ltn "( sport = :$1 )" 2>/dev/null | grep -q LISTEN
  else return 1; fi
}

# ---------------------------------------------------------------- doctor
cmd_doctor() {
  say "Sprawdzam wymagania"
  local missing=0
  for c in git curl tar docker; do
    if have "$c"; then ok "$c"; else warn "brak: $c"; missing=1; fi
  done
  if docker compose version >/dev/null 2>&1; then ok "docker compose $(docker compose version --short 2>/dev/null)"; else warn "brak docker compose v2"; missing=1; fi
  if docker info >/dev/null 2>&1; then
    local mem
    mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
    mem=$((mem / 1024 / 1024 / 1024))
    if [ "$mem" -ge 10 ]; then ok "pamięć Dockera: ${mem} GB"
    else warn "pamięć Dockera: ${mem} GB (do 10 mln biletów zalecane 10 GB, smoke wystarczy 4 GB)"; fi
  else
    warn "demon Dockera nie działa (uruchom Docker Desktop albo usługę docker)"; missing=1
  fi
  for c in tectonic go gh; do
    if have "$c"; then ok "$c (opcjonalnie)"; else printf '  - %s (opcjonalnie, nie znaleziono)\n' "$c"; fi
  done
  local busy=""
  for p in 5432 3306 27017 6379 7001 7002 7003 7004 "$TB_RUNNER_PORT" 4317 4318 16686 9090 3000; do
    if port_busy "$p"; then busy="$busy $p"; fi
  done
  if [ -n "$busy" ]; then
    if compose ps -q 2>/dev/null | grep -q .; then ok "porty zajęte przez działający stos $TB_PROJECT"
    else warn "zajęte porty:$busy (zatrzymaj inne usługi albo zmień TB_RUNNER_PORT)"; fi
  else ok "porty wolne"; fi
  local free
  free=$(df -Pk "$(dirname "$TB_HOME")" | awk 'NR==2 {print int($4/1024/1024)}')
  if [ "$free" -ge 30 ]; then ok "wolne miejsce: ${free} GB"; else warn "wolne miejsce: ${free} GB (pełna macierz potrzebuje ok. 30 GB)"; fi
  [ "$missing" = 0 ] || die "brakuje wymaganych narzędzi"
}

# ---------------------------------------------------------------- install
# github_api fetches a GitHub API URL, with a token when one is available
# (unauthenticated calls from shared CI runners hit the rate limit).
github_api() {
  local token=${GITHUB_TOKEN:-${GH_TOKEN:-}}
  if [ -n "$token" ]; then
    curl -fsSL -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $token" "$1"
  else
    curl -fsSL -H 'Accept: application/vnd.github+json' "$1"
  fi
}

download_tbench() {
  local plat repo=https://github.com/$GH_OWNER/ticketbench-cli url sums asset tag
  plat=$(platform)
  case "$TB_CHANNEL" in
    edge)
      # Snapshot archive names contain the commit, so ask the API.
      local json
      json=$(github_api "https://api.github.com/repos/$GH_OWNER/ticketbench-cli/releases/tags/edge") \
        || die "nie mogę pobrać informacji o wydaniu edge (limit API? ustaw GITHUB_TOKEN)"
      url=$(printf '%s\n' "$json" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(http[^"]*\)"/\1/' \
            | grep "_${plat}\.\(tar\.gz\|zip\)$" | head -1)
      sums=$repo/releases/download/edge/checksums.txt
      ;;
    *)
      # Versioned releases: no API call, the tag comes from the redirect of
      # /releases/latest and the archive name follows the GoReleaser pattern.
      if [ "$TB_CHANNEL" = latest ]; then
        tag=$(curl -fsSI "$repo/releases/latest" | tr -d '\r' | awk 'tolower($1)=="location:" {print $2}' | sed 's#.*/tag/##')
        [ -n "$tag" ] || die "nie mogę ustalić najnowszego wydania tbench"
      else
        tag=$TB_CHANNEL
      fi
      local ext=tar.gz
      case "$plat" in windows_*) ext=zip ;; esac
      url=$repo/releases/download/$tag/tbench_${tag#v}_${plat}.$ext
      sums=$repo/releases/download/$tag/checksums.txt
      ;;
  esac
  [ -n "$url" ] || die "wydanie $TB_CHANNEL nie ma archiwum dla $plat"
  asset=$(printf '%s' "${url##*/}" | sed 's/%2B/+/g')
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/$asset" "$url" || die "nie mogę pobrać $url"
  if curl -fsSL -o "$tmp/checksums.txt" "$sums"; then
    local want got
    want=$(grep " $asset\$" "$tmp/checksums.txt" | awk '{print $1}' || true)
    [ -n "$want" ] || die "brak $asset w checksums.txt"
    if have sha256sum; then got=$(sha256sum "$tmp/$asset" | awk '{print $1}'); else got=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}'); fi
    [ "$want" = "$got" ] || die "suma kontrolna $asset się nie zgadza"
    ok "suma SHA-256 zgodna"
  fi
  mkdir -p "$BIN"
  case "$asset" in
    *.zip) (cd "$tmp" && unzip -q "$asset") ;;
    *)     tar -xzf "$tmp/$asset" -C "$tmp" ;;
  esac
  local exe=$tmp/tbench
  [ -f "$exe" ] || exe=$tmp/tbench.exe
  [ -f "$exe" ] || die "archiwum $asset nie zawiera tbench"
  cp "$exe" "$TBENCH" && chmod 0755 "$TBENCH"
  rm -rf "$tmp"
  ok "tbench $("$TBENCH" version | awk '{print $2}') ($asset)"
}

cmd_install() {
  say "Katalog roboczy: $TB_HOME"
  if [ -d "$TB_HOME/.git" ]; then
    git -C "$TB_HOME" pull --ff-only --quiet || warn "nie udało się zaktualizować $TB_HOME (lokalne zmiany?)"
    ok "ticketbench: $(git -C "$TB_HOME" rev-parse --short HEAD)"
  else
    git clone --quiet "$GLUE_URL" "$TB_HOME"
    ok "ticketbench: sklonowane ($(git -C "$TB_HOME" rev-parse --short HEAD))"
  fi
  if [ "$TB_UPDATE" = 1 ]; then
    git -C "$TB_HOME" submodule update --init --remote --quiet
  else
    git -C "$TB_HOME" submodule update --init --quiet
  fi
  for r in $SUBMODULES; do
    ok "$r: $(git -C "$TB_HOME/$r" rev-parse --short HEAD) (github.com/$GH_OWNER/ticketbench-$r)"
  done
  mkdir -p "$RESULTS"
  if [ "$TB_SOURCE" = 1 ]; then
    say "Buduję tbench ze źródeł"
    have go || die "TB_SOURCE=1 wymaga Go"
    mkdir -p "$BIN"
    (cd "$TB_HOME/cli" && GOWORK=off CGO_ENABLED=0 go build -trimpath -o "$TBENCH" ./cmd/tbench)
    ok "tbench zbudowany"
    say "Buduję obrazy serwisów ze źródeł"
    compose build
  else
    say "Pobieram tbench z GitHub Releases ($TB_CHANNEL)"
    download_tbench
    say "Pobieram obrazy z GHCR (tag $TB_VERSION)"
    compose pull --quiet
    ok "obrazy pobrane"
  fi
}

# ---------------------------------------------------------------- stack
cmd_up() {
  [ -f "$INFRA/docker-compose.yml" ] || die "brak $INFRA, uruchom: $0 install"
  say "Uruchamiam stos (bazy, serwisy, obserwowalność)"
  compose up -d --wait --wait-timeout 300
  cmd_ping
  cmd_urls
}

cmd_ping()   { say "Sprawdzam runner i store'y"; tb ping; }
cmd_status() { compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'; }
cmd_logs()   { compose logs --tail 200 -f "$@"; }
cmd_down()   { say "Zatrzymuję stos (dane w wolumenach zostają)"; compose down; }
cmd_destroy(){ say "Usuwam stos razem z wolumenami"; compose down -v --remove-orphans; }

cmd_urls() {
  cat <<EOF
  Jaeger      http://localhost:16686
  Grafana     http://localhost:3000   (pulpit ticketbench)
  Prometheus  http://localhost:9090
  Runner      localhost:$TB_RUNNER_PORT (gRPC)
EOF
}

# ---------------------------------------------------------------- benchmarks
run_matrix() {
  local config=$1; shift
  local run
  run=${TB_RUN:-$(date -u +%Y%m%d-%H%M%S)}
  local out=$RESULTS/$run
  say "Plan: $config"
  tb plan --config "$config" "$@" | tail -1
  say "Uruchamiam macierz, wyniki: $out"
  tb matrix --config "$config" --out "$out" "$@"
  ln -sfn "$out" "$RESULTS/latest"
  say "Raport tymczasowy"
  tb report "$out" --out "$out/report"
  ok "tabele i dane wykresów: $out/report"
}

cmd_smoke() { run_matrix "$INFRA/config/smoke.yaml" "$@"; }

cmd_bench() {
  local config=$INFRA/config/matrix.yaml
  if [ "${1:-}" = "--config" ]; then config=$2; shift 2; fi
  run_matrix "$config" "$@"
}

cmd_contend() { tb contend "$@"; }
cmd_run()     { tb run "$@"; }

cmd_report() {
  local run=${1:-$RESULTS/latest}
  [ -d "$run" ] || die "brak katalogu wyników $run"
  run=$(cd "$run" && pwd -P)
  local rep=$TB_HOME/report
  [ -d "$rep" ] || die "brak katalogu $rep, uruchom: $0 install"
  # The report plots 0.5M, 1M and 10M tickets; a smaller run (e.g. smoke)
  # only gets its own tables next to the results.
  local size
  for size in 500000 1000000 10000000; do
    if ! grep -q ",$size," "$run/scenarios.csv" 2>/dev/null; then
      warn "wyniki w $run nie zawierają rozmiaru $size: sprawozdanie wymaga pełnej macierzy ($0 bench)"
      say "Generuję tylko tabele obok wyników"
      tb report "$run" --out "$run/report"
      ok "tabele i dane wykresów: $run/report"
      return 0
    fi
  done
  say "Generuję tabele i wykresy z $run"
  rm -rf "$rep/generated"
  tb report "$run" --out "$rep/generated"
  # Keep the raw results next to the report (unless they already are there).
  if [ "$run" != "$(cd "$rep" && pwd -P)/data/results" ]; then
    rm -rf "$rep/data/results"
    mkdir -p "$rep/data" && cp -R "$run" "$rep/data/results"
  fi
  if have tectonic; then
    say "Kompiluję PDF (tectonic)"
    (cd "$rep" && for f in sprawozdanie podsumowanie prezentacja; do tectonic -X compile "$f.tex"; done)
  elif have latexmk; then
    say "Kompiluję PDF (latexmk -xelatex)"
    (cd "$rep" && latexmk -xelatex -interaction=nonstopmode sprawozdanie.tex podsumowanie.tex prezentacja.tex)
  else
    warn "brak tectonic i latexmk: PDF pominięty (brew install tectonic albo apt install latexmk texlive-xetex)"
    return 0
  fi
  ok "PDF: $rep/sprawozdanie.pdf, $rep/podsumowanie.pdf, $rep/prezentacja.pdf"
}

cmd_all() {
  cmd_doctor
  cmd_install
  cmd_up
  cmd_smoke "$@"
  say "Gotowe. Pełna macierz: $0 bench, sprawozdanie: $0 report"
}

cmd_help() {
  cat <<EOF
${B}ticketbench.sh${N}: benchmark PostgreSQL, MariaDB, MongoDB i Valkey

Użycie: $0 <polecenie> [argumenty]

  doctor               sprawdza narzędzia, pamięć Dockera, porty i miejsce na dysku
  install              klonuje ticketbench z submodułami, pobiera tbench i obrazy z GitHuba
  up                   uruchamia stos i sprawdza wszystkie serwisy
  ping | status | urls stan runnera i store'ów, kontenery, adresy UI
  smoke                krótka macierz (20 tys. biletów, ok. 1 min)
  bench [--config f]   pełna macierz (domyślnie infra/config/matrix.yaml), dodatkowe
                       flagi idą do tbench matrix, np. --sizes 500k,1M --stores postgres
  run ... | contend ...  pojedyncze polecenia tbench (tbench run --help)
  report [katalog]     tabele, wykresy i PDF z wyników (domyślnie results/latest)
  logs [serwis]        logi kontenerów
  down | destroy       zatrzymanie stosu, destroy usuwa też dane
  all                  doctor + install + up + smoke

Zmienne środowiskowe:
  TB_HOME=$TB_HOME
  TB_VERSION=$TB_VERSION   tag obrazów w GHCR
  TB_CHANNEL=$TB_CHANNEL   wydanie tbench: latest, edge, v0.1.0
  TB_SOURCE=$TB_SOURCE     1 = budowanie obrazów i tbench ze źródeł (wymaga Go)
  TB_UPDATE=$TB_UPDATE     1 = submoduły na najnowszy main
  TB_RUNNER_PORT=$TB_RUNNER_PORT
EOF
}

main() {
  local cmd=${1:-help}
  [ $# -gt 0 ] && shift
  case "$cmd" in
    doctor|install|up|ping|status|urls|smoke|bench|run|contend|report|logs|down|destroy|all|help) "cmd_$cmd" "$@" ;;
    -h|--help) cmd_help ;;
    *) cmd_help; die "nieznane polecenie: $cmd" ;;
  esac
}

main "$@"
