#!/usr/bin/env bash
# Render every stack x agent-tool combination, then for each stack:
#   1. the generated project passes its own verify command, and
#   2. the guardrails reject a seeded violation (escape hatch, layer leak, skipped test).
# Usage: tests/render-all.sh [stack...]      (default: typescript python dotnet go rust)
#   SHARD=core|datastores|ui runs one part of each stack (default: all). core: the agent-tool renders, the defaults
#   and the full render; datastores: one render per extra datastore; ui: the frontend/ssr renders. CI runs each part
#   as its own job.
# The renders go to a temp folder that is deleted when every check passes; it is kept on a failure,
# or always with KEEP_WORK=1, and its path is printed at the end.
# Needs: uv, git, bash >= 4 (associative arrays; Git Bash and Linux are fine, macOS /bin/bash 3.2 is not), Docker (running); node/npm for typescript; .NET 10 SDK for dotnet; Go >= 1.26 for go; rustup + cargo-deny + cargo-mutants for rust.
set -uo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/project-starter-XXXXXX")
stacks=("$@")
[ ${#stacks[@]} -gt 0 ] || stacks=(typescript python dotnet go rust)
failures=0

cleanup() {
  cd "$repo" || return
  if [ "$failures" -gt 0 ] || [ "${KEEP_WORK:-0}" = 1 ]; then
    echo "Rendered into $work (kept)"
  else
    chmod -R u+w "$work" 2>/dev/null
    rm -rf "$work" 2>/dev/null || echo "Could not fully remove $work (files still in use?)"
  fi
}
trap cleanup EXIT

pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; failures=$((failures + 1)); }
part() { [ "${SHARD:-all}" = all ] || [ "$SHARD" = "$1" ]; }
case "${SHARD:-all}" in all | core | datastores | ui) ;; *) echo "SHARD must be all, core, datastores or ui" >&2; exit 2 ;; esac

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
  # The release check's full (active) scan, time-capped here; it reports warnings and fails on FAIL-level rules.
  # The active rules run too: ZAP 2.17 checks ~67 rules in the baseline and ~140 in the full scan.
  verify "zap: full scan of the running container" "DAST_MAX_MINUTES=3 bash ci/dast.sh $image --full | tee /dev/stderr | grep -qE 'PASS: [1-9][0-9]{2,}'"
  # Drop one security header: the ZAP scan must fail the build, in both modes.
  sed -i "$4" "$3"
  expect_fail "zap: missing X-Content-Type-Options" bash -c "docker build -q -t $image-seed . >/dev/null && bash ci/dast.sh $image-seed"
  expect_fail "zap full: missing X-Content-Type-Options" bash -c "DAST_MAX_MINUTES=3 bash ci/dast.sh $image-seed --full"
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

ssr_test_ui="npm --prefix e2e-ui install --no-audit --no-fund && npm --prefix e2e-ui test"

ssr_key_ring_check() { # .NET: compose keeps the antiforgery key ring in a volume, so a form opened before a restart still posts
  local c="docker compose -p ps-dpkeys" page cookie token code
  $c down -v >/dev/null 2>&1
  if $c up -d --build app >/dev/null 2>&1 && wait_healthz; then
    page=$(curl -fsS -D - http://127.0.0.1:8080/)
    cookie=$(grep -i '^set-cookie: __Host-csrf=' <<<"$page" | sed 's/^[^:]*: //; s/;.*//' | tr -d '')
    token=$(grep -o 'name="csrf_token"[^>]*value="[^"]*"' <<<"$page" | sed 's/.*value="//; s/"$//')
    $c restart app >/dev/null 2>&1 && wait_healthz
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" -H 'Sec-Fetch-Site: same-origin'       --data-urlencode "csrf_token=$token" --data-urlencode job_id=restart-1 --data-urlencode content=id http://127.0.0.1:8080/)
  fi
  $c down -v >/dev/null 2>&1
  if [ "${code:-}" = 303 ]; then pass "ssr: compose: form opened before a restart still posts (Data Protection keys)"
  else fail "ssr: compose: form opened before a restart got ${code:-no answer} (Data Protection keys)"; fi
}

wait_healthz() { for _ in $(seq 1 60); do curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

ssr_checks() { # ssr_checks <stack> <install-cmd> <ui-file> <csp-sed-expression> <application-file> <framework-import-text> <arch-cmd>
  # A separate render with the server-rendered UI (frontend=ssr, ADR 0005): verify, browser flows + axe, ZAP from /,
  # then seeded violations: the page CSP removed (sed applied to every tracked source file), the template engine
  # imported in application, and an unlabeled <input> added to the page template (<ui-file>).
  local dir="$work/$1-ssr" image="project-starter-ssr-$1" out
  render "$1" '["claude"]' "$dir" -d frontend=ssr || { fail "render frontend=ssr"; return; }
  pushd "$dir" >/dev/null || return
  git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm base && git branch -q base
  # The ratchet reads the Playwright specs too, although they are not in the stack's language.
  sed -i '0,/^test(/s//test.skip(/' e2e-ui/app.spec.ts && git -c user.name=t -c user.email=t@t commit -qam skip
  if out=$(bash ci/guardrail-ratchet.sh base 2>&1); then fail "ssr: ratchet: skipped Playwright spec (should have failed)"
  elif grep -q "Skipped/focused Playwright specs" <<<"$out"; then pass "ssr: ratchet: skipped Playwright spec rejected"
  else fail "ssr: ratchet: skipped Playwright spec failed for another reason"; printf '%s
' "$out" | tail -n 15 | sed 's/^/      /'; fi
  git reset -q --hard base
  # Only the two IGNOREs every scan has (10049 no-store, 10109 modern web app): the UI adds none.
  [ -f .zap/rules.tsv ] && grep -q '\.zap/rules\.tsv' AGENTS.md && [ "$(grep -c $'\tIGNORE\t' .zap/rules.tsv)" = 2 ] \
    && [ "$(wc -l < AGENTS.md)" -lt 60 ] && pass "ssr: ZAP rules protected, no new IGNORE, AGENTS.md short" \
    || fail "ssr: ZAP rules missing, unprotected or relaxed"
  bash -c "$2" >/dev/null 2>&1
  verify "ssr: $1 verify" "${verify_cmd[$1]}"
  npm --prefix e2e-ui install --no-audit --no-fund >/dev/null 2>&1 && (cd e2e-ui && npx playwright install chromium >/dev/null 2>&1)
  verify "ssr: browser flows + axe (Playwright)" "$ssr_test_ui"
  export MSYS_NO_PATHCONV=1
  verify "ssr: zap baseline of the UI (from /)" "docker build -q -t $image . && DAST_PATH=/ bash ci/dast.sh $image"
  if [ "$1" = dotnet ]; then ssr_key_ring_check; fi
  git ls-files -z -- . ':!tests' ':!docs' ':!e2e-ui' ':!ci' ':!.github' ':!*.md' | xargs -0 sed -i "$4"
  if out=$(bash -c "docker build -q -t $image-seed . >/dev/null && DAST_PATH=/ bash ci/dast.sh $image-seed" 2>&1); then
    fail "ssr: zap: missing Content-Security-Policy (should have failed)"
  elif grep -q '10038' <<<"$out"; then pass "ssr: zap: missing Content-Security-Policy rejected"
  else fail "ssr: zap: missing Content-Security-Policy failed for another reason"; printf '%s\n' "$out" | tail -n 15 | sed 's/^/      /'; fi
  git checkout -q -- .
  unset MSYS_NO_PATHCONV
  # <framework-import-text> starting with "package" is the content of a new file <application-file> (Go: imports go first).
  if [[ "$6" == package* ]]; then seeded_new "ssr: template engine imported in application" "$5" "$6" bash -c "$7"
  else seeded "ssr: template engine imported in application" "$5" "$6" bash -c "$7"; fi
  if [ -n "${8:-}" ]; then # optional <ui-file-checked> <driver-text> <check-cmd>: a datastore driver named in the UI is rejected by that check
    printf '%b' "$9" >> "$8"
    if out=$(bash -c "${10}" 2>&1); then fail "ssr: datastore driver named in the UI (should have failed)"
    elif grep -q "must not name a datastore driver" <<<"$out"; then pass "ssr: datastore driver named in the UI rejected"
    else fail "ssr: datastore driver in the UI failed for another reason"; printf '%s\n' "$out" | tail -n 15 | sed 's/^/      /'; fi
    git checkout -q -- "$8"
  fi
  sed -i 's#</form>#  <input name="seeded">\n&#' "$3"
  if out=$(bash -c "$ssr_test_ui" 2>&1); then fail "ssr: axe: unlabeled input (should have failed)"
  elif grep -q '"id": "label"' <<<"$out"; then pass "ssr: axe: unlabeled input rejected"
  else fail "ssr: axe: unlabeled input failed for another reason"; printf '%s\n' "$out" | tail -n 15 | sed 's/^/      /'; fi
  git checkout -q -- "$3"
  popd >/dev/null || return
}

ssr_api_checks() { # ssr_api_checks <stack> <install-cmd> <e2e-cmd> [<seed-fn> <label> <file> <text> <cmd...>]
  # The JSON API and the UI share one server, next to a datastore adapter (postgres; the server still runs on the
  # in-memory store without POSTGRES_URL). The optional seed names the driver in the UI and must be rejected.
  local dir="$work/$1-ssr-api"
  render "$1" '["codex"]' "$dir" -d frontend=ssr -d http_api=true -d containerize=false -d 'datastores=["postgres"]'     || { fail "render frontend=ssr http_api=true datastores=[postgres]"; return; }
  pushd "$dir" >/dev/null || return
  git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm base
  bash -c "$2" >/dev/null 2>&1
  verify "ssr + api + postgres: $1 verify" "${verify_cmd[$1]}"
  verify "ssr + api: API tests against the shared server" "$3"
  verify "ssr + api: browser flows + axe (Playwright)" "$ssr_test_ui"
  if [ "$#" -gt 3 ]; then "$4" "${@:5}"; fi
  popd >/dev/null || return
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

# Mutation testing of the domain (cmd.mutation): the command, the domain file, the line an untested branch goes before,
# that branch (an off-by-one the tests never pin down), and the output that proves the threshold, not a build error,
# rejected it.
declare -A mutation_cmd=(
  [typescript]="npm run mutation"
  [python]="uv run mutmut run && uv run mutmut export-cicd-stats && uv run python ci/mutation-gate.py"
  [dotnet]="cd tests/DemoApp.Domain.Tests && dotnet tool restore && dotnet stryker"
  [go]="go run github.com/go-gremlins/gremlins/cmd/gremlins@v0.5.1 unleash ./internal/domain"
  [rust]="cargo mutants -p domain"
)
declare -A mutation_file=(
  [typescript]=src/domain/export-job.ts [python]=src/demo_app/domain/export_job.py
  [dotnet]=src/DemoApp.Domain/ExportJob.cs [go]=internal/domain/exportjob.go [rust]=crates/domain/src/lib.rs
)
declare -A mutation_anchor=(
  [typescript]='^  if (artifactKey.trim().length === 0) {'
  [python]='^    if not artifact_key.strip():'
  [dotnet]='^        return new ExportJob.Ready(job.Id, artifactKey);'
  [go]='^\tif strings.TrimSpace(artifactKey) == "" {'
  [rust]='^    if artifact_key.trim().is_empty() {'
)
declare -A mutation_gap=(
  [typescript]='  if (artifactKey.length > 1024) {\n    throw new Error("Artifact key too long");\n  }'
  [python]='    if len(artifact_key) > 1024:\n        raise ValueError("Artifact key too long")'
  [dotnet]='        if (artifactKey.Length > 1024)\n        {\n            throw new ArgumentException("Artifact key too long", nameof(artifactKey));\n        }'
  [go]='\tif len(artifactKey) > 1024 {\n\t\treturn Ready{}, ErrBlankArtifactKey\n\t}'
  [rust]='    if artifact_key.len() > 1024 {\n        return Err(CompleteError::BlankArtifactKey);\n    }'
)
declare -A mutation_rejected=(
  [typescript]='under breaking threshold' [python]='surviving mutants: uv run mutmut results' [dotnet]='lower than the configured break threshold'
  [go]='below efficacy-threshold' [rust]='MISSED'
)

# Property-test run count (PROPERTY_RUNS, raised by .github/workflows/release-check.yml): the command that runs only the
# property test, and a seed that makes the property fail from its 501st case. With PROPERTY_RUNS=1000 the seeded test
# must fail on that seed; unset, the framework default (100) never reaches it.
declare -A property_cmd=(
  [typescript]="npx vitest run src/domain/export-job.test.ts"
  [python]='uv run pytest tests/test_export_job.py -q -p no:cacheprovider ${PROPERTY_RUNS:+--property-runs=$PROPERTY_RUNS}'
  [dotnet]="dotnet test --project tests/DemoApp.Domain.Tests"
  [go]='go test -count=1 ./internal/domain -run TestCompleteKeepsIDAndKey ${PROPERTY_RUNS:+-rapid.checks=$PROPERTY_RUNS}'
  [rust]='env ${PROPERTY_RUNS:+PROPTEST_CASES=$PROPERTY_RUNS} cargo test -q -p domain keeps_id_and_key'
)
declare -A property_file=(
  [typescript]=src/domain/export-job.test.ts [python]=tests/test_export_job.py
  [dotnet]=tests/DemoApp.Domain.Tests/ExportJobTests.cs [go]=internal/domain/exportjob_test.go [rust]=crates/domain/src/lib.rs
)
declare -A property_anchor=(
  [typescript]='^          const ready = completeExport'
  [python]='^    ready = complete_export(RunningExport(id=job_id), key)'
  [dotnet]='^            var ready = ExportTransitions.Complete(new ExportJob.Running(id.Get), key.Get);'
  [go]='^\tready, err := domain.Complete(domain.Start(domain.NewQueued(id)), key)'
  [rust]='^            let ready = complete(start(Queued::new(id.clone())), \&key).unwrap();'
)
declare -A property_seed=(
  [typescript]='          const g = globalThis as { seedCalls?: number };\n          g.seedCalls = (g.seedCalls ?? 0) + 1;\n          if (g.seedCalls > 500) throw new Error("seed: past 500 cases");'
  [python]='    global _seed_calls\n    _seed_calls = globals().get("_seed_calls", 0) + 1\n    assert _seed_calls <= 500, "seed: past 500 cases"'
  [dotnet]='        if (SeedCalls.Next() > 500)\n        {\n            throw new System.InvalidOperationException("seed: past 500 cases");\n        }'
  [go]='\tseedCalls++\n\tif seedCalls > 500 {\n\t\tt.Fatalf("seed: past 500 cases")\n\t}'
  [rust]='            static SEED_CALLS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);\n            prop_assert!(SEED_CALLS.fetch_add(1, std::sync::atomic::Ordering::SeqCst) < 500, "seed: past 500 cases");'
)

property_runs_check() { # property_runs_check <stack>: in the claude-only render (installed by default_verify)
  pushd "$work/$1-claude" >/dev/null || return
  local file=${property_file[$1]} out
  sed -i "s|${property_anchor[$1]}|${property_seed[$1]}\n&|" "$file"
  case "$1" in
    dotnet) printf '\ninternal static class SeedCalls\n{\n    private static int s_count;\n\n    public static int Next() => System.Threading.Interlocked.Increment(ref s_count);\n}\n' >> "$file" ;;
    go) printf '\nvar seedCalls int\n' >> "$file" ;;
  esac
  if out=$(PROPERTY_RUNS=1000 bash -c "${property_cmd[$1]}" 2>&1); then
    fail "property runs: PROPERTY_RUNS=1000 ignored ($1)"
  elif grep -q 'seed: past 500 cases' <<<"$out"; then
    pass "property runs: PROPERTY_RUNS honoured ($1)"
  else
    fail "property runs: failed for another reason ($1)"; printf '%s\n' "$out" | tail -n 15 | sed 's/^/      /'
  fi
  if out=$(env -u PROPERTY_RUNS bash -c "${property_cmd[$1]}" 2>&1); then
    pass "property runs: default unchanged ($1)"
  else
    fail "property runs: default run reached the seed ($1)"; printf '%s\n' "$out" | tail -n 15 | sed 's/^/      /'
  fi
  git checkout -q -- "$file"
  rm -rf .hypothesis crates/domain/proptest-regressions
  popd >/dev/null || return
}

mutation_unsupported_here() { # mutmut, Stryker.NET and gremlins misbehave on Windows; CI (Linux) runs them
  case "$1:$(uname -s)" in
    python:MINGW* | python:MSYS* | dotnet:MINGW* | dotnet:MSYS* | go:MINGW* | go:MSYS*)
      echo "  SKIP mutation ($1): needs Linux/macOS here; CI runs it"; return 0 ;;
  esac
  return 1
}

full_mutation() { # full_mutation <stack>: in the full render (datastores + HTTP API), the domain run still needs no Docker
  mutation_unsupported_here "$1" && return
  verify "full render: $1 mutation" "${mutation_cmd[$1]}"
  rm -rf .stryker-tmp reports mutants tests/DemoApp.Domain.Tests/StrykerOutput mutants.out mutants.out.old
}

default_mutation() { # default_mutation <stack>: on the default render, mutation passes; an untested branch fails it
  mutation_unsupported_here "$1" && return
  pushd "$work/$1-claude" >/dev/null || return
  local file=${mutation_file[$1]} out
  verify "defaults: $1 mutation" "${mutation_cmd[$1]}"
  sed -i "s|${mutation_anchor[$1]}|${mutation_gap[$1]}\n&|" "$file"
  if out=$(bash -c "${mutation_cmd[$1]}" 2>&1); then
    fail "mutation: untested branch in the domain (should have failed)"
  elif grep -q "${mutation_rejected[$1]}" <<<"$out"; then
    pass "mutation: untested branch in the domain rejected"
  else
    fail "mutation: untested branch failed for another reason"; printf '%s\n' "$out" | tail -n 15 | sed 's/^/      /'
  fi
  git checkout -q -- "$file"
  rm -rf .stryker-tmp reports mutants tests/DemoApp.Domain.Tests/StrykerOutput mutants.out mutants.out.old
  popd >/dev/null || return
}

# The frontend question only offers what each stack implements: copier's validator rejects the rest.
expect_fail "copier: frontend=react on go" render go '["codex"]' "$work/invalid-go-react" -d frontend=react
expect_fail "copier: frontend=ssr on typescript" render typescript '["codex"]' "$work/invalid-ts-ssr" -d frontend=ssr
echo

model_check_checks() { # in the full render (model_check=true): TLC passes the model and finds the seeded race
  local model=models/ExportWorkers.tla
  verify "model-check: TLC on $model" "bash ci/model-check.sh"
  # Drop the owner check from the commit fence: a worker whose lease expired can then complete the job.
  sed -i '/^CanCommit(w, j) ==/s| /. owner\[j\] = w$||' "$model"
  if grep -q '^CanCommit(w, j) == state\[j\] = "running"$' "$model"; then
    expect_fail "model-check: completion without the owner fence" bash ci/model-check.sh
  else
    fail "model-check: could not seed the race in $model"
  fi
  git checkout -q -- "$model"
}

task_checks() { # in the full render (both tools, git repo on main): scripts/new-task.sh and scripts/end-task.sh
  local tasks
  grep -q 'scripts/new-task.sh' AGENTS.md && grep -q 'scripts/new-task.sh' docs/engineering/parallel-work.md \
    && grep -qF -- '- [x] worktree' docs/roadmap.md && pass "parallel work documented" || fail "parallel work docs missing"
  tasks="../$(basename "$PWD")-tasks"
  if bash scripts/new-task.sh a >/dev/null && bash scripts/new-task.sh b >/dev/null \
    && grep -q '^export TASK_SLOT=1$' "$tasks/a/.task/env" && grep -q '^export E2E_PORT=20102$' "$tasks/a/.task/env" \
    && grep -q '^export TASK_SLOT=2$' "$tasks/b/.task/env" && grep -q '^export E2E_PORT=20202$' "$tasks/b/.task/env"; then
    pass "new-task: two tasks, distinct ports"
  else
    fail "new-task: two tasks, distinct ports"
  fi
  (cd "$tasks/a" && bash scripts/new-task.sh c >/dev/null) && [ -f "$tasks/c/.task/env" ] && [ ! -e "$tasks/a-tasks" ] \
    && pass "new-task: from a task worktree" || fail "new-task: from a task worktree"
  expect_fail "new-task: fourth task over MAX_TASKS=3" bash scripts/new-task.sh d
  expect_fail "new-task: bad name" bash scripts/new-task.sh Bad_Name
  [ -z "$(git -C "$tasks/a" status --porcelain)" ] && pass "new-task: task files ignored" || fail "new-task: task files show in git status"
  grep -q '"E2E_PORT": "20102"' "$tasks/a/.claude/settings.local.json" && pass "new-task: claude env" || fail "new-task: claude env"
  grep -q "$(git rev-parse main)" "$tasks/a/.task/brief.md" && grep -q 'COMPOSE_PROJECT_NAME=demo-app-a' "$tasks/a/.task/env" \
    && pass "new-task: brief has base SHA, compose project per task" || fail "new-task: brief or compose project"

  touch "$tasks/a/x.txt"
  expect_fail "end-task: dirty worktree" bash scripts/end-task.sh a
  rm -f "$tasks/a/x.txt"
  (cd "$tasks/b" && echo b > b.txt && git add b.txt && git -c user.name=t -c user.email=t@t commit -qm b)
  expect_fail "end-task: unmerged branch" bash scripts/end-task.sh b
  bash scripts/end-task.sh b --force >/dev/null && [ ! -e "$tasks/b" ] && ! git show-ref -q --verify refs/heads/task/b \
    && pass "end-task: --force" || fail "end-task: --force"
  bash scripts/end-task.sh a >/dev/null && bash scripts/new-task.sh e >/dev/null && grep -q '^export TASK_SLOT=1$' "$tasks/e/.task/env" \
    && pass "end-task: slot reused" || fail "end-task: slot reused"
  expect_fail "end-task: from inside the task" bash -c "cd '$tasks/c' && bash scripts/end-task.sh c"
  bash scripts/end-task.sh c >/dev/null && bash scripts/end-task.sh e >/dev/null && [ -z "$(git worktree list | sed 1d)" ] \
    && pass "end-task: all tasks removed" || fail "end-task: tasks left behind"
  # A squash merge (what automerge does) leaves the task's own commits out of main; the change is in, so it is merged.
  bash scripts/new-task.sh s >/dev/null
  (cd "$tasks/s" && echo s > s.txt && git add s.txt && git -c user.name=t -c user.email=t@t commit -qm s)
  git merge -q --squash task/s && git -c user.name=t -c user.email=t@t commit -qm "squash s"
  # No git identity, as on CI runners: end-task must not need one.
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash scripts/end-task.sh s >/dev/null && pass "end-task: squash-merged task" || fail "end-task: squash-merged task refused"
  # No origin/HEAD and no local main: the default branch is the main checkout's branch.
  bash scripts/new-task.sh t >/dev/null && git branch -q -m main trunk
  bash scripts/end-task.sh t >/dev/null && pass "end-task: default branch without origin/HEAD or main" \
    || fail "end-task: default branch without origin/HEAD or main"
  git branch -q -m trunk main
  # Each task builds its own image tag, so one task's build cannot replace another's.
  if [ -f compose.yaml ]; then
    bash scripts/new-task.sh i >/dev/null
    grep -q 'IMAGE_TAG:-local' compose.yaml && grep -q '^export IMAGE_TAG=task-i$' "$tasks/i/.task/env" \
      && pass "new-task: image tag per task" || fail "new-task: image tag per task"
    bash scripts/end-task.sh i >/dev/null
  fi
}

release_check_files() { # release_check_files <render-dir> <tools>: the release check exists in every render
  local wf="$1/.github/workflows/release-check.yml"
  if [ -f "$wf" ] && [ -f "$1/ci/release-report.sh" ] && ! grep -q 'pull_request' "$wf" && grep -q "tags: \[\"v\*\"\]" "$wf" \
    && grep -q 'PROPERTY_RUNS: "10000"' "$wf" && grep -q 'no v\* tag' "$wf"; then
    pass "release check workflow ($2)"
  else
    fail "release check workflow missing, or runs on pull requests ($2)"
  fi
  # The full scan runs exactly where the per-PR baseline scan does.
  if [ -f "$1/ci/dast.sh" ] && grep -q '^  dast-full:' "$wf"; then
    pass "release check: full scan with a container ($2)"
  elif [ ! -f "$1/ci/dast.sh" ] && ! grep -q 'dast-full' "$wf"; then
    pass "release check: no full scan without a scanned container ($2)"
  else
    fail "release check: dast-full does not match ci/dast.sh ($2)"
  fi
}

gh_stub() { # gh_stub <dir>: a fake gh on PATH that logs its arguments to $GH_LOG ($GH_EXISTING: an open issue number)
  mkdir -p "$1"
  cat >"$1/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "issue list") [ -z "${GH_EXISTING:-}" ] || echo "$GH_EXISTING" ;;
  "issue create") echo "https://github.com/o/r/issues/41" ;;
  "pr create") case " $* " in *" --draft "*) [ -z "${GH_NO_DRAFT:-}" ] || exit 1 ;; esac; echo "https://github.com/o/r/pull/42" ;;
esac
EOF
  chmod +x "$1/gh"
}

release_check_checks() { # in the full render: actionlint, and ci/release-report.sh files one issue per failing job
  local vol stub log
  vol=$(docker_vol)
  MSYS_NO_PATHCONV=1 verify "actionlint: release-check workflow" \
    "docker run --rm -v '$vol:/repo' -w /repo rhysd/actionlint:1.7.7 .github/workflows/release-check.yml"
  stub="$work/gh-stub" log="$work/gh.log"
  gh_stub "$stub"
  : >"$log"
  PATH="$stub:$PATH" GH_LOG="$log" bash ci/release-report.sh property v1.2.0 abc123 https://ci/run/1 >/dev/null 2>&1
  grep -q '^issue create .*--label release-check' "$log" && grep -q 'release-check: property failed on v1.2.0' "$log" \
    && pass "release-report: new issue" || fail "release-report: no issue created ($(tr '\n' ';' <"$log"))"
  : >"$log"
  PATH="$stub:$PATH" GH_LOG="$log" GH_EXISTING=7 bash ci/release-report.sh property v1.3.0 def456 https://ci/run/2 >/dev/null 2>&1
  grep -q '^issue comment 7 ' "$log" && ! grep -q '^issue create' "$log" \
    && pass "release-report: comments on the open issue" || fail "release-report: duplicate issue ($(tr '\n' ';' <"$log"))"
}

automerge_checks() { # in the full render (automerge=true): ci/risk-tier.sh by path, and the workflow lints clean
  local first case want got file
  first=$(sed -n 's/.*"Edit(\/\([^*)]*\))".*/\1/p' .claude/settings.json | head -1)
  # <file to change>:<expected tier>
  for case in docs/feature-map.md:0 README.md:0 notes.txt:1 "$(git ls-files | grep -v '^ci/' | grep -m1 -E '\.(ts|py|cs|go|rs)$')":1 \
    AGENTS.md:3 docs/risk-tiers.md:3 ci/guardrail-ratchet.sh:3 .github/workflows/ci.yml:3 "$first":3 \
    models/ExportWorkers.tla:3 auth/login.txt:3 src/auth/login.txt:3 migrations/0001_create_export_artifacts.sql:3; do
    want=${case##*:}
    file=${case%:*}
    git switch -q -c tier-probe base
    mkdir -p "$(dirname "$file")" && printf '\nprobe\n' >> "$file"
    git add -A && git -c user.name=t -c user.email=t@t commit -qm probe
    got=$(bash ci/risk-tier.sh base 2>&1)
    git switch -q main && git branch -qD tier-probe
    [ "$got" = "$want" ] && pass "risk-tier: $file -> $want" || fail "risk-tier: $file -> $got (want $want)"
  done
  local vol
  vol=$(docker_vol)
  MSYS_NO_PATHCONV=1 verify "actionlint: automerge workflow" \
    "docker run --rm -v '$vol:/repo' -w /repo rhysd/actionlint:1.7.7 .github/workflows/automerge.yml"
}

# Checks that each use their own render, grouped so CI can run them as separate jobs (SHARD, see the header).
datastores_extras_typescript() {
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
}
ui_extras_typescript() {
  frontend_checks react
  frontend_checks vue
  frontend_checks nextjs
  frontend_checks angular
  frontend_checks react-native
}
datastores_extras_python() {
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
}
ui_extras_python() {
  ssr_checks python "uv sync" src/demo_app/adapters/web/templates/index.html '/"Content-Security-Policy":/d' \
    src/demo_app/application/complete_export.py '\nimport jinja2\n\nENGINE = jinja2\n' "uv run lint-imports"
  ssr_api_checks python "uv sync" "uv run pytest -q -p no:warnings -m e2e"         seeded "ssr: import-linter: driver imported in the UI" src/demo_app/adapters/web/routes.py '
import psycopg

DRIVER = psycopg
' uv run lint-imports
}
datastores_extras_dotnet() {
  mariadb_checks dotnet "dotnet build" 'dotnet test --project tests/DemoApp.Tests --no-build --filter-trait "Category=Integration"'
  sqlserver_checks dotnet "dotnet build" 'dotnet test --project tests/DemoApp.Tests --no-build --filter-trait "Category=Integration"'
  oracle_checks dotnet "dotnet build" 'dotnet test --project tests/DemoApp.Tests --no-build --filter-trait "Category=Integration"'
  mongodb_checks dotnet "dotnet build" 'dotnet test --project tests/DemoApp.Tests --no-build --filter-trait "Category=Integration"'
  dynamodb_checks dotnet "dotnet build" 'dotnet test --project tests/DemoApp.Tests --no-build --filter-trait "Category=Integration"'
  cosmosdb_checks dotnet "dotnet build" 'dotnet test --project tests/DemoApp.Tests --no-build --filter-trait "Category=Integration"'
  s3_checks dotnet "dotnet build" 'dotnet test --project tests/DemoApp.Tests --no-build --filter-trait "Category=Integration"'
}
ui_extras_dotnet() {
  ssr_checks dotnet "dotnet restore" src/DemoApp.Adapters/Web/Pages/Index.cshtml '/headers.ContentSecurityPolicy = /d' \
    src/DemoApp.Application/CompleteExport.cs '\npublic static class PageLeak\n{\n    public static Microsoft.AspNetCore.Html.HtmlString Render() => new("x");\n}\n' \
    'sed -i "s#</Project>#  <ItemGroup><FrameworkReference Include=\"Microsoft.AspNetCore.App\" /></ItemGroup>\n</Project>#" src/DemoApp.Application/DemoApp.Application.csproj; out=$(dotnet test --project tests/DemoApp.Tests --filter-trait "Category=Architecture" 2>&1); git checkout -q -- src/DemoApp.Application/DemoApp.Application.csproj; ! grep -q "Domain/Application must not touch I/O" <<<"$out"' \
    src/DemoApp.Adapters/Web/Pages/Index.cshtml.cs '\npublic static class DriverLeak\n{\n    public static System.Data.Common.DbConnection? Connection { get; set; }\n}\n' \
    'dotnet test --project tests/DemoApp.Tests --filter-trait "Category=Architecture"'
  ssr_api_checks dotnet "dotnet restore" 'dotnet test --project tests/DemoApp.Tests --filter-trait "Category=E2E"'
}
datastores_extras_go() {
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
}
ui_extras_go() {
  ssr_checks go "go mod tidy" internal/adapters/web/templates/index.html '/Content-Security-Policy/d' \
    internal/application/web_leak.go 'package application\n\nimport _ "html/template"\n' "go tool golangci-lint run --enable-only depguard ./internal/application/"
  ssr_api_checks go "go mod tidy" "go test -tags e2e ./..."         seeded_new "ssr: depguard: driver imported in the UI" internal/adapters/web/driver_leak.go 'package web

import _ "github.com/jackc/pgx/v5/pgxpool"
' go tool golangci-lint run --enable-only depguard ./internal/adapters/web/
}
datastores_extras_rust() {
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
}
ui_extras_rust() {
  ssr_checks rust "cargo fetch -q" crates/adapters/templates/index.html '/CONTENT_SECURITY_POLICY, PAGE_CSP/d' \
    crates/application/Cargo.toml 'askama = "0.16"\n' "bash ci/check-layers.sh" \
    crates/adapters/src/web.rs '\nuse redis::Client;\n' "bash ci/check-layers.sh"
  ssr_api_checks rust "cargo fetch -q" "npm --prefix e2e install --no-audit --no-fund && npm --prefix e2e test"
}

core_checks() { # the agent-tool renders, the defaults, and the full render of $stack
  echo "== $stack"

  # Agent-tool combinations: only the file set changes.
  # The both-tools render also sets a guardrail owner; the others leave it empty (no CODEOWNERS).
  for tools in '["claude"]' '["codex"]' '["claude","codex"]'; do
    d="$work/$stack-$(echo "$tools" | tr -dc 'a-z,' | tr ',' '-')"  # no comma: MSBuild (Stryker.NET's project analysis) breaks on it
    # The both-tools render also wires in every datastore and the HTTP API; it gets the full verification below.
    if [ "$tools" = '["claude","codex"]' ]; then
      owner_args=(-d guardrail_owner=@demo-org/platform -d 'datastores=["postgres","mysql","redis"]' -d http_api=true
        -d model_check=true -d automerge=true)
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
      [ -f "$d/models/ExportWorkers.tla" ] && [ -f "$d/ci/model-check.sh" ] && grep -q 'model-check:' "$d/.github/workflows/ci.yml" \
        && grep -q '^/models/' "$d/.github/CODEOWNERS" && [ -f "$d/.github/workflows/automerge.yml" ] && [ -f "$d/ci/risk-tier.sh" ] \
        && pass "model check and automerge files ($tools)" || fail "model check or automerge files missing ($tools)"
    else
      [ ! -e "$d/models" ] && [ ! -e "$d/ci/model-check.sh" ] && ! grep -q 'model-check:' "$d/.github/workflows/ci.yml" \
        && [ ! -e "$d/.github/workflows/automerge.yml" ] && [ ! -e "$d/ci/risk-tier.sh" ] \
        && pass "no model check or automerge files by default ($tools)" || fail "model check or automerge files generated by default ($tools)"
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
    release_check_files "$d" "$tools"
    # GitHub workflows use ${{ }} themselves.
    if grep -rIl '{{\|{%' "$d" --exclude-dir=node_modules --exclude-dir=.venv --exclude=ci.yml --exclude=automerge.yml --exclude=release-check.yml --exclude=release-fuzz.yml >/dev/null; then
      fail "unrendered Jinja in $(grep -rIl '{{\|{%' "$d" --exclude=ci.yml --exclude=automerge.yml --exclude=release-check.yml --exclude=release-fuzz.yml | head -1)"
    fi
  done

  default_verify "$stack"
  property_runs_check "$stack"
  default_mutation "$stack"

  # Full verification on the both-tools render.
  d="$work/$stack-claude-codex"
  cd "$d" || return
  git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm base && git branch -q base
  model_check_checks
  automerge_checks
  task_checks
  release_check_checks
  case "$stack" in
    typescript)
      npm install --no-audit --no-fund >/dev/null 2>&1
      verify "npm run verify" "npm run verify"
      full_mutation typescript
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
      verify "integration: adapter contracts on real PostgreSQL + Redis" "npm run test:integration"
      # HTTP API (docs/adr/0004-http-api.md). A task worktree moves the test port (docs/engineering/parallel-work.md).
      grep -q 'process.env.E2E_PORT' playwright.config.ts && grep -q 'APP_PORT:-8080' compose.yaml \
        && pass "ports read the environment" || fail "test or compose ports are fixed"
      verify "playwright: API tests on E2E_PORT=28702" "E2E_PORT=28702 npm run test:e2e"
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
      printf '\nimport { InMemoryArtifactStore } from "../adapters/in-memory-artifact-store.ts";\nexport const leak = new InMemoryArtifactStore() as any;\n' >> src/domain/export-job.ts
      expect_fail "eslint: as any" npm run lint
      expect_fail "depcruise: domain -> adapters" npm run arch
      ;;
    python)
      uv sync >/dev/null 2>&1
      verify "python verify" "${verify_cmd[python]}"
      full_mutation python
      # Dependency audit: clean on the render, rejects a known-vulnerable package.
      verify "uv audit" "uv audit --locked --preview-features audit-command"
      cp pyproject.toml uv.lock "$work/"
      # pyyaml 5.3 has known advisories and no dependencies. Only below Python 3.14: libcst (via mutmut) needs
      # pyyaml >= 6.0.3 on 3.14+, so an unconditional pin cannot resolve and the audit would pass.
      uv add --no-sync "pyyaml==5.3; python_full_version < '3.14'" >/dev/null 2>&1
      expect_fail "uv audit: vulnerable dependency" uv audit --locked --preview-features audit-command
      cp "$work/pyproject.toml" "$work/uv.lock" .
      # Container and secret scanning (docs/security/owasp.md).
      container_checks python
      secret_checks
      # Datastores (docs/adr/0003-datastores.md).
      datastore_checks python
      verify "integration: adapter contracts on real PostgreSQL + Redis" "uv run pytest -q -p no:warnings -m integration"
      # HTTP API (docs/adr/0004-http-api.md).
      http_checks python "uv run pytest -q -p no:warnings -m e2e" src/demo_app/adapters/http/app.py '/"X-Content-Type-Options": "nosniff",/d'
      seeded "import-linter: web framework imported in application" src/demo_app/application/complete_export.py '\nimport fastapi\n\nFRAMEWORK = fastapi\n' uv run lint-imports
      seeded "import-linter: driver imported in application" src/demo_app/application/complete_export.py '\nimport psycopg\n\nDRIVER = psycopg\n' uv run lint-imports
      seeded "import-linter: driver imported in bootstrap" src/demo_app/bootstrap/main.py '\nimport redis\n\nDRIVER = redis\n' uv run lint-imports
      # Server-rendered UI (ADR 0005), alone and sharing the server with the JSON API.
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
      full_mutation dotnet
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
      verify "integration: adapter contracts on real PostgreSQL + Redis" 'dotnet test --project tests/DemoApp.Tests --filter-trait "Category=Integration"'
      # HTTP API (docs/adr/0004-http-api.md).
      http_checks dotnet 'dotnet test --project tests/DemoApp.Tests --filter-trait "Category=E2E"' src/DemoApp.Adapters/Http/ExportEndpoints.cs '/headers.XContentTypeOptions = "nosniff";/d'
      # Server-rendered UI (ADR 0005), alone and sharing the server with the JSON API. The Application seed adds the
      # framework reference too (without it the seed would only fail to compile) and must be caught by the arch test.
      seeded "CA2100: SQL built by concatenation" src/DemoApp.Adapters/PostgresArtifactStore.cs '\npublic static class Unsafe\n{\n    public static NpgsqlCommand Query(NpgsqlConnection connection, string jobId) =>\n        new() { Connection = connection, CommandText = "SELECT body FROM export_artifacts WHERE job_id = \x27" + jobId + "\x27" };\n}\n' dotnet build
      # Design rules (ADR 0002), one violation at a time.
      seeded "BannedApi: ambient clock in Domain" src/DemoApp.Domain/ExportJob.cs '\npublic static class Clock\n{\n    public static DateTime Now() => DateTime.UtcNow;\n}\n' dotnet build
      seeded "BannedApi: Guid.NewGuid in Application" src/DemoApp.Application/CompleteExport.cs '\npublic static class Ids\n{\n    public static Guid Next() => Guid.NewGuid();\n}\n' dotnet build
      seeded "naming: async method without Async suffix" src/DemoApp.Adapters/InMemoryArtifactStore.cs '\npublic static class Waits\n{\n    public static async Task Pause() => await Task.CompletedTask.ConfigureAwait(false);\n}\n' dotnet build
      seeded "NetArchTest: unsealed concrete class" src/DemoApp.Application/CompleteExport.cs '\npublic class Helper\n{\n    public int Value { get; init; }\n}\n' dotnet test --project tests/DemoApp.Tests --filter-trait "Category=Architecture"
      printf '\npublic static class Leak\n{\n#pragma warning disable CA1823\n    public static string Value = null!;\n}\n' >> src/DemoApp.Domain/ExportJob.cs
      expect_fail "build: TreatWarningsAsErrors" dotnet build
      ;;
    go)
      go mod tidy >/dev/null 2>&1
      verify "go verify" "${verify_cmd[go]}"
      full_mutation go
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
      verify "integration: adapter contracts on real PostgreSQL + Redis" "go test -tags integration ./..."
      seeded_new "ruleguard: SQL built by concatenation" internal/adapters/postgres/unsafe.go 'package postgres\n\nimport "context"\n\n// Unsafe builds SQL from a value.\nfunc (s *Store) Unsafe(ctx context.Context, jobID string) error {\n\t_, err := s.pool.Exec(ctx, "SELECT body FROM export_artifacts WHERE job_id = \x27"+jobID+"\x27")\n\treturn err //nolint:wrapcheck // seeded\n}\n' go tool golangci-lint run ./internal/adapters/postgres/
      seeded_new "depguard: driver imported in application" internal/application/driver.go 'package application\n\nimport "github.com/jackc/pgx/v5/pgxpool"\n\n// Pool leaks the driver into the application layer.\ntype Pool = pgxpool.Pool\n' go tool golangci-lint run --enable-only depguard ./internal/application/
      # HTTP API (docs/adr/0004-http-api.md).
      http_checks go "go test -tags e2e ./..." internal/adapters/httpapi/handler.go '/headers.Set("X-Content-Type-Options", "nosniff")/d'
      # Server-rendered UI (ADR 0005), alone and sharing the server with the JSON API.
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
      full_mutation rust
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
      verify "integration: adapter contracts on real PostgreSQL + Redis" "cargo test -p adapters --features integration"
      seeded "sqlx: SQL built from a string does not compile" crates/adapters/src/postgres.rs '\n/// Builds SQL from a value.\npub async fn unsafe_read(pool: &PgPool, job_id: &str) -> Result<(), PortError> {\n    let sql = format!("SELECT body FROM export_artifacts WHERE job_id = \x27{job_id}\x27");\n    sqlx::query(&sql).execute(pool).await?;\n    Ok(())\n}\n' cargo check -p adapters
      seeded "check-layers: driver in bootstrap" crates/bootstrap/Cargo.toml 'redis = "1.8"\n' bash ci/check-layers.sh
      # HTTP API (docs/adr/0004-http-api.md).
      http_checks rust "npm --prefix e2e install --no-audit --no-fund && npm --prefix e2e test" crates/adapters/src/http.rs '/X_CONTENT_TYPE_OPTIONS/d'
      # Server-rendered UI (ADR 0005), alone and sharing the server with the JSON API.
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
    dotnet) sed -i 's/\[Fact\]/[Fact(Skip = "x")]/' tests/DemoApp.Domain.Tests/ExportJobTests.cs ;;
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
}

for stack in "${stacks[@]}"; do
  part core && core_checks
  part datastores && { echo "== $stack (datastores)"; "datastores_extras_$stack"; }
  part ui && { echo "== $stack (ui)"; "ui_extras_$stack"; }
  cd "$repo" || exit 1
done

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASSED"; else echo "$failures FAILURE(S)"; exit 1; fi
