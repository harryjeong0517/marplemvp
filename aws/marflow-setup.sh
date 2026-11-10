#!/bin/bash
# ════════════════════════════════════════════════════════════
#  MARFLOW · AWS 서버 설치 (EC2 Amazon Linux 2023 · x86_64)
#  실행: sudo bash marflow-setup.sh
#  하는 일: PostgreSQL 클라이언트 · PostgREST · Caddy 설치 → RDS에 표/함수 만들기 → 서비스 등록 → HTTPS 확인
# ════════════════════════════════════════════════════════════
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "sudo 로 실행해 주세요: sudo bash $0"; exit 1; }
APP_KEY='mf_TIzElYt3pKdrMabs1aDTCkOC71JInkAPbX09bc4O'
PGRST_VER=v12.2.3
CADDY_VER=2.8.4
ask() { local v; read -r -p "$1" v </dev/tty; echo "$v"; }
asks() { local v; read -r -s -p "$1" v </dev/tty; echo >&2; echo "$v"; }

echo "── 1/6 설정값 입력 ──────────────────────────────"
if [ -f /etc/marflow/env ]; then echo "(이미 설치된 설정이 있어요 → /etc/marflow/env 를 그대로 써요)"; source /etc/marflow/env; fi
DOMAIN=${DOMAIN:-$(ask "API 주소 (예: api.marple.co.kr): ")}
DB_HOST=${DB_HOST:-$(ask "RDS 엔드포인트 (예: marflow-db.xxxx.ap-northeast-2.rds.amazonaws.com): ")}
if [ -z "${PGRST_DB_URI:-}" ]; then
  DB_ADMIN=$(ask "RDS 마스터 사용자 이름 [postgres]: "); DB_ADMIN=${DB_ADMIN:-postgres}
  DB_ADMIN_PW=$(asks "RDS 마스터 비밀번호: ")
  PGRST_PW=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
fi

echo "── 2/6 프로그램 설치 ──────────────────────────────"
dnf install -y -q postgresql16 jq tar xz >/dev/null
dnf install -y -q dnf-automatic >/dev/null 2>&1 && sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf && systemctl enable --now dnf-automatic.timer >/dev/null 2>&1 || echo "(자동 보안 업데이트 설정은 건너뜀)"
cd /tmp
if [ ! -x /usr/local/bin/postgrest ]; then
  curl -fsSL -o pgrst.tar.xz "https://github.com/PostgREST/postgrest/releases/download/${PGRST_VER}/postgrest-${PGRST_VER}-linux-static-x64.tar.xz"
  tar xf pgrst.tar.xz && install -m 755 postgrest /usr/local/bin/postgrest
fi
if [ ! -x /usr/local/bin/caddy ]; then
  curl -fsSL -o caddy.tgz "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VER}/caddy_${CADDY_VER}_linux_amd64.tar.gz"
  tar xzf caddy.tgz caddy && install -m 755 caddy /usr/local/bin/caddy
fi
id caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --shell /sbin/nologin caddy
id pgrst >/dev/null 2>&1 || useradd --system --shell /sbin/nologin pgrst
mkdir -p /var/lib/caddy /etc/marflow && chown caddy:caddy /var/lib/caddy

echo "── 3/6 데이터베이스 만들기 ──────────────────────────────"
if [ -z "${PGRST_DB_URI:-}" ]; then
  export PGPASSWORD="$DB_ADMIN_PW"
  ADMIN_BASE="host=$DB_HOST port=5432 user=$DB_ADMIN sslmode=${DB_SSLMODE:-require}"
  [ "$(psql "$ADMIN_BASE dbname=postgres" -tAc "select 1 from pg_database where datname='marflow'")" = 1 ] || psql "$ADMIN_BASE dbname=postgres" -c "create database marflow"
  cat > /tmp/01_db_setup.sql <<'SQL_EOF'
-- ════════════════════════════════════════════════════════════
--  MARFLOW · AWS RDS(PostgreSQL) 초기 설정 — 서버(EC2)에서 한 번 실행
--  Supabase와 같은 구조: erp_docs 표 1개 + 저장 함수 erp_upsert + 서버 시각 기록
--  실행: psql "$DB_ADMIN_URI" -v pgrst_pw="$PGRST_PW" -f 01_db_setup.sql
-- ════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on

create table if not exists public.erp_docs (
  coll        text        not null,               -- 종류 (projects, users, v_venues …)
  id          text        not null,               -- 문서 id
  data        jsonb,                              -- 내용
  deleted     boolean     not null default false, -- 삭제 표시
  updated_at  timestamptz not null default clock_timestamp(),
  updated_by  text,
  primary key (coll, id)
);
create index if not exists erp_docs_updated_at_idx on public.erp_docs (updated_at);

-- 저장할 때마다 서버 시각으로 updated_at 갱신
create or replace function public.erp_docs_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end $$;
drop trigger if exists erp_docs_touch on public.erp_docs;
create trigger erp_docs_touch before insert or update on public.erp_docs
  for each row execute function public.erp_docs_touch();

-- 저장 함수: 같은 문서를 동시에 고쳐도 각자 "바꾼 칸"만 반영 (Supabase와 같은 내용)
create or replace function public.erp_upsert(docs jsonb, who text default '')
returns void language plpgsql as $$
declare d jsonb; cur jsonb; merged jsonb; k text; nd jsonb; bs jsonb;
begin
  for d in select * from jsonb_array_elements(docs) loop
    if coalesce((d->>'deleted')::boolean, false) then
      insert into public.erp_docs (coll, id, data, deleted, updated_by) values (d->>'coll', d->>'id', null, true, who)
      on conflict (coll, id) do update set data = null, deleted = true, updated_by = excluded.updated_by;
    else
      nd := d->'data'; bs := d->'base'; merged := nd;
      select data into cur from public.erp_docs where coll = d->>'coll' and id = d->>'id' and not deleted for update;
      if cur is not null and bs is not null and jsonb_typeof(cur) = 'object' and jsonb_typeof(nd) = 'object'
         and jsonb_typeof(bs) = 'object' and cur <> bs then
        merged := cur;
        for k in select jsonb_object_keys(nd || bs) loop
          if (nd -> k) is distinct from (bs -> k) then
            if nd ? k then merged := merged || jsonb_build_object(k, nd -> k); else merged := merged - k; end if;
          end if;
        end loop;
      end if;
      insert into public.erp_docs (coll, id, data, deleted, updated_by) values (d->>'coll', d->>'id', merged, false, who)
      on conflict (coll, id) do update set data = excluded.data, deleted = false, updated_by = excluded.updated_by;
    end if;
  end loop;
end $$;

-- PostgREST용 계정: web_anon(앱 권한) · pgrst(PostgREST가 접속할 때 쓰는 계정)
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'web_anon') then create role web_anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'pgrst') then create role pgrst login noinherit; end if;
end $$;
alter role pgrst with password :'pgrst_pw';
grant web_anon to pgrst;
grant usage on schema public to web_anon;
grant select, insert, update, delete on public.erp_docs to web_anon;
grant execute on function public.erp_upsert(jsonb, text) to web_anon;
-- 함수는 기본적으로 누구나 실행 가능하니, 다른 함수는 막아 둠
revoke execute on function public.erp_docs_touch() from public;

select count(*) as erp_docs_rows from public.erp_docs;
SQL_EOF
  psql "$ADMIN_BASE dbname=marflow" -v pgrst_pw="$PGRST_PW" -f /tmp/01_db_setup.sql
  rm -f /tmp/01_db_setup.sql; unset PGPASSWORD
  PGRST_DB_URI="postgres://pgrst:${PGRST_PW}@${DB_HOST}:5432/marflow?sslmode=${DB_SSLMODE:-require}"
fi

echo "── 4/6 설정 파일 ──────────────────────────────"
cat > /etc/marflow/env <<ENV_EOF
DOMAIN=$DOMAIN
APP_KEY=$APP_KEY
DB_HOST=$DB_HOST
PGRST_DB_URI=$PGRST_DB_URI
ENV_EOF
chmod 640 /etc/marflow/env; chown root:pgrst /etc/marflow/env
cat > /etc/marflow/postgrest.conf <<'CONF_EOF'
# ════ PostgREST 설정 ════  (db-uri 는 /etc/marflow/env 의 PGRST_DB_URI 로 들어와요)
db-schemas = "public"
db-anon-role = "web_anon"
db-pool = 10
server-host = "127.0.0.1"
server-port = 3000
openapi-mode = "disabled"
log-level = "warn"
CONF_EOF
cat > /etc/marflow/Caddyfile <<'CADDY_EOF'
# ════ MARFLOW API 서버 (Caddy) ════
# · HTTPS 인증서 자동 발급 · 앱 키(apikey) 확인 · /rest/v1 → PostgREST 연결
# · DOMAIN, APP_KEY 는 /etc/marflow/env 에서 읽어요
{
	admin off
}

{$DOMAIN} {
	encode gzip

	header {
		Access-Control-Allow-Origin "*"
		Access-Control-Allow-Methods "GET, POST, PATCH, DELETE, OPTIONS"
		Access-Control-Allow-Headers "apikey, authorization, content-type, prefer, accept, range, x-client-info"
		Access-Control-Expose-Headers "content-range"
		Access-Control-Max-Age "86400"
		-Server
	}

	@preflight method OPTIONS
	handle @preflight {
		respond 204
	}

	handle /health {
		respond "ok" 200
	}

	@badkey not header apikey {$APP_KEY}
	handle @badkey {
		header Content-Type application/json
		respond `{"message":"invalid api key"}` 401
	}

	handle_path /rest/v1/* {
		request_header -Authorization
		reverse_proxy 127.0.0.1:3000
	}

	handle {
		respond 404
	}
}
CADDY_EOF
cat > /etc/marflow/caddy.env <<ENV2_EOF
DOMAIN=$DOMAIN
APP_KEY=$APP_KEY
XDG_DATA_HOME=/var/lib/caddy
XDG_CONFIG_HOME=/var/lib/caddy
ENV2_EOF
chmod 640 /etc/marflow/caddy.env; chown root:caddy /etc/marflow/caddy.env

echo "── 5/6 서비스 등록 (재부팅해도 자동 시작) ──────────────────────────────"
cat > /etc/systemd/system/postgrest.service <<'UNIT_EOF'
[Unit]
Description=PostgREST (MARFLOW)
After=network-online.target
Wants=network-online.target
[Service]
User=pgrst
EnvironmentFile=/etc/marflow/env
ExecStart=/usr/local/bin/postgrest /etc/marflow/postgrest.conf
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT_EOF
cat > /etc/systemd/system/caddy.service <<'UNIT_EOF'
[Unit]
Description=Caddy (MARFLOW HTTPS)
After=network-online.target postgrest.service
Wants=network-online.target
[Service]
User=caddy
EnvironmentFile=/etc/marflow/caddy.env
ExecStart=/usr/local/bin/caddy run --config /etc/marflow/Caddyfile --adapter caddyfile
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT_EOF
systemctl daemon-reload
systemctl enable postgrest caddy >/dev/null 2>&1
systemctl restart postgrest; sleep 2; systemctl restart caddy

echo "── 6/6 확인 ──────────────────────────────"
ok=1
for i in $(seq 1 30); do curl -fsS "https://$DOMAIN/health" >/dev/null 2>&1 && break; sleep 3; done
if curl -fsS "https://$DOMAIN/health" >/dev/null 2>&1; then echo "✓ HTTPS 연결 OK (https://$DOMAIN)"; else echo "✗ HTTPS 연결 실패 — 도메인 A 레코드가 이 서버 IP를 가리키는지, 보안 그룹 80·443이 열렸는지 확인"; ok=0; fi
R=$(curl -sS -H "apikey: $APP_KEY" "https://$DOMAIN/rest/v1/erp_docs?select=id&limit=1" || true)
case "$R" in \[*) echo "✓ 데이터베이스 연결 OK";; *) echo "✗ 데이터베이스 응답 이상: $R"; ok=0;; esac
B=$(curl -s -o /dev/null -w '%{http_code}' -H "apikey: wrong" "https://$DOMAIN/rest/v1/erp_docs?limit=1" || true)
[ "$B" = 401 ] && echo "✓ 잘못된 앱 키 차단 OK" || { echo "✗ 앱 키 확인 이상 ($B)"; ok=0; }
[ $ok = 1 ] && echo "══ 설치 완료 ══ 다음 단계: 데이터 옮기기 (sudo bash marflow-migrate.sh)" || echo "══ 위의 ✗ 항목을 확인해 주세요 (로그: journalctl -u caddy -u postgrest -n 50) ══"
