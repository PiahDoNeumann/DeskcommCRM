# DeskcommCRM em UM contêiner: app (Next) + worker (agente de IA) + cron,
# gerenciados pelo supervisor. Imagem do fork, construída pelo Dokploy.
#
#   Dokploy › Build Type: Dockerfile
#            Docker File: docker/deskcrm/Dockerfile
#            Docker Context Path: .
#
# O upstream publica três imagens (Dockerfile, Dockerfile.worker,
# Dockerfile.scheduler). Esta junta as três sem copiar a lógica delas:
#   - app: os mesmos estágios deps/build do Dockerfile da raiz (standalone);
#   - worker: compilado com esbuild num arquivo só, em vez de rodar sob tsx —
#     assim o estágio final não leva o node_modules completo;
#   - cron: o próprio docker/scheduler/entrypoint.sh, com o endereço do app
#     trocado para 127.0.0.1 no build.

########################################
# Estágio 1 — dependências
########################################
FROM node:22-alpine AS deps
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9.15.9 --activate
COPY package.json pnpm-lock.yaml ./
COPY patches ./patches
RUN pnpm install --frozen-lockfile

########################################
# Estágio 2 — build (app standalone + worker compilado)
########################################
FROM node:22-alpine AS build
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9.15.9 --activate
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Placeholders: os NEXT_PUBLIC_* reais entram em RUNTIME pelo ambiente
# (igual ao Dockerfile da raiz), então a imagem serve qualquer domínio.
ARG NEXT_PUBLIC_SUPABASE_URL=https://placeholder.supabase.co
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY=placeholder-anon-key
ARG NEXT_PUBLIC_APP_URL=https://placeholder.invalid
ARG NEXT_PUBLIC_ADMIN_URL=https://placeholder.invalid
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY \
    NEXT_PUBLIC_APP_URL=$NEXT_PUBLIC_APP_URL \
    NEXT_PUBLIC_ADMIN_URL=$NEXT_PUBLIC_ADMIN_URL \
    NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    NODE_OPTIONS=--max-old-space-size=4096

RUN pnpm build

# pdfjs + canvas nativo dentro do standalone (mesmo passo do Dockerfile da raiz).
# O worker compilado também os usa: ficam FORA do bundle e são resolvidos daqui.
RUN PDFJS_DIR=$(basename node_modules/.pnpm/pdfjs-dist@*) && \
    cp -a "node_modules/pdfjs-dist" ".next/standalone/node_modules/pdfjs-dist" && \
    mkdir -p ".next/standalone/node_modules/.pnpm/$PDFJS_DIR/node_modules/@napi-rs" && \
    cp -a "node_modules/.pnpm/$PDFJS_DIR/node_modules/@napi-rs/canvas" \
          ".next/standalone/node_modules/.pnpm/$PDFJS_DIR/node_modules/@napi-rs/canvas" && \
    cp "node_modules/.pnpm/$PDFJS_DIR/node_modules/pdfjs-dist/legacy/build/pdf.worker.mjs" \
       ".next/standalone/.next/server/chunks/pdf.worker.mjs"

# Worker: TypeScript -> um .mjs. O esbuild já vem no node_modules (dependência
# do tsx); o `ls` falha o build se um dia ele sumir.
RUN ESBUILD=$(ls -d node_modules/.pnpm/esbuild@*/node_modules/esbuild | tail -1) && \
    node "$ESBUILD/bin/esbuild" workers/agent-worker/main.ts \
      --bundle --platform=node --target=node22 --format=esm \
      --tsconfig=tsconfig.json \
      --external:pdfjs-dist --external:@napi-rs/canvas \
      --banner:js="import{createRequire as __cr}from'node:module';const require=__cr(import.meta.url);" \
      --outfile=/app/dist-worker/worker.mjs

# Cron: reaproveita a lista de rotas do upstream, só troca o endereço do app.
# Se a linha mudar lá, o grep falha o build em vez de gerar cron que erra calado.
RUN sed 's#^APP_ORIGIN="http://app:3000"$#APP_ORIGIN="http://127.0.0.1:3000"#' \
      docker/scheduler/entrypoint.sh > /app/dist-worker/cron.sh && \
    grep -q '^APP_ORIGIN="http://127.0.0.1:3000"$' /app/dist-worker/cron.sh

########################################
# Estágio 3 — runtime
########################################
FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production \
    PORT=3000 \
    HOSTNAME=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1 \
    KEEP_ALIVE_TIMEOUT=125000 \
    TZ=UTC

RUN apk add --no-cache ffmpeg supervisor curl tzdata
RUN addgroup -g 1001 -S nodejs && adduser -S nextjs -u 1001

COPY --from=build --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=build --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=build --chown=nextjs:nodejs /app/public ./public
COPY --from=build --chown=nextjs:nodejs /app/dist-worker/worker.mjs ./worker.mjs
# Lido pelo worker via process.cwd() (lib/agent-engine/agent/playbook-seed.ts).
COPY --from=build --chown=nextjs:nodejs /app/lib/agent-engine/playbooks ./lib/agent-engine/playbooks
COPY --from=build /app/dist-worker/cron.sh /usr/local/bin/cron.sh
COPY docker/deskcrm/supervisord.conf /etc/supervisord.conf
RUN chmod +x /usr/local/bin/cron.sh

ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION

EXPOSE 3000

# supervisord roda como root (o crond exige); app e worker descem para nextjs.
CMD ["supervisord", "-c", "/etc/supervisord.conf", "-n"]
