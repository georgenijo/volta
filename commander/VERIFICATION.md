# Local verification receipt — 2026-10-07

Host: implementation MacBook, Darwin/arm64. Worktree:
`/Users/macbook/code/volta-wt/commander`, branch `feat/commander`.
Go 1.27.1 was fetched to `/tmp/volta-tools/go` and its official archive SHA-256
verified (`ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12`).
Docker Compose v5.6.0 CLI was fetched to `/tmp/volta-tools/docker-compose` and
verified against its release checksum. No system installation or daemon launch.

## Go and executable acceptance

Commands run from `commander/`:

```sh
/tmp/volta-tools/go/bin/go test -race -count=1 -json ./... \
  > /tmp/volta-tools/commander-test-results.jsonl
/tmp/volta-tools/go/bin/go vet ./...
GO=/tmp/volta-tools/go/bin/go python3 scripts/smoke-stub.py
/tmp/volta-tools/go/bin/go test -cover ./...
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 /tmp/volta-tools/go/bin/go build \
  -trimpath -o /tmp/volta-tools/commander-linux-amd64 ./cmd/commander
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 /tmp/volta-tools/go/bin/go build \
  -trimpath -o /tmp/volta-tools/commander-linux-arm64 ./cmd/commander
```

Results: 26 top-level tests / 67 tests including subtests passed; zero failures,
race-enabled package elapsed 4.848 seconds. Core package statement coverage
82.5%; executable entry points are exercised by the separate smoke run, not
included in that coverage percentage. `go vet` exited 0. Both Linux binary builds
exited 0.

Smoke output:

```text
PASS: stub PKCE login, command, replay, restart replay, audit privacy, disconnect; no Tesla requests
```

Meaningful cases include S256 verifier validation, expired/wrong/replayed state,
single concurrent refresh and rotation, encrypted/tampered/wrong-key state,
storage-write failure recovery without consuming a refresh token twice, complete
command mapping, strict parameters, unauthenticated/public-surface rejection,
bounded wake/retry and offline timeout, key-missing/error mapping, no blind retry
after ambiguous errors, concurrent/restart/pending idempotency, persisted limits,
public-key/private-PEM separation, verified TLS and refusal to follow redirects,
and Tesla-specific/RFC Alt-Svc regional discovery with allowlisted hosts.
Review regression cases cover offline→online wake, bounded command queue,
cancellation before acceptance and mid-send, definitive dial failures, same-key
429 recovery, token lifetime margin, detached token copies and disabled-command
account linking.

## Official proxy build

```sh
/tmp/volta-tools/go/bin/go mod download -json \
  github.com/teslamotors/vehicle-command@v0.4.1
# Run in the returned module Dir (as the Docker proxy build does):
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 /tmp/volta-tools/go/bin/go build \
  -trimpath -o /tmp/volta-tools/tesla-http-proxy-linux-amd64 ./cmd/tesla-http-proxy
```

Exited 0. Downloaded module checksum:
`h1:J4ne/TNGwgodJLYJDLm/hjoygXyQ/bpqO/EiCaeoobM=`. This establishes compilation
of the pinned upstream proxy with CGO disabled, not Tesla transport execution.

## Deployment/key checks

Using a temporary `.env` containing only synthetic internal/encryption values,
`COMMANDER_VEHICLES={}`, and default disabled stub mode, from repo root:

```sh
/tmp/volta-tools/docker-compose --env-file <temporary-fixture.env> \
  -f deploy/commander/compose.yaml config --quiet
/tmp/volta-tools/docker-compose --env-file <temporary-fixture.env> \
  -f deploy/commander/compose.yaml --profile live config --format json
./commander/scripts/generate-keys.sh <temporary-absolute-key-directory>
```

Exited 0; parsed the rendered Compose JSON and checked both published ports bind
host 127.0.0.1, commander/proxy namespaces are independent with an internal
signing network and separate proxy egress, and the proxy publishes no host ports.
Key checks verified matching public export, 0600 private files, localhost and
Docker service DNS certificate trust/names, and overwrite refusal (exit 2).
Generated private keys remained outside Git in a removed temporary directory.
The source-only `Dockerfile.dockerignore` was checked with Moby patternmatcher
v0.6.0 (`go run -mod=mod .` in `/tmp/volta-tools/ignore-check`) against synthetic
source, `.env`, `.env.local`, PEM, bare key filenames, audit logs, binaries,
README, state, lock and unrelated-repo paths: expected inclusions and exclusions
all passed. This check used only synthetic path strings; no files were sent to
a builder. Regional tests also cover parameterized/multiple Alt-Svc headers and
reject destinations with untrusted suffixes or paths.

Limitations: no Docker daemon is installed, so images/containers were not built
or run. No ubuntu deployment, Tesla account login/refresh, partner registration,
virtual key pairing, physical vehicle execution, or actual Tesla PKCE enforcement
was exercised. Live prerequisite/acceptance gates are in `INTEGRATION.md`.
