#!/bin/bash
# ════════════════════════════════════════════════════════════
#  MARFLOW · Supabase → AWS 데이터 옮기기 (여러 번 실행해도 안전)
#  실행: sudo bash marflow-migrate.sh
#  · Supabase에서 전부 읽어 RDS에 넣어요. 저장 시각(updated_at)은 그대로 유지
#  · 이미 옮긴 문서는 Supabase 쪽이 더 최신일 때만 덮어써요 → 전환 직후 다시 돌려도 AWS에서 새로 고친 내용은 지켜져요
# ════════════════════════════════════════════════════════════
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "sudo 로 실행해 주세요"; exit 1; }
SUPA_URL="${SUPA_URL_OVERRIDE:-https://unfekpuaqakyutcqaoib.supabase.co}"
SUPA_KEY="${SUPA_KEY_OVERRIDE:-sb_publishable__D15F65mxxTgsi7lDZo5-w_DgLYMXg-}"
source /etc/marflow/env
[ -n "${DB_ADMIN:-}" ] || { read -r -p "RDS 마스터 사용자 이름 [postgres]: " DB_ADMIN </dev/tty; DB_ADMIN=${DB_ADMIN:-postgres}; }
[ -n "${PGPASSWORD:-}" ] || { read -r -s -p "RDS 마스터 비밀번호: " PGPASSWORD </dev/tty; echo; }; export PGPASSWORD
DB="host=$DB_HOST port=${DB_PORT:-5432} user=$DB_ADMIN dbname=marflow sslmode=${DB_SSLMODE:-require}"
W=/root/marflow-migrate; mkdir -p $W; F=$W/supabase-$(date +%Y%m%d-%H%M%S).ndjson; : > $F

echo "── 1/3 Supabase에서 읽기 ──"
off=0; n=0
while :; do
  page=$(curl -fsS -H "apikey: $SUPA_KEY" -H "Authorization: Bearer $SUPA_KEY" "$SUPA_URL/rest/v1/erp_docs?select=coll,id,data,deleted,updated_at,updated_by&order=coll.asc,id.asc&limit=500&offset=$off")
  c=$(echo "$page" | jq 'length'); [ "$c" = 0 ] && break
  echo "$page" | jq -c '.[]' >> $F; n=$((n+c)); off=$((off+500)); printf "\r  %d건" $n
done
echo; echo "  → $n건 받음 ($F)"
legacy=$(grep -o '"fileRef":"[^"]*"' $F | grep -vc '"fileRef":"gd:' || true)
[ "$legacy" != 0 ] && echo "  ⚠ 예전 Supabase 저장소 파일 참조 $legacy개 — ERP 사용자 관리 화면의 [예전 저장소 파일 옮기기]를 먼저 해 주세요" || echo "  ✓ 첨부는 전부 구글 드라이브 (옮길 파일 없음)"

echo "── 2/3 AWS(RDS)에 넣기 ──"
psql "$DB" -v ON_ERROR_STOP=1 -q <<SQL
begin;
create temp table imp (line text) on commit drop;
\copy imp(line) from '$F' with (format csv, quote e'\x01', delimiter e'\x02')
alter table public.erp_docs disable trigger erp_docs_touch;
with src as (
  select (j->>'coll') coll, (j->>'id') id, (j->'data') data, coalesce((j->>'deleted')::boolean,false) deleted, (j->>'updated_at')::timestamptz updated_at, (j->>'updated_by') updated_by
  from (select line::jsonb j from imp) x
), up as (
  insert into public.erp_docs (coll, id, data, deleted, updated_at, updated_by)
  select coll, id, case when jsonb_typeof(data) = 'null' then null else data end, deleted, updated_at, updated_by from src
  on conflict (coll, id) do update set data = excluded.data, deleted = excluded.deleted, updated_at = excluded.updated_at, updated_by = excluded.updated_by
  where public.erp_docs.updated_at < excluded.updated_at
  returning 1
)
select count(*) as "새로 넣거나 갱신" from up;
alter table public.erp_docs enable trigger erp_docs_touch;
commit;
SQL

echo "── 3/3 비교 ──"
jq -r '.coll' $F | sort | uniq -c | awk '{print $2"\t"$1}' | sort > $W/src.txt
psql "$DB" -tA -F $'\t' -c "select coll, count(*) from public.erp_docs group by coll order by coll" | sort > $W/dst.txt
if diff -q $W/src.txt $W/dst.txt >/dev/null; then echo "✓ 종류별 건수가 Supabase와 똑같아요 ($(wc -l < $W/src.txt)종류 · $n건)"; else echo "종류별 건수 (Supabase / AWS):"; join -a1 -a2 -e0 -o 0,1.2,2.2 -t $'\t' $W/src.txt $W/dst.txt | awk -F'\t' '{ m=($2==$3)?"":"  ← 다름(AWS에서 새로 만든 문서면 정상)"; printf "  %-24s %6s / %6s%s\n",$1,$2,$3,m }'; fi
unset PGPASSWORD
echo "══ 완료 ══"
