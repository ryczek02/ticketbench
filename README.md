# ticketbench

Benchmark of PostgreSQL 17, MariaDB 11.8, MongoDB 8.0 and Valkey 8.1 on a
ticket reservation workload. A course project for "Zaawansowane technologie
baz danych" at Politechnika Krakowska, by Łukasz Ryczko and Łukasz Pacholec.

The workload covers 24 CRUD scenarios plus 3 on JSON data, on 500 thousand,
1 million and 10 million tickets, each run without and with secondary
indexes. On top of that, a contention test runs 1 to 1000 clients against
the same 500 seats, and the report checks the two hypotheses from the
project brief against the measurements.

## Quick start

```
git clone --recursive https://github.com/ryczek02/ticketbench
cd ticketbench
./ticketbench.sh all       # check tools, pull everything from GitHub, start the stack, smoke test
./ticketbench.sh bench     # full matrix: 0.5M, 1M and 10M tickets
./ticketbench.sh report    # tables, plots and report/sprawozdanie.pdf
```

The step-by-step guide is [docs/runbook.html](docs/runbook.html). It covers
requirements, every command of `ticketbench.sh`, the result files, tracing
and troubleshooting. To view it rendered:
[htmlpreview](https://htmlpreview.github.io/?https://github.com/ryczek02/ticketbench/blob/main/docs/runbook.html).

## What is in this repository

| Path | Contents |
|---|---|
| `ticketbench.sh` | One program for everything: `doctor`, `install`, `up`, `smoke`, `bench`, `report`, `down` |
| `docs/runbook.html` | Runbook in Polish |
| `report/` | Report in LaTeX (Polish): `sprawozdanie.pdf`, slides `prezentacja.pdf` (Beamer), study notes `podsumowanie.pdf` |
| `report/data/results/` | Raw results of the run used in the report (CSV, query plans, `meta.json`) |
| `report/generated/` | Tables, plot data and values produced by `tbench report` from the raw results |
| `contracts/`, `services/`, `cli/`, `infra/` | Git submodules, one per component repository |
| `go.work` | Lets the three Go modules build against each other locally |

## Repositories

| Repository | Contents |
|---|---|
| [ticketbench-contracts](https://github.com/ryczek02/ticketbench-contracts) | gRPC contracts, domain model, deterministic data generator, scenarios, OpenTelemetry setup |
| [ticketbench-services](https://github.com/ryczek02/ticketbench-services) | `bench-runner` and one gRPC store service per database, conformance tests, binaries, images |
| [ticketbench-cli](https://github.com/ryczek02/ticketbench-cli) | `tbench`: runs plans, writes CSV, generates LaTeX tables and pgfplots data |
| [ticketbench-infra](https://github.com/ryczek02/ticketbench-infra) | Docker Compose, collector, Jaeger, Prometheus, Grafana, matrices, Ansible |

Binaries for linux, darwin and windows (amd64, arm64) are attached to the
releases of `ticketbench-services` and `ticketbench-cli`. The `edge`
prerelease follows `main`, `v*` releases are versioned. Images live in
`ghcr.io/ryczek02/ticketbench-*`.

## Architecture

```
tbench ──gRPC──> bench-runner ──gRPC──> store-postgres ──> PostgreSQL
  │ root span      │                ├──> store-mariadb  ──> MariaDB
  │ traceparent    │                ├──> store-mongo    ──> MongoDB (rs0)
  │                │                └──> store-valkey   ──> Valkey
  └───── OTLP ─────┴──> otel-collector ──> Jaeger, Prometheus ──> Grafana
```

The CLI starts one trace per segment (one size on one database). The W3C
`traceparent` header carries it through the runner to the store service and
into the database driver spans. Every result row stores the trace id, so any
measurement leads to its trace in Jaeger.

Stores generate the dataset themselves from the seed. The bulk data never
crosses gRPC, and a checksum confirms that all four databases hold the same
rows. Timings are taken inside the store around the database call. The
runner records the end-to-end time next to it, which shows the cost of the
gRPC hop separately.

## CI

| Repository | Checks |
|---|---|
| ticketbench | shellcheck, W3C validation of the runbook, tables rebuilt from raw results must match, PDF build, end-to-end run of `ticketbench.sh` (install, up, smoke) |
| contracts | buf lint, breaking change check, generated code check, tests, benchmarks |
| services | conformance suite on the four real databases, GoReleaser binaries, multi-arch images on GHCR |
| cli | tests, GoReleaser binaries, image |
| infra | compose validation, ansible-lint, end-to-end smoke run provisioned by Ansible |

## License

MIT.
