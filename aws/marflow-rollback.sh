#!/bin/bash
# ════════════════════════════════════════════════════════════
#  MARFLOW · 되돌리기용: AWS에서 전환 뒤에 바뀐 문서를 Supabase로 다시 보내기
#  실행: sudo bash marflow-rollback.sh "2026-11-14 18:00"   (← 전환한 시각, 한국 시간)
#  · 그 시각 이후 AWS에서 고친 문서만 Supabase에 덮어써요 (그 다음 예전 ERP 파일을 다시 올리면 원래대로)
# ════════════════════════════════════════════════════════════
set -euo pipefail
SUPA_URL="${SUPA_URL_OVERRIDE:-https://unfekpuaqakyutcqaoib.supabase.co}"
SUPA_KEY="${SUPA_KEY_OVERRIDE:-sb_publishable__D15F65mxxTgsi7lDZo5-w_DgLYMXg-}"
SINCE="${1:?전환한 시각을 넣어 주세요. 예: sudo bash marflow-rollback.sh \"2026-11-14 18:00\"}"
source /etc/marflow/env
S=$(date -u -d "$SINCE +0900" +%Y-%m-%dT%H:%M:%SZ)
J=$(curl -fsS -H "apikey: $APP_KEY" "${API_BASE:-https://$DOMAIN}/rest/v1/erp_docs?select=coll,id,data,deleted,updated_by&updated_at=gt.$S&limit=100000")
n=$(echo "$J" | jq 'length'); echo "AWS에서 $SINCE 이후 바뀐 문서: ${n}건"
[ "$n" = 0 ] && exit 0
echo "$J" | jq -c '[_nwise(200)]|.[]' | while read -r b; do
  curl -fsS -o /dev/null -X POST -H "apikey: $SUPA_KEY" -H "Authorization: Bearer $SUPA_KEY" -H 'Content-Type: application/json' -H 'Prefer: resolution=merge-duplicates' "$SUPA_URL/rest/v1/erp_docs?on_conflict=coll,id" -d "$b"
  printf "."
done
echo; echo "✓ Supabase로 ${n}건 돌려보냈어요 — 이제 "되돌리기용 ERP (Supabase)" 폴더의 index.html · m.html을 Vercel에 다시 올리면 돼요"
