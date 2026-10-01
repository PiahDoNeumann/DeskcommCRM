#!/usr/bin/env bash
# Stack local do fork no Docker Desktop (Windows, Git Bash).
#
#   bash docker/deskcrm/local.sh up        Supabase + app (sobe tudo; 1ª vez cria banco e dono)
#   bash docker/deskcrm/local.sh down      para tudo (dados do banco ficam)
#   bash docker/deskcrm/local.sh status    o que está de pé
#   bash docker/deskcrm/local.sh logs      logs do app (Ctrl+C sai)
#   bash docker/deskcrm/local.sh build     reconstrói a imagem com o código atual
#   bash docker/deskcrm/local.sh studio    (re)sobe só o Studio do Supabase
#   bash docker/deskcrm/local.sh baseline  reaplica supabase/baseline.sql (depois de sync com upstream)
#   bash docker/deskcrm/local.sh reset     APAGA o banco local e recomeça do zero
#
# Por que não scripts/local-stack.sh do upstream: ele usa `--network host` e
# `hostname -I` (Linux/VM). No Docker Desktop os contêineres chegam no host por
# host.docker.internal, e o app usa SUPABASE_SERVER_URL para isso.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE=".env.deskcrm-local"
IMAGE="piah2025/deskcrm:local"
COMPOSE=(docker compose -p deskcrm-local -f docker/deskcrm/docker-compose.local.yml --env-file "$ENV_FILE")
# Serviços do Supabase que o app não usa (menos memória). O Studio fica fora do
# CLI porque ele monta uma pasta do Windows nele (snippets); sobe por studio_up.
SUPABASE_EXCLUDE="edge-runtime,vector,logflare,imgproxy,supavisor,studio"

# O CLI do Supabase roda num workdir próprio (.deskcrm-local/, fora do git), com
# uma cópia do supabase/config.toml SEM os content_path dos e-mails: são eles que
# fazem o CLI montar pasta do Windows no contêiner do auth. Nada de bind mount —
# o banco nasce do baseline, copiado para dentro via stdin. Sem pasta migrations
# no workdir, o `start` não tenta a cadeia (que não sobe do zero).
SB_WORKDIR="$ROOT_DIR/.deskcrm-local"

supabase() { npx --yes supabase --workdir "$SB_WORKDIR" "$@"; }

supabase_up() {
  mkdir -p "$SB_WORKDIR/supabase"
  grep -v '^content_path' supabase/config.toml \
    | sed 's/^project_id = .*/project_id = "deskcrm-local"/' > "$SB_WORKDIR/supabase/config.toml"
  grep -qx '.deskcrm-local/' .git/info/exclude 2>/dev/null || echo '.deskcrm-local/' >> .git/info/exclude
  if supabase status >/dev/null 2>&1; then return; fi
  supabase start -x "$SUPABASE_EXCLUDE"
}

# Studio sem pasta: a mesma imagem do CLI, na rede do Supabase, sem volume.
# Sem a pasta de snippets, consulta salva no SQL Editor não persiste.
STUDIO="supabase_studio_deskcrm-local"

studio_up() {
  docker rm -f "$STUDIO" >/dev/null 2>&1 || true
  local image
  image="$(docker image ls public.ecr.aws/supabase/studio --format '{{.Repository}}:{{.Tag}}' | head -1)"
  [[ -n "$image" ]] || image="public.ecr.aws/supabase/studio:latest"
  docker run -d --name "$STUDIO" --network supabase_network_deskcrm-local \
    -p 127.0.0.1:54323:3000 \
    -e STUDIO_PG_META_URL=http://supabase_pg_meta_deskcrm-local:8080 \
    -e POSTGRES_PASSWORD=postgres \
    -e SUPABASE_URL=http://supabase_kong_deskcrm-local:8000 \
    -e SUPABASE_PUBLIC_URL=http://localhost:54321 \
    -e SUPABASE_ANON_KEY="$(sb_value ANON_KEY)" \
    -e SUPABASE_SERVICE_KEY="$(sb_value SERVICE_ROLE_KEY)" \
    -e AUTH_JWT_SECRET="$(sb_value JWT_SECRET)" \
    -e DEFAULT_ORGANIZATION_NAME="DeskCRM Local" \
    -e DEFAULT_PROJECT_NAME="deskcrm-local" \
    -e NEXT_PUBLIC_ENABLE_LOGS=false \
    "$image" >/dev/null
}

sb_value() { supabase status -o env 2>/dev/null | sed -nE "s/^$1=\"?([^\"]*)\"?$/\1/p"; }

psql_host() {
  docker run --rm -i --add-host host.docker.internal:host-gateway postgres:15-alpine \
    psql "postgresql://postgres:postgres@host.docker.internal:54322/postgres" "$@"
}

# $1 = 1 em banco novo (install: para no 1º erro); 0 ao reaplicar em banco
# existente (update: o baseline é idempotente e segue, como no update.sh).
apply_baseline() {
  psql_host -q -v ON_ERROR_STOP=1 -c 'create extension if not exists "uuid-ossp";
    create extension if not exists pgcrypto;
    create extension if not exists vector;
    create extension if not exists citext;
    create extension if not exists pg_trgm;'
  psql_host -q -v ON_ERROR_STOP="$1" -f - < supabase/baseline.sql > /dev/null
  echo "baseline aplicado."
}

db_is_empty() {
  [[ "$(psql_host -Atc "select to_regclass('public.organizations') is null")" == "t" ]]
}

gen_env() {
  [[ -s "$ENV_FILE" ]] && return
  local anon service waha_key
  anon="$(sb_value ANON_KEY)"
  service="$(sb_value SERVICE_ROLE_KEY)"
  [[ -n "$anon" && -n "$service" ]] || { echo "Supabase não devolveu as chaves." >&2; exit 1; }
  waha_key="$(openssl rand -hex 24)"
  umask 077
  cat > "$ENV_FILE" <<EOF
# Gerado por docker/deskcrm/local.sh — só para a stack local. Não commitar.
NEXT_PUBLIC_SUPABASE_URL=http://localhost:54321
NEXT_PUBLIC_SUPABASE_ANON_KEY=$anon
SUPABASE_SERVICE_ROLE_KEY=$service
SUPABASE_DB_URL=postgresql://postgres:postgres@host.docker.internal:54322/postgres
SUPABASE_DB_ADMIN_URL=postgresql://postgres:postgres@host.docker.internal:54322/postgres

NEXT_PUBLIC_APP_URL=http://localhost:3000
NEXT_PUBLIC_ADMIN_URL=http://localhost:3000

INTERNAL_SECRET=$(openssl rand -hex 32)
INTERNAL_CRON_SECRET=$(openssl rand -hex 32)
CPF_ENCRYPTION_KEY=$(openssl rand -base64 32)
WAHA_BYO_ENCRYPTION_KEY=$(openssl rand -base64 32)
AI_CRED_AES_KEY=$(openssl rand -base64 32)
NUVEMSHOP_OAUTH_ENCRYPTION_KEY=$(openssl rand -hex 32)
LGPD_SIGNING_KEY=$(openssl rand -hex 32)
IMPERSONATE_COOKIE_SECRET=$(openssl rand -hex 32)

WAHA_API_KEY=$waha_key
WAHA_API_KEY_SHA512=$(printf '%s' "$waha_key" | sha512sum | awk '{print $1}')
WAHA_HMAC_SECRET=$(openssl rand -hex 32)
WAHA_WEBHOOK_REQUIRE_SIGNATURE=false

UPSTASH_REDIS_REST_TOKEN=deskcrm-local-redis
SRH_TOKEN=deskcrm-local-redis

# Telemetria da comunidade desligada (o padrão do upstream manda erros para eles).
SENTRY_DSN=off

# Dono criado no primeiro "up".
OWNER_EMAIL=admin@deskcrm.test
OWNER_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=')
OWNER_ORG_NAME=DeskCRM Local
EOF
  echo "ambiente gerado em $ENV_FILE"
}

env_get() { sed -nE "s/^$1=(.*)$/\1/p" "$ENV_FILE" | head -1; }

bootstrap_owner() {
  NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321 \
  SUPABASE_SERVICE_ROLE_KEY="$(env_get SUPABASE_SERVICE_ROLE_KEY)" \
  OWNER_EMAIL="$(env_get OWNER_EMAIL)" \
  OWNER_PASSWORD="$(env_get OWNER_PASSWORD)" \
  OWNER_ORG_NAME="$(env_get OWNER_ORG_NAME)" \
  SENTRY_DSN=off \
    pnpm exec tsx scripts/bootstrap-owner.ts
}

ensure_image() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 && return
  echo "imagem $IMAGE não existe — construindo (demora)."
  build_image
}

build_image() {
  docker build -f docker/deskcrm/Dockerfile \
    --build-arg APP_VERSION="local-$(git rev-parse --short HEAD)" -t "$IMAGE" .
}

case "${1:-}" in
  up)
    supabase_up
    gen_env
    if db_is_empty; then
      apply_baseline 1
      bootstrap_owner
    fi
    ensure_image
    "${COMPOSE[@]}" up -d
    studio_up
    echo
    echo "App:      http://localhost:3000   (login: $(env_get OWNER_EMAIL), senha em $ENV_FILE)"
    echo "WAHA:     http://localhost:3030"
    echo "Studio:   http://localhost:54323"
    ;;
  down)
    [[ -s "$ENV_FILE" ]] && "${COMPOSE[@]}" down
    docker rm -f "$STUDIO" >/dev/null 2>&1 || true
    supabase stop
    ;;
  status)
    supabase status || true
    [[ -s "$ENV_FILE" ]] && "${COMPOSE[@]}" ps
    ;;
  logs)
    "${COMPOSE[@]}" logs -f --tail=200 "${2:-deskcrm}"
    ;;
  build)
    build_image
    [[ -s "$ENV_FILE" ]] && "${COMPOSE[@]}" up -d deskcrm || true
    ;;
  baseline)
    apply_baseline 0
    ;;
  studio)
    studio_up
    echo "Studio:   http://localhost:54323"
    ;;
  reset)
    [[ -s "$ENV_FILE" ]] && "${COMPOSE[@]}" down -v
    docker rm -f "$STUDIO" >/dev/null 2>&1 || true
    supabase stop --no-backup
    rm -f "$ENV_FILE"
    echo "banco local apagado. Rode 'up' para recomeçar."
    ;;
  *)
    sed -n '2,10p' "$0"
    exit 2
    ;;
esac
