#!/usr/bin/env bash
# Render every stack x agent-tool combination, then for each stack:
#   1. the generated project passes its own verify command, and
#   2. the guardrails reject a seeded violation (escape hatch, layer leak, skipped test).
# Usage: tests/render-all.sh [stack...]      (default: typescript python dotnet go rust)
# Needs: uv, git, bash >= 4 (associative arrays; Git Bash and Linux are fine, macOS /bin/bash 3.2 is not), Docker (running); node/npm for typescript; .NET 10 SDK for dotnet; Go >= 1.26 for go; rustup + cargo-deny for rust.
set -uo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/project-starter-XXXXXX")
stacks=("$@")
[ ${#stacks[@]} -gt 0 ] || stacks=(typescript python dotnet go rust)
failures=0

pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; failures=$((failures + 1)); }

render() { # render <stack> <tools-json> <dest> [extra copier args...]
  uvx copier copy --trust --defaults --quiet \
    -d project_name=demo-app -d stack="$1" -d "agent_tools=$2" "${@:4}" "$repo" "$3" >/dev/null 2>&1
}

verify() { # verify <label> <command-string>: must succeed; show the tail of the output when it does not
  local out
  if out=$(bash -c "$2" 2>&1); then pass "$1"; else fail "$1"; printf '%s\n' "$out" | tail -n 15 | sed 's/^/      /'; fi
}

expect_fail() { # expect_fail <label> <command...>
  if "${@:2}" >/dev/null 2>&1; then fail "$1 (should have failed)"; else pass "$1 rejected"; fi
}

seeded() { # seeded <label> <file> <text-to-append> <command...>: append, expect the command to fail, restore
  local file=$2
  printf '%b' "$3" >> "$file"
  expect_fail "$1" "${@:4}"
  git checkout -q -- "$file"
}

seeded_new() { # seeded_new <label> <new-file> <content> <command...>: create the file, expect the command to fail, delete it
  local file=$2
  mkdir -p "$(dirname "$file")"
  printf '%b' "$3" > "$file"
  expect_fail "$1" "${@:4}"
  rm -f "$file"
}

docker_vol() { # host path of the current directory for `docker run -v` (Git Bash on Windows needs C:/...)
  pwd -W 2>/dev/null || pwd
}

image_runs_as_non_root() { # image_runs_as_non_root <image>: the image's configured user is set and not root
  local user
  user=$(docker image inspect -f '{{.Config.User}}' "$1") || return 1
  case "$user" in "" | root | root:* | 0 | 0:*) return 1 ;; esac
}

container_checks() { # container_checks <stack>: run inside the rendered project (containerize=true)
  local vol image="project-starter-$1" hadolint="hadolint/hadolint:v2.15.1"
  vol=$(docker_vol)
  export MSYS_NO_PATHCONV=1
  verify "hadolint" "docker run --rm -v '$vol:/w' -w /w $hadolint hadolint Dockerfile"
  verify "check-dockerfile" "bash ci/check-dockerfile.sh"
  # This render serves HTTP, so the smoke run starts the hardened container and waits for /healthz.
  verify "docker build + hardened smoke run (non-root, read-only, /healthz)" \
    "docker build -q -t $image . && bash ci/dast.sh $image --smoke && $(declare -f image_runs_as_non_root); image_runs_as_non_root $image"
  sed -i '0,/^FROM \([^ :]*\):[^ ]*/s//FROM \1:latest/' Dockerfile
  expect_fail "hadolint: :latest base image" docker run --rm -v "$vol:/w" -w /w $hadolint hadolint Dockerfile
  git checkout -q -- Dockerfile
  seeded "hadolint: final stage runs as root" Dockerfile 'USER root\n' docker run --rm -v "$vol:/w" -w /w $hadolint hadolint Dockerfile
  sed -i '/^USER /d' Dockerfile
  expect_fail "check-dockerfile: no USER in final stage" bash ci/check-dockerfile.sh
  git checkout -q -- Dockerfile
  seeded "hadolint: inline ignore pragma" Dockerfile '# hadolint ignore=DL3007\nFROM busybox:latest AS extra\nUSER 1000:1000\n' docker run --rm -v "$vol:/w" -w /w $hadolint hadolint Dockerfile
  unset MSYS_NO_PATHCONV
}

datastore_checks() { # datastore_checks <stack>: rendered with datastores=[postgres, redis] and containerize=true
  local sqlfluff="uvx -q sqlfluff==4.5.0" migration=migrations/0001_create_export_artifacts.sql
  verify "sqlfluff: migrations" "$sqlfluff lint migrations"
  seeded "sqlfluff: lower-case keywords" "$migration" '\nselect body from export_artifacts;\n' $sqlfluff lint migrations
  # Append-only migrations: adding a file passes the ratchet, editing a merged one fails it.
  printf 'CREATE INDEX export_artifacts_created_at_idx ON export_artifacts (created_at);\n' > migrations/0002_index_created_at.sql
  git add migrations && git -c user.name=t -c user.email=t@t commit -qm "add migration"
  verify "ratchet: new migration allowed" "bash ci/guardrail-ratchet.sh base"
  git -c user.name=t -c user.email=t@t revert -q --no-edit HEAD
  printf '\n-- edited after merge\n' >> "$migration"
  git -c user.name=t -c user.email=t@t commit -qam "edit migration"
  expect_fail "ratchet: edited migration" bash ci/guardrail-ratchet.sh base
  git -c user.name=t -c user.email=t@t revert -q --no-edit HEAD
  # End to end: compose starts PostgreSQL + Redis (migrations applied) and the app; an HTTP request is stored
  # through the PostgreSQL adapter.
  local compose="docker compose -p ps-$1"
  $compose down -v >/dev/null 2>&1
  verify "compose: HTTP request is stored in PostgreSQL" \
    "$compose build app && $compose up -d --wait postgres mysql redis && $compose up -d app \
     && for _ in \$(seq 1 60); do curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break; sleep 1; done \
     && curl -fsS -X POST -H 'Content-Type: application/json' -d '{\"content\":\"id\\n1\\n\"}' http://127.0.0.1:8080/exports/compose-1/complete | grep -q 'exports/compose-1.csv' \
     && [ \"\$($compose exec -T postgres psql -U app -d app -tAc \"SELECT count(*) FROM export_artifacts WHERE job_id = 'compose-1'\")\" = 1 ]"
  # The MySQL service applied migrations/mysql through its init hook.
  verify "compose: MySQL migrations applied" \
    "[ \"\$($compose exec -T mysql mysql -uapp -plocal-dev-only app -N -e 'SELECT COUNT(*) FROM export_artifacts' 2>/dev/null)\" = 0 ]"
  $compose down -v >/dev/null 2>&1
}

mariadb_checks() { # mariadb_checks <stack> <install> <integration-command>: MariaDB reuses the MySQL adapter
  local dir="$work/$1-mariadb"
  render "$1" '["codex"]' "$dir" -d 'datastores=["mariadb"]' -d containerize=false || { fail "render mariadb"; return; }
  pushd "$dir" >/dev/null || return
  bash -c "$2" >/dev/null 2>&1
  verify "mariadb: adapter contract on a real MariaDB" "$3"
  popd >/dev/null || return
}

sqlserver_checks() { # sqlserver_checks <stack> <install> <integration-command> [seeded|seeded_new label file text command...]
  local dir="$work/$1-sqlserver"
  render "$1" '["codex"]' "$dir" -d 'datastores=["sqlserver"]' || { fail "render sqlserver"; return; }
  pushd "$dir" >/dev/null || return
  git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init
  bash -c "$2" >/dev/null 2>&1
  verify "sqlserver: adapter contract on a real SQL Server" "$3"
  if [ "$#" -gt 3 ]; then "$4" "${@:5}"; fi
  if [ "$1" = typescript ]; then
    # Stack-independent parts, checked once: T-SQL lint and the compose migrate job.
    local sqlfluff="uvx -q sqlfluff==4.5.0"
    verify "sqlfluff: T-SQL migrations" "$sqlfluff lint migrations"
    seeded "sqlfluff: lower-case T-SQL keywords" migrations/sqlserver/0001_create_export_artifacts.sql \
      '\nselect body from export_artifacts;\n' $sqlfluff lint migrations
    local compose="docker compose -p ps-sqlserver"
    $compose down -v >/dev/null 2>&1
    verify "compose: SQL Server migrate job creates the schema" \
      "$compose up -d --wait sqlserver && $compose run --rm sqlserver-migrate \
       && [ \"\$(MSYS_NO_PATHCONV=1 $compose exec -T sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P Local-dev-only-1 -C -d app -h -1 -W -Q 'SET NOCOUNT ON; SELECT COUNT(*) FROM export_artifacts' | tr -d '[:space:]')\" = 0 ]"
    $compose down -v >/dev/null 2>&1
  fi
  popd >/dev/null || return
}

mongodb_checks() { # mongodb_checks <stack> <install> <integration-command> [seeded|seeded_new label file text command...]
  local dir="$work/$1-mongodb"
  render "$1" '["codex"]' "$dir" -d 'datastores=["mongodb"]' -d http_api=true || { fail "render mongodb"; return; }
  pushd "$dir" >/dev/null || return
  git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init
  bash -c "$2" >/dev/null 2>&1
  verify "mongodb: adapter contract on a real MongoDB" "$3"
  if [ "$#" -gt 3 ]; then "$4" "${@:5}"; fi
  if [ "$1" = typescript ]; then
    # End to end once: compose wires MONGODB_URL into the app and an HTTP request lands in MongoDB.
    local compose="docker compose -p ps-mongodb"
    $compose down -v >/dev/null 2>&1
    verify "compose: HTTP request is stored in MongoDB" \
      "$compose build app && $compose up -d --wait mongodb && $compose up -d app \
       && for _ in \$(seq 1 60); do curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break; sleep 1; done \
       && curl -fsS -X POST -H 'Content-Type: application/json' -d '{\"content\":\"id\\n1\\n\"}' http://127.0.0.1:8080/exports/mongo-1/complete | grep -q 'exports/mongo-1.csv' \
       && [ \"\$($compose exec -T mongodb mongosh -u app -p local-dev-only --authenticationDatabase admin app --quiet --eval 'db.export_artifacts.countDocuments({job_id: \"mongo-1\"})')\" = 1 ]"
    $compose down -v >/dev/null 2>&1
  fi
  popd >/dev/null || return
}

dynamodb_e2e() { # dynamodb_e2e <compose>: an HTTP request lands in DynamoDB Local through the app
  local compose=$1 key='{"artifact_key":{"S":"exports/dyn-1.csv"}}'
  $compose build app && $compose up -d app || return 1
  for _ in $(seq 1 60); do curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break; sleep 1; done
  curl -fsS -X POST -H 'Content-Type: application/json' -d '{"content":"id\n1\n"}' \
    http://127.0.0.1:8080/exports/dyn-1/complete | grep -q 'exports/dyn-1.csv' || return 1
  [ "$($compose run --rm -T --entrypoint aws dynamodb-migrate dynamodb --endpoint-url http://dynamodb:8000 \
    get-item --table-name export_artifacts --key "$key" --query Item.job_id.S --output text 2>/dev/null | tr -d '\r')" = dyn-1 ]
}
export -f dynamodb_e2e

dynamodb_checks() { # dynamodb_checks <stack> <install> <integration-command> [seeded|seeded_new label file text command...]
  local dir="$work/$1-dynamodb"
  render "$1" '["codex"]' "$dir" -d 'datastores=["dynamodb"]' -d http_api=true || { fail "render dynamodb"; return; }
  pushd "$dir" >/dev/null || return
  git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init
  bash -c "$2" >/dev/null 2>&1
  verify "dynamodb: adapter contract on DynamoDB Local" "$3"
  if [ "$#" -gt 3 ]; then "$4" "${@:5}"; fi
  if [ "$1" = typescript ]; then
    local compose="docker compose -p ps-dynamodb"
    $compose down -v >/dev/null 2>&1
    verify "compose: HTTP request is stored in DynamoDB Local" "dynamodb_e2e '$compose'"
    $compose down -v >/dev/null 2>&1
  fi
  popd >/dev/null || return
}

cosmosdb_checks() { # cosmosdb_checks <stack> <install> <integration-command> [seeded|seeded_new label file text command...]
  local dir="$work/$1-cosmosdb"
  render "$1" '["codex"]' "$dir" -d 'datastores=["cosmosdb"]' -d http_api=true || { fail "render cosmosdb"; return; }
  pushd "$dir" >/dev/null || return
  git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init
  bash -c "$2" >/dev/null 2>&1
  verify "cosmosdb: adapter contract on the Cosmos DB emulator" "$3"
  if [ "$#" -gt 3 ]; then "$4" "${@:5}"; fi
  if [ "$1" = typescript ]; then
    # The emulator's well-known key in compose.yaml must not trip secret scanning (.gitleaks.toml allowlist).
    local vol gitleaks="zricethezav/gitleaks:v8.30.1"
    vol=$(docker_vol)
    export MSYS_NO_PATHCONV=1
    verify "gitleaks: Cosmos DB emulator key is allowlisted"       "docker run --rm -v '$vol:/repo' -w /repo $gitleaks git --config .gitleaks.toml --redact --exit-code 1 /repo"
    unset MSYS_NO_PATHCONV
    local compose="docker compose -p ps-cosmosdb"
    $compose down -v >/dev/null 2>&1
    verify "compose: HTTP request is stored in the Cosmos DB emulator" \
      "$compose build app && $compose up -d app \
       && for _ in \$(seq 1 90); do curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break; sleep 1; done \
       && curl -fsS -X POST -H 'Content-Type: application/json' -d '{\"content\":\"id\\n1\\n\"}' http://127.0.0.1:8080/exports/cosmos-1/complete | grep -q 'exports/cosmos-1.csv'"
    $compose down -v >/dev/null 2>&1
  fi
  popd >/dev/null || return
}

s3_checks() { # s3_checks <stack> <install> <integration-command> [seeded|seeded_new label file text command...]
  local dir="$work/$1-s3"
  render "$1" '["codex"]' "$dir" -d 'datastores=["s3"]' -d http_api=true || { fail "render s3"; return; }
  pushd "$dir" >/dev/null || return
  git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init
  bash -c "$2" >/dev/null 2>&1
  verify "s3: adapter contract on a local S3 server" "$3"
  if [ "$#" -gt 3 ]; then "$4" "${@:5}"; fi
  if [ "$1" = typescript ]; then
    local compose="docker compose -p ps-s3"
    $compose down -v >/dev/null 2>&1
    verify "compose: HTTP request is stored as an S3 object" \
      "$compose build app && $compose up -d app \
       && for _ in \$(seq 1 60); do curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break; sleep 1; done \
       && curl -fsS -X POST -H 'Content-Type: application/json' -d '{\"content\":\"id\\n1\\n\"}' http://127.0.0.1:8080/exports/s3-1/complete | grep -q 'exports/s3-1.csv' \
       && $compose exec -T app node -e \"fetch('http://s3:9090/artifacts/exports/s3-1.csv').then(r => process.exit(r.ok ? 0 : 1))\""
    $compose down -v >/dev/null 2>&1
  fi
  popd >/dev/null || return
}

oracle_checks() { # oracle_checks <stack> <install> <integration-command> [seeded|seeded_new label file text command...]
  local dir="$work/$1-oracle"
  render "$1" '["codex"]' "$dir" -d 'datastores=["oracle"]' || { fail "render oracle"; return; }
  pushd "$dir" >/dev/null || return
  git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init
  bash -c "$2" >/dev/null 2>&1
  verify "oracle: adapter contract on Oracle Database Free" "$3"
  if [ "$#" -gt 3 ]; then "$4" "${@:5}"; fi
  if [ "$1" = typescript ]; then
    # Stack-independent parts, checked once: Oracle SQL lint and the compose migrate job.
    local sqlfluff="uvx -q sqlfluff==4.5.0"
    verify "sqlfluff: Oracle migrations" "$sqlfluff lint migrations"
    seeded "sqlfluff: lower-case Oracle keywords" migrations/oracle/0001_create_export_artifacts.sql \
      '\nselect body from export_artifacts;\n' $sqlfluff lint migrations
    local compose="docker compose -p ps-oracle"
    $compose down -v >/dev/null 2>&1
    verify "compose: Oracle migrate job creates the schema" \
      "$compose up -d --wait oracle && $compose run --rm oracle-migrate \
       && [ \"\$(printf 'SET HEADING OFF FEEDBACK OFF\nSELECT COUNT(*) FROM export_artifacts;\n' | $compose exec -T oracle sqlplus -s app/local-dev-only@//localhost:1521/FREEPDB1 | tr -d '[:space:]')\" = 0 ]"
    $compose down -v >/dev/null 2>&1
  fi
  popd >/dev/null || return
}

http_checks() { # http_checks <stack> <e2e-command> <file> <sed-expression>: rendered with http_api=true
  local image="project-starter-$1"
  verify "playwright: API tests against the real server" "$2"
  verify "zap: baseline scan of the running container" "bash ci/dast.sh $image"
  # Drop one security header: the ZAP scan must fail the build.
  sed -i "$4" "$3"
  expect_fail "zap: missing X-Content-Type-Options" bash -c "docker build -q -t $image-seed . >/dev/null && bash ci/dast.sh $image-seed"
  git checkout -q -- "$3"
}

frontend_checks() { # frontend_checks <framework>: a separate TypeScript render with that UI (ADR 0005)
  local fw=$1 dir="$work/typescript-$1" image="project-starter-web-$1" vol
  render typescript '["claude"]' "$dir" -d frontend="$fw" || { fail "render frontend=$fw"; return; }
  pushd "$dir" >/dev/null || return
  git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm base
  npm install --no-audit --no-fund >/dev/null 2>&1
  verify "$fw: npm run verify" "npm run verify"
  npx playwright install chromium >/dev/null 2>&1
  verify "$fw: browser flows + axe (Playwright)" "npm run test:ui"
  vol=$(docker_vol)
  export MSYS_NO_PATHCONV=1
  verify "$fw: hadolint Dockerfile.web" "docker run --rm -v '$vol:/w' -w /w hadolint/hadolint:v2.15.1 hadolint Dockerfile.web"
  verify "$fw: check-dockerfile Dockerfile.web" "bash ci/check-dockerfile.sh Dockerfile.web"
  verify "$fw: web image smoke (non-root, read-only, /healthz)" \
    "docker build -q -f Dockerfile.web -t $image . && bash ci/dast.sh $image --smoke && $(declare -f image_runs_as_non_root); image_runs_as_non_root $image"
  verify "$fw: zap baseline of the web UI (from /)" "DAST_PATH=/ bash ci/dast.sh $image"
  local csp_file=nginx.conf csp_sed='/Content-Security-Policy/d'
  if [ "$fw" = nextjs ]; then csp_file=src/proxy.ts csp_sed='/response.headers.set("Content-Security-Policy", csp);/d'; fi
  sed -i "$csp_sed" "$csp_file"
  expect_fail "$fw: zap: missing Content-Security-Policy" bash -c "docker build -q -f Dockerfile.web -t $image-seed . >/dev/null && DAST_PATH=/ bash ci/dast.sh $image-seed"
  git checkout -q -- "$csp_file"
  unset MSYS_NO_PATHCONV
  "frontend_seeds_$fw"
  popd >/dev/null || return
}

frontend_seeds_vue() {
  seeded "vue: framework imported in application" src/application/complete-export.ts '
import { ref } from "vue";
export const state = ref;
' npm run arch
  seeded_new "vue: image without alt text (vuejs-accessibility)" src/ui/Logo.vue '<template>
  <img src="/logo.png">
</template>
' npm run lint
  seeded_new "vue: v-html (XSS)" src/ui/Raw.vue '<script setup lang="ts">
defineProps<{ html: string }>();
</script>

<template>
  <div v-html="html" />
</template>
' npm run lint
}

frontend_seeds_nextjs() {
  frontend_seeds_react
  seeded_new "nextjs: synchronous script (@next/next)" src/app/legacy/page.tsx 'import type { JSX } from "react";

export default function Legacy(): JSX.Element {
  return <script src="/legacy.js" />;
}
' npm run lint
}

frontend_seeds_angular() {
  seeded "angular: framework imported in application" src/application/complete-export.ts '
import { signal } from "@angular/core";
export const state = signal;
' npm run arch
  seeded_new "angular: image without alt text (template accessibility)" src/ui/logo.component.ts 'import { ChangeDetectionStrategy, Component } from "@angular/core";

@Component({
  selector: "app-logo",
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `<img src="/logo.png" />`,
})
export class LogoComponent {}
' npm run lint
  seeded_new "angular: click without keyboard support (template accessibility)" src/ui/tile.component.ts 'import { ChangeDetectionStrategy, Component } from "@angular/core";

@Component({
  selector: "app-tile",
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `<div (click)="open()">Open</div>`,
})
export class TileComponent {
  protected open(): void {
    return;
  }
}
' npm run lint
}

frontend_seeds_react-native() {
  seeded "react-native: framework imported in application" src/application/complete-export.ts '\nimport { Platform } from "react-native";\nexport const platform = Platform;\n' npm run arch
  seeded_new "react-native: touchable without an accessible name" src/ui/Tap.tsx 'import type { JSX } from "react";\nimport { Pressable, Text } from "react-native";\n\nexport function Tap(): JSX.Element {\n  return (\n    <Pressable role="button" onPress={() => undefined}>\n      <Text>Go</Text>\n    </Pressable>\n  );\n}\n' npm run lint
  seeded_new "react-native: image without alt text" src/ui/Logo.tsx 'import type { JSX } from "react";\nimport { Image } from "react-native";\n\nexport function Logo(): JSX.Element {\n  return <Image source={{ uri: "/logo.png" }} />;\n}\n' npm run lint
}

frontend_seeds_react() {
  seeded "react: framework imported in application" src/application/complete-export.ts '\nimport { useState } from "react";\nexport const hook = useState;\n' npm run arch
  seeded "react: image without alt text (jsx-a11y)" src/ui/App.tsx '\nexport function Logo(): JSX.Element {\n  return <img src="/logo.png" />;\n}\n' npm run lint
  seeded "react: hook called conditionally (rules-of-hooks)" src/ui/App.tsx '\nexport function Broken({ on }: { readonly on: boolean }): JSX.Element {\n  if (on) {\n    useState(0);\n  }\n  return <p />;\n}\n' npm run lint
}

secret_checks() { # secret_checks: gitleaks is clean on the render and rejects a committed token
  local vol gitleaks="zricethezav/gitleaks:v8.30.1"
  vol=$(docker_vol)
  export MSYS_NO_PATHCONV=1
  verify "gitleaks: clean history" "docker run --rm -v '$vol:/repo' -w /repo $gitleaks git --config .gitleaks.toml --redact --exit-code 1 /repo"
  git switch -q -c leak
  printf 'GITHUB_TOKEN=ghp_%s\n' "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)" > leaked.env
  git add -f leaked.env && git -c user.name=t -c user.email=t@t commit -qm leak
  expect_fail "gitleaks: committed token" docker run --rm -v "$vol:/repo" -w /repo $gitleaks git --config .gitleaks.toml --redact --exit-code 1 /repo
  git switch -q main && git branch -q -D leak
  unset MSYS_NO_PATHCONV
}

# Each stack's own verify command (the generated AGENTS.md "Verify your work" step).
declare -A verify_cmd=(
  [typescript]="npm run verify"
  [python]="uv run pyright && uv run ruff check . && uv run ruff format --check . && uv run lint-imports && uv run pytest -q"
  [dotnet]='dotnet build && dotnet format --verify-no-changes --no-restore && dotnet test --no-build --filter-not-trait "Category=Integration" --filter-not-trait "Category=E2E"'
  [go]="go vet ./... && go tool golangci-lint run && go test ./..."
  [rust]="cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && bash ci/check-layers.sh && cargo test --workspace"
)
declare -A install_cmd=(
  [typescript]="npm install --no-audit --no-fund" [python]="uv sync" [dotnet]="dotnet restore" [go]="go mod tidy" [rust]="cargo fetch -q"
)

default_verify() { # default_verify <stack>: the claude-only render keeps every optional answer at its default
  # (no datastores, no HTTP API, no frontend); what most users get must pass its own verify too.
  pushd "$work/$1-claude" >/dev/null || return
  git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm base && git branch -q base
  bash -c "${install_cmd[$1]}" >/dev/null 2>&1
  verify "defaults: $1 verify" "${verify_cmd[$1]}"
  popd >/dev/null || return
}

for stack in "${stacks[@]}"; do
  echo "== $stack"

  # Agent-tool combinations: only the file set changes.
  # The both-tools render also sets a guardrail owner; the others leave it empty (no CODEOWNERS).
  for tools in '["claude"]' '["codex"]' '["claude","codex"]'; do
    d="$work/$stack-$(echo "$tools" | tr -dc 'a-z,')"
    # The both-tools render also wires in every datastore and the HTTP API; it gets the full verification below.
    if [ "$tools" = '["claude","codex"]' ]; then
      owner_args=(-d guardrail_owner=@demo-org/platform -d 'datastores=["postgres","mysql","redis"]' -d http_api=true)
    else
      owner_args=()
    fi
    # The codex-only render opts out of containers; the others keep the default (containerize=true).
    if [ "$tools" = '["codex"]' ]; then container_args=(-d containerize=false); else container_args=(); fi
    render "$stack" "$tools" "$d" "${owner_args[@]}" "${container_args[@]}" || { fail "render $tools"; continue; }
    if [ ${#container_args[@]} -gt 0 ]; then
      if [ ! -e "$d/Dockerfile" ] && [ ! -e "$d/compose.yaml" ] && [ ! -e "$d/.hadolint.yaml" ] && [ ! -e "$d/ci/check-dockerfile.sh" ] \
        && ! grep -q 'container:' "$d/.github/workflows/ci.yml" && ! grep -q 'docker' "$d/.github/dependabot.yml"; then
        pass "no container files without containerize ($tools)"
      else
        fail "container files generated with containerize=false ($tools)"
      fi
    else
      [ -f "$d/Dockerfile" ] && [ -f "$d/.hadolint.yaml" ] && grep -q '\.hadolint\.yaml' "$d/AGENTS.md" \
        && pass "container files ($tools)" || fail "container files missing or unprotected ($tools)"
    fi
    [ -f "$d/.gitleaks.toml" ] && grep -q 'gitleaks' "$d/.github/workflows/ci.yml" && pass "secret scan configured ($tools)" || fail "secret scan missing ($tools)"
    if [ ${#owner_args[@]} -gt 0 ]; then
      [ -f "$d/migrations/0001_create_export_artifacts.sql" ] && grep -q '\.sqlfluff' "$d/AGENTS.md" && grep -q 'integration:' "$d/.github/workflows/ci.yml"         && pass "datastore files ($tools)" || fail "datastore files missing or unprotected ($tools)"
    else
      [ ! -e "$d/migrations" ] && [ ! -e "$d/.sqlfluff" ] && ! grep -q 'integration:' "$d/.github/workflows/ci.yml" && [ -f "$d/docs/adr/0003-datastores.md" ] && pass "no datastore files without datastores ($tools)" || fail "datastore files generated without datastores ($tools)"
    fi
    if [ ${#owner_args[@]} -gt 0 ]; then
      [ -f "$d/ci/dast.sh" ] && [ -f "$d/docs/adr/0004-http-api.md" ] && grep -q '\.zap/rules\.tsv' "$d/AGENTS.md" \
        && grep -q 'e2e:' "$d/.github/workflows/ci.yml" && grep -q 'dast:' "$d/.github/workflows/ci.yml" \
        && pass "http api files ($tools)" || fail "http api files missing or unprotected ($tools)"
    else
      [ ! -e "$d/ci/dast.sh" ] && [ ! -e "$d/.zap" ] && [ ! -e "$d/docs/adr/0004-http-api.md" ] && ! grep -q 'dast:' "$d/.github/workflows/ci.yml" \
        && pass "no http api files without http_api ($tools)" || fail "http api files generated without http_api ($tools)"
    fi
    if [ ${#owner_args[@]} -gt 0 ]; then
      grep -q '@demo-org/platform' "$d/.github/CODEOWNERS" 2>/dev/null && pass "CODEOWNERS with owner ($tools)" || fail "CODEOWNERS missing ($tools)"
    else
      if [ ! -e "$d/.github/CODEOWNERS" ] && ! grep -rIq '@your-org\|owned by  ' "$d"; then
        pass "no CODEOWNERS without owner ($tools)"
      else
        fail "CODEOWNERS or placeholder owner generated without an owner ($tools)"
      fi
    fi
    lines=$(wc -l < "$d/AGENTS.md")
    [ "$lines" -lt 60 ] && pass "AGENTS.md $lines lines ($tools)" || fail "AGENTS.md too long: $lines ($tools)"
    if [[ "$tools" == *claude* ]]; then
      [ -f "$d/CLAUDE.md" ] && [ -f "$d/.claude/settings.json" ] && pass "claude files ($tools)" || fail "claude files missing ($tools)"
    else
      [ ! -e "$d/CLAUDE.md" ] && [ ! -e "$d/.claude" ] && pass "no claude files ($tools)" || fail "unexpected claude files ($tools)"
    fi
    if grep -rIl '{{\|{%' "$d" --exclude-dir=node_modules --exclude-dir=.venv --exclude=ci.yml >/dev/null; then
      fail "unrendered Jinja in $(grep -rIl '{{\|{%' "$d" --exclude=ci.yml | head -1)"
    fi
  done

  default_verify "$stack"

  # Full verification on the both-tools render.
  d="$work/$stack-claude,codex"
  cd "$d" || continue
  git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm base && git branch -q base
  case "$stack" in
    typescript)
      npm install --no-audit --no-fund >/dev/null 2>&1
      verify "npm run verify" "npm run verify"
      # Dependency audit: clean on the render, rejects a known-vulnerable package.
      verify "npm audit (ci/npm-audit.mjs)" "node ci/npm-audit.mjs"
      cp package.json package-lock.json "$work/"
      npm install --no-audit --no-fund lodash@4.17.20 >/dev/null 2>&1
      expect_fail "npm audit: vulnerable dependency" node ci/npm-audit.mjs
      cp "$work/package.json" "$work/package-lock.json" . && npm install --no-audit --no-fund >/dev/null 2>&1
      sed -i 's/"expires": "[0-9-]*"/"expires": "2000-01-01"/' .audit-exceptions.json
      expect_fail "npm audit: expired exception" node ci/npm-audit.mjs
      git checkout -q -- .audit-exceptions.json
      # Container and secret scanning (docs/security/owasp.md).
      container_checks typescript
      secret_checks
      # Datastores (docs/adr/0003-datastores.md).
      datastore_checks typescript
      mariadb_checks typescript "npm install --no-audit --no-fund" "npm run test:integration"
      sqlserver_checks typescript "npm install --no-audit --no-fund" "npm run test:integration"
      oracle_checks typescript "npm install --no-audit --no-fund" "npm run test:integration"
      cosmosdb_checks typescript "npm install --no-audit --no-fund" "npm run test:integration"
      s3_checks typescript "npm install --no-audit --no-fund" "npm run test:integration" \
        seeded_new "dependency-cruiser: S3 SDK in application" src/application/s3-leak.ts \
        'import "@aws-sdk/client-s3";\n' npx depcruise src --config .dependency-cruiser.cjs
      dynamodb_checks typescript "npm install --no-audit --no-fund" "npm run test:integration" \
        seeded "eslint: DynamoDB expression built from a value" src/adapters/dynamo-artifact-store.ts \
        '\nexport const seeded = (id: string) => ({ KeyConditionExpression: `job_id = ${id}` });\n' \
        npx eslint src/adapters/dynamo-artifact-store.ts
      mongodb_checks typescript "npm install --no-audit --no-fund" "npm run test:integration" \
        seeded "eslint: MongoDB \$where" src/adapters/mongo-artifact-store.ts \
        '\nexport const seeded = { $where: "this.a == 1" };\n' npx eslint src/adapters/mongo-artifact-store.ts
      verify "integration: adapter contracts on real PostgreSQL + Redis" "npm run test:integration"
      # HTTP API (docs/adr/0004-http-api.md).
      http_checks typescript "npm run test:e2e" src/adapters/http/app.ts 's/      xFrameOptions: "DENY",/&\n      xContentTypeOptions: false,/'
      seeded "depcruise: web framework imported in application" src/application/complete-export.ts '\nimport { Hono } from "hono";\nexport const framework = Hono;\n' npm run arch
      seeded "depcruise: driver imported in application" src/application/complete-export.ts '\nimport pg from "pg";\nexport const driver = pg;\n' npm run arch
      seeded "depcruise: driver imported in bootstrap" src/bootstrap/main.ts '\nimport { createClient } from "redis";\nexport const driver = createClient;\n' npm run arch
      seeded "eslint: SQL built by concatenation" src/adapters/postgres-artifact-store.ts '\nexport function unsafe(pool: pg.Pool, jobId: string): Promise<pg.QueryResult> {\n  return pool.query("SELECT body FROM export_artifacts WHERE job_id = \x27" + jobId + "\x27");\n}\n' npm run lint
      # Design rules (ADR 0002), one violation at a time.
      seeded "eslint: ambient clock in domain" src/domain/export-job.ts '\nexport const now = (): number => Date.now();\n' npm run lint
      seeded "eslint: too many parameters" src/application/complete-export.ts '\nexport function sum(a: number, b: number, c: number, d: number, e: number): number {\n  return a + b + c + d + e;\n}\n' npm run lint
      seeded "eslint: non-exhaustive switch" src/domain/export-job.ts '\nexport function label(job: ExportJob): string {\n  switch (job.kind) {\n    case "queued":\n      return "q";\n    default:\n      return "other";\n  }\n}\n' npm run lint
      seeded "sonarjs: cognitive complexity" src/application/complete-export.ts '\nexport function grade(a: number, b: number, c: boolean): string {\n  let out = "";\n  for (let i = 0; i < a; i++) {\n    if (i > b && c) {\n      out += i % 2 === 0 ? "e" : "o";\n    } else if (i < b || !c) {\n      for (let j = 0; j < b; j++) {\n        if (j === i) {\n          out += j > 1 ? "x" : "y";\n        } else if (j > i && c) {\n          out += "z";\n        }\n      }\n    }\n  }\n  return out;\n}\n' npm run lint
      seeded "sonarjs: duplicated branches" src/domain/export-job.ts '\nexport function pick(job: ReadyExport, flag: boolean): string {\n  if (flag) {\n    return job.id.trim();\n  } else {\n    return job.id.trim();\n  }\n}\n' npm run lint
      seeded "depcruise: npm package in domain" src/domain/export-job.ts '\nimport fc from "fast-check";\nexport const gen = fc;\n' npm run arch
      seeded "depcruise: node built-in in application" src/application/complete-export.ts '\nimport { readFileSync } from "node:fs";\nexport const read = readFileSync;\n' npm run arch
      # Frontends (ADR 0005), each in its own render.
      frontend_checks react
      frontend_checks vue
      frontend_checks nextjs
      frontend_checks angular
      frontend_checks react-native
      printf '\nimport { InMemoryArtifactStore } from "../adapters/in-memory-artifact-store.ts";\nexport const leak = new InMemoryArtifactStore() as any;\n' >> src/domain/export-job.ts
      expect_fail "eslint: as any" npm run lint
      expect_fail "depcruise: domain -> adapters" npm run arch
      ;;
    python)
      uv sync >/dev/null 2>&1
      verify "python verify" "${verify_cmd[python]}"
      # Dependency audit: clean on the render, rejects a known-vulnerable package.
      verify "uv audit" "uv audit --locked --preview-features audit-command"
      cp pyproject.toml uv.lock "$work/"
      # pyyaml 5.3 has known advisories and no dependencies, so it resolves next to any other package set.
      uv add --no-sync pyyaml==5.3 >/dev/null 2>&1
      expect_fail "uv audit: vulnerable dependency" uv audit --locked --preview-features audit-command
      cp "$work/pyproject.toml" "$work/uv.lock" .
      # Container and secret scanning (docs/security/owasp.md).
      container_checks python
      secret_checks
      # Datastores (docs/adr/0003-datastores.md).
      datastore_checks python
      mariadb_checks python "uv sync" "uv run pytest -q -p no:warnings -m integration"
      sqlserver_checks python "uv sync" "uv run pytest -q -p no:warnings -m integration"
      oracle_checks python "uv sync" "uv run pytest -q -p no:warnings -m integration" \
        seeded_new "import-linter: Oracle driver in application" src/demo_app/application/oracle_leak.py \
        'import oracledb\n' uv run lint-imports
      s3_checks python "uv sync" "uv run pytest -q -p no:warnings -m integration"
      cosmosdb_checks python "uv sync" "uv run pytest -q -p no:warnings -m integration" \
        seeded_new "import-linter: Cosmos DB SDK in application" src/demo_app/application/cosmos_leak.py \
        'import azure.cosmos\n' uv run lint-imports
      dynamodb_checks python "uv sync" "uv run pytest -q -p no:warnings -m integration" \
        seeded_new "import-linter: AWS SDK in application" src/demo_app/application/dynamo_leak.py \
        'import boto3\n' uv run lint-imports
      mongodb_checks python "uv sync" "uv run pytest -q -p no:warnings -m integration" \
        seeded_new "import-linter: MongoDB driver in application" src/demo_app/application/mongo_leak.py \
        'import pymongo\n' uv run lint-imports
      verify "integration: adapter contracts on real PostgreSQL + Redis" "uv run pytest -q -p no:warnings -m integration"
      # HTTP API (docs/adr/0004-http-api.md).
      http_checks python "uv run pytest -q -p no:warnings -m e2e" src/demo_app/adapters/http/app.py '/"X-Content-Type-Options": "nosniff",/d'
      seeded "import-linter: web framework imported in application" src/demo_app/application/complete_export.py '\nimport fastapi\n\nFRAMEWORK = fastapi\n' uv run lint-imports
      seeded "import-linter: driver imported in application" src/demo_app/application/complete_export.py '\nimport psycopg\n\nDRIVER = psycopg\n' uv run lint-imports
      seeded "import-linter: driver imported in bootstrap" src/demo_app/bootstrap/main.py '\nimport redis\n\nDRIVER = redis\n' uv run lint-imports
      seeded "ruff: SQL built with an f-string" src/demo_app/adapters/postgres_artifact_store.py '\n\ndef unsafe(connection: psycopg.Connection[TupleRow], job_id: str) -> None:\n    connection.execute(f"SELECT body FROM export_artifacts WHERE job_id = \x27{job_id}\x27")\n' uv run ruff check .
      # Design rules (ADR 0002), one violation at a time.
      seeded "ruff: ambient randomness in domain" src/demo_app/domain/export_job.py '\n\nimport random\n\n\ndef roll() -> float:\n    return random.random()\n' uv run ruff check .
      seeded "ruff: ambient clock in application" src/demo_app/application/complete_export.py '\n\ndef now() -> object:\n    import datetime\n\n    return datetime.datetime.now(tz=datetime.UTC)\n' uv run ruff check .
      seeded "ruff: too many arguments" src/demo_app/application/complete_export.py '\n\ndef total(a: int, b: int, c: int, d: int, e: int) -> int:\n    return a + b + c + d + e\n' uv run ruff check .
      seeded "ruff: boolean flag parameter" src/demo_app/domain/export_job.py '\n\ndef describe(job: ReadyExport, verbose: bool) -> str:\n    return job.artifact_key if verbose else job.id\n' uv run ruff check .
      seeded "pyright: implicit override" src/demo_app/adapters/in_memory_artifact_store.py '\n\nclass Loud(InMemoryArtifactStore):\n    def read(self, key: str) -> str | None:\n        return key\n' uv run pyright
      printf '\nfrom demo_app.adapters.in_memory_artifact_store import InMemoryArtifactStore  # noqa\nleak: int = InMemoryArtifactStore()  # type: ignore\n' >> src/demo_app/domain/export_job.py
      expect_fail "pyright: type: ignore disabled" uv run pyright
      expect_fail "ruff: blanket noqa/type: ignore" uv run ruff check .
      expect_fail "import-linter: domain -> adapters" uv run lint-imports
      ;;
    dotnet)
      verify "dotnet verify" "${verify_cmd[dotnet]}"
      # Dependency audit (NuGetAudit + TreatWarningsAsErrors): clean, then rejects a known-vulnerable package.
      verify "nuget audit" "dotnet restore --force-evaluate"
      sed -i 's#<PackageVersion Include="xunit.v3"#<PackageVersion Include="Newtonsoft.Json" Version="12.0.1" />\n    &#' Directory.Packages.props
      sed -i 's#</Project>#  <ItemGroup><PackageReference Include="Newtonsoft.Json" /></ItemGroup>\n</Project>#' src/DemoApp.Adapters/DemoApp.Adapters.csproj
      expect_fail "nuget audit: vulnerable dependency" dotnet restore --force-evaluate
      git checkout -q -- Directory.Packages.props src/DemoApp.Adapters/DemoApp.Adapters.csproj && dotnet restore --force-evaluate >/dev/null 2>&1
      # Container and secret scanning (docs/security/owasp.md).
      container_checks dotnet
      secret_checks
      # Datastores (docs/adr/0003-datastores.md).
      datastore_checks dotnet
      mariadb_checks dotnet "dotnet build" 'dotnet test --no-build --filter-trait "Category=Integration"'
      sqlserver_checks dotnet "dotnet build" 'dotnet test --no-build --filter-trait "Category=Integration"'
      oracle_checks dotnet "dotnet build" 'dotnet test --no-build --filter-trait "Category=Integration"'
      mongodb_checks dotnet "dotnet build" 'dotnet test --no-build --filter-trait "Category=Integration"'
      dynamodb_checks dotnet "dotnet build" 'dotnet test --no-build --filter-trait "Category=Integration"'
      cosmosdb_checks dotnet "dotnet build" 'dotnet test --no-build --filter-trait "Category=Integration"'
      s3_checks dotnet "dotnet build" 'dotnet test --no-build --filter-trait "Category=Integration"'
      verify "integration: adapter contracts on real PostgreSQL + Redis" 'dotnet test --filter-trait "Category=Integration"'
      # HTTP API (docs/adr/0004-http-api.md).
      http_checks dotnet 'dotnet test --filter-trait "Category=E2E"' src/DemoApp.Adapters/Http/ExportEndpoints.cs '/headers.XContentTypeOptions = "nosniff";/d'
      seeded "CA2100: SQL built by concatenation" src/DemoApp.Adapters/PostgresArtifactStore.cs '\npublic static class Unsafe\n{\n    public static NpgsqlCommand Query(NpgsqlConnection connection, string jobId) =>\n        new() { Connection = connection, CommandText = "SELECT body FROM export_artifacts WHERE job_id = \x27" + jobId + "\x27" };\n}\n' dotnet build
      # Design rules (ADR 0002), one violation at a time.
      seeded "BannedApi: ambient clock in Domain" src/DemoApp.Domain/ExportJob.cs '\npublic static class Clock\n{\n    public static DateTime Now() => DateTime.UtcNow;\n}\n' dotnet build
      seeded "BannedApi: Guid.NewGuid in Application" src/DemoApp.Application/CompleteExport.cs '\npublic static class Ids\n{\n    public static Guid Next() => Guid.NewGuid();\n}\n' dotnet build
      seeded "naming: async method without Async suffix" src/DemoApp.Adapters/InMemoryArtifactStore.cs '\npublic static class Waits\n{\n    public static async Task Pause() => await Task.CompletedTask.ConfigureAwait(false);\n}\n' dotnet build
      seeded "NetArchTest: unsealed concrete class" src/DemoApp.Application/CompleteExport.cs '\npublic class Helper\n{\n    public int Value { get; init; }\n}\n' dotnet test --filter-trait "Category=Architecture"
      printf '\npublic static class Leak\n{\n#pragma warning disable CA1823\n    public static string Value = null!;\n}\n' >> src/DemoApp.Domain/ExportJob.cs
      expect_fail "build: TreatWarningsAsErrors" dotnet build
      ;;
    go)
      go mod tidy >/dev/null 2>&1
      verify "go verify" "${verify_cmd[go]}"
      # The property test (rapid) must catch a bug that the example test and fixed inputs miss.
      sed -i 's/artifactKey: artifactKey}/artifactKey: strings.ToLower(artifactKey)}/' internal/domain/exportjob.go
      # Must fail as a rapid property failure, not as a compile error from a stale sed target.
      expect_fail "rapid: property test catches a key-mangling bug" \
        bash -c 'out=$(go test -count=1 ./internal/domain/ 2>&1); ! grep -q "\[rapid\] failed" <<<"$out"'
      git checkout -q -- internal/domain/exportjob.go && rm -rf internal/domain/testdata/rapid
      # Dependency audit: clean, then rejects a vulnerable function that our code actually calls.
      verify "govulncheck" "go tool govulncheck ./..."
      cp go.mod go.sum "$work/"
      go get gopkg.in/yaml.v2@v2.2.7 >/dev/null 2>&1
      printf 'package inmemory\n\nimport "gopkg.in/yaml.v2"\n\n// Decode calls a vulnerable yaml version.\nfunc Decode(b []byte) (map[string]any, error) {\n\tvar v map[string]any\n\terr := yaml.Unmarshal(b, &v)\n\treturn v, err\n}\n' > internal/adapters/inmemory/vuln.go
      expect_fail "govulncheck: vulnerable function called" go tool govulncheck ./...
      rm -f internal/adapters/inmemory/vuln.go && cp "$work/go.mod" "$work/go.sum" .
      # Container and secret scanning (docs/security/owasp.md).
      container_checks go
      secret_checks
      # Datastores (docs/adr/0003-datastores.md).
      datastore_checks go
      mariadb_checks go "go mod tidy" "go test -tags integration ./..."
      s3_checks go "go mod tidy" "go test -tags integration ./..." \
        seeded_new "depguard: S3 SDK outside adapters" internal/application/s3_leak.go \
        'package application\n\nimport _ "github.com/aws/aws-sdk-go-v2/service/s3"\n' go tool golangci-lint run
      cosmosdb_checks go "go mod tidy" "go test -tags integration ./..." \
        seeded_new "depguard: Cosmos DB SDK outside adapters" internal/application/cosmos_leak.go \
        'package application\n\nimport _ "github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"\n' go tool golangci-lint run
      dynamodb_checks go "go mod tidy" "go test -tags integration ./..." \
        seeded_new "depguard: DynamoDB SDK outside adapters" internal/application/dynamo_leak.go \
        'package application\n\nimport _ "github.com/aws/aws-sdk-go-v2/service/dynamodb"\n' go tool golangci-lint run
      mongodb_checks go "go mod tidy" "go test -tags integration ./..." \
        seeded_new "ruleguard: MongoDB \$where" internal/adapters/mongostore/seeded.go \
        'package mongostore\n\nimport "go.mongodb.org/mongo-driver/v2/bson"\n\nvar seeded = bson.M{"$where": "this.a == 1"}\n' \
        go tool golangci-lint run
      oracle_checks go "go mod tidy" "go test -tags integration ./..." \
        seeded_new "depguard: Oracle driver outside adapters" internal/application/oracle_leak.go \
        'package application\n\nimport _ "github.com/sijms/go-ora/v2"\n' go tool golangci-lint run
      sqlserver_checks go "go mod tidy" "go test -tags integration ./..." \
        seeded_new "depguard: SQL Server driver outside adapters" internal/application/sqlserver_driver.go \
        'package application\n\nimport _ "github.com/microsoft/go-mssqldb"\n' go tool golangci-lint run
      verify "integration: adapter contracts on real PostgreSQL + Redis" "go test -tags integration ./..."
      seeded_new "ruleguard: SQL built by concatenation" internal/adapters/postgres/unsafe.go 'package postgres\n\nimport "context"\n\n// Unsafe builds SQL from a value.\nfunc (s *Store) Unsafe(ctx context.Context, jobID string) error {\n\t_, err := s.pool.Exec(ctx, "SELECT body FROM export_artifacts WHERE job_id = \x27"+jobID+"\x27")\n\treturn err //nolint:wrapcheck // seeded\n}\n' go tool golangci-lint run ./internal/adapters/postgres/
      seeded_new "depguard: driver imported in application" internal/application/driver.go 'package application\n\nimport "github.com/jackc/pgx/v5/pgxpool"\n\n// Pool leaks the driver into the application layer.\ntype Pool = pgxpool.Pool\n' go tool golangci-lint run --enable-only depguard ./internal/application/
      # HTTP API (docs/adr/0004-http-api.md).
      http_checks go "go test -tags e2e ./..." internal/adapters/httpapi/handler.go '/headers.Set("X-Content-Type-Options", "nosniff")/d'
      seeded_new "depguard: net/http imported in application" internal/application/web.go 'package application\n\nimport "net/http"\n\n// Handler leaks HTTP into the application layer.\ntype Handler = http.Handler\n' go tool golangci-lint run --enable-only depguard ./internal/application/
      # Design rules (ADR 0002), one violation at a time.
      seeded_new "forbidigo: ambient clock in domain" internal/domain/clock.go 'package domain\n\nimport "time"\n\n// Now reads the wall clock.\nfunc Now() time.Time { return time.Now() }\n' go tool golangci-lint run ./internal/domain/
      seeded_new "depguard: os imported in domain" internal/domain/leak.go 'package domain\n\nimport "os"\n\n// Args leaks process state into the domain.\nfunc Args() []string { return os.Args }\n' go tool golangci-lint run --enable-only depguard ./internal/domain/
      seeded_new "revive: too many parameters" internal/application/sum.go 'package application\n\n// Sum has too many parameters.\nfunc Sum(a, b, c, d, e int) int { return a + b + c + d + e }\n' go tool golangci-lint run ./internal/application/
      seeded_new "gochecksumtype: non-exhaustive type switch" internal/domain/label.go 'package domain\n\n// Label misses states.\nfunc Label(job ExportJob) string {\n\tswitch job.(type) {\n\tcase Queued:\n\t\treturn "q"\n\t}\n\treturn ""\n}\n' go tool golangci-lint run ./internal/domain/
      seeded_new "nolintlint: suppression without a reason" internal/domain/quiet.go 'package domain\n\nimport "time"\n\n// Now reads the wall clock.\nfunc Now() time.Time { return time.Now() } //nolint:forbidigo\n' go tool golangci-lint run ./internal/domain/
      printf '\n// Seeded escape hatch for the ratchet.\nvar _ = 1 //nolint:gochecknoglobals // seeded\n' >> internal/domain/exportjob.go
      ;;
    rust)
      cargo fetch -q >/dev/null 2>&1
      verify "rust verify" "${verify_cmd[rust]}"
      # Dependency audit: clean, then rejects a crate with a known advisory.
      verify "cargo deny advisories" "cargo deny check advisories"
      cp crates/adapters/Cargo.toml Cargo.lock "$work/"
      sed -i 's/^\[dependencies\]$/&\ntime = "=0.1.45"/' crates/adapters/Cargo.toml && cargo fetch -q >/dev/null 2>&1
      expect_fail "cargo deny: crate with a known advisory" cargo deny check advisories
      cp "$work/Cargo.toml" crates/adapters/Cargo.toml && cp "$work/Cargo.lock" .
      # Container and secret scanning (docs/security/owasp.md).
      container_checks rust
      secret_checks
      # Datastores (docs/adr/0003-datastores.md).
      datastore_checks rust
      mariadb_checks rust "cargo fetch" "cargo test -p adapters --features integration"
      mongodb_checks rust "cargo fetch" "cargo test -p adapters --features integration"
      dynamodb_checks rust "cargo fetch" "cargo test -p adapters --features integration"
      cosmosdb_checks rust "cargo fetch" "cargo test -p adapters --features integration"
      s3_checks rust "cargo fetch" "cargo test -p adapters --features integration" \
        seeded "check-layers: S3 SDK in bootstrap" crates/bootstrap/Cargo.toml 'aws-sdk-s3 = "1"\n' bash ci/check-layers.sh
      oracle_checks rust "cargo fetch" "cargo test -p adapters --features integration" \
        seeded "clippy: oracle-rs query outside the static-SQL gateway" crates/adapters/src/oracle.rs \
        '\n/// Builds SQL from a value.\npub async fn unsafe_delete(connection: &Connection, table: &str) -> oracle_rs::Result<QueryResult> {\n    connection.execute(&format!("DELETE FROM {table}"), &[]).await\n}\n' \
        cargo clippy -p adapters -- -D warnings
      sqlserver_checks rust "cargo fetch" "cargo test -p adapters --features integration" \
        seeded "clippy: tiberius query outside the static-SQL gateway" crates/adapters/src/sqlserver.rs \
        '\n/// Builds SQL from a value.\npub async fn unsafe_delete(client: &mut Connection, table: &str) -> tiberius::Result<u64> {\n    Ok(client.execute(format!("DELETE FROM {table}"), &[]).await?.total())\n}\n' \
        cargo clippy -p adapters -- -D warnings
      verify "integration: adapter contracts on real PostgreSQL + Redis" "cargo test -p adapters --features integration"
      seeded "sqlx: SQL built from a string does not compile" crates/adapters/src/postgres.rs '\n/// Builds SQL from a value.\npub async fn unsafe_read(pool: &PgPool, job_id: &str) -> Result<(), PortError> {\n    let sql = format!("SELECT body FROM export_artifacts WHERE job_id = \x27{job_id}\x27");\n    sqlx::query(&sql).execute(pool).await?;\n    Ok(())\n}\n' cargo check -p adapters
      seeded "check-layers: driver in bootstrap" crates/bootstrap/Cargo.toml 'redis = "1.8"\n' bash ci/check-layers.sh
      # HTTP API (docs/adr/0004-http-api.md).
      http_checks rust "npm --prefix e2e install --no-audit --no-fund && npm --prefix e2e test" crates/adapters/src/http.rs '/X_CONTENT_TYPE_OPTIONS/d'
      seeded "check-layers: web framework in application" crates/application/Cargo.toml 'axum = "0.8"\n' bash ci/check-layers.sh
      # Design rules (ADR 0002), one violation at a time.
      seeded "clippy: ambient clock in domain" crates/domain/src/lib.rs '\n/// Reads the wall clock.\npub fn now() -> std::time::SystemTime {\n    std::time::SystemTime::now()\n}\n' cargo clippy -p domain -- -D warnings
      seeded "clippy: too many arguments" crates/application/src/lib.rs '\n/// Too many parameters.\npub fn sum(a: u8, b: u8, c: u8, d: u8, e: u8) -> u32 {\n    u32::from(a) + u32::from(b) + u32::from(c) + u32::from(d) + u32::from(e)\n}\n' cargo clippy -p application -- -D warnings
      seeded "clippy: wildcard match arm" crates/domain/src/lib.rs '\n/// Hides new variants.\npub fn label(job: &ExportJob) -> &str {\n    match job {\n        ExportJob::Queued(_) => "q",\n        _ => "other",\n    }\n}\n' cargo clippy -p domain -- -D warnings
      seeded "clippy: unwrap outside tests" crates/application/src/lib.rs '\n/// Panics on bad input.\npub fn parse(s: &str) -> u32 {\n    s.parse().unwrap()\n}\n' cargo clippy -p application -- -D warnings
      seeded "clippy: allow without a reason" crates/domain/src/lib.rs '\n#[allow(dead_code)]\nfn unused() {}\n' cargo clippy -p domain -- -D warnings
      printf '\n#[expect(dead_code, reason = "seeded escape for the ratchet")]\nfn seeded_escape() {}\n' >> crates/domain/src/lib.rs
      ;;
  esac
  # Ratchet: commit the violation plus a skipped test and compare with base.
  case "$stack" in
    typescript) sed -i 's/  it("rejects/  it.skip("rejects/' src/domain/export-job.test.ts ;;
    python) sed -i 's/^def test_rejects/@pytest.mark.skip\ndef test_rejects/' tests/test_export_job.py ;;
    dotnet) sed -i 's/\[Fact\]/[Fact(Skip = "x")]/' tests/DemoApp.Tests/ExportJobTests.cs ;;
    go) sed -i 's/^func TestRejectsBlankArtifactKey(t \*testing.T) {$/&\n\tt.Skip("x")/' internal/domain/exportjob_test.go ;;
    rust) sed -i 's/^#\[tokio::test\]$/&\n#[ignore]/' crates/adapters/tests/in_memory.rs ;;
  esac
  git -c user.name=t -c user.email=t@t commit -qam violation
  expect_fail "guardrail-ratchet" bash ci/guardrail-ratchet.sh base

  # Claude Code hook: guardrail configs are protected.
  if [ -f .claude/hooks/protect-guardrails.sh ]; then
    first=$(sed -n 's/.*"Edit(\/\([^*)]*\))".*/\1/p' .claude/settings.json | head -1)
    echo "{\"tool_input\":{\"file_path\":\"$first\"}}" | CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/protect-guardrails.sh 2>/dev/null
    [ $? -eq 2 ] && pass "hook blocks edit of $first" || fail "hook did not block $first"
  fi
  cd "$repo" || exit 1
done

echo
echo "Rendered into $work"
if [ "$failures" -eq 0 ]; then echo "ALL PASSED"; else echo "$failures FAILURE(S)"; exit 1; fi
