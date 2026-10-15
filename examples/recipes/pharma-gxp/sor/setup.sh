#!/usr/bin/env bash
# Stand up the self-hosted system of record this recipe is driven against: Odoo 18.0
# Community with the OCA manufacture addons (quality control on stock moves and
# manufacturing orders). Idempotent: re-running leaves an initialised database alone.
# Odoo 18.0 rather than 19.0 because on the 19.0 OCA branch only quality_control_oca
# exists; the stock and MRP quality modules this recipe reads are 18.0.
# Port 18069 on 127.0.0.1 only. Login admin / gxp-admin, database gxp.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
OCA_COMMIT="957fbe8246f3440aaa04328e4fd2619cc92bf34f"
if [ ! -d oca-manufacture/.git ]; then
  git clone --depth 1 -b 18.0 https://github.com/OCA/manufacture.git oca-manufacture
fi
# pin to the commit the recipe was tested on (a shallow clone fetches it if needed)
( cd oca-manufacture && git fetch --depth 1 origin "$OCA_COMMIT" >/dev/null 2>&1 && git checkout -q "$OCA_COMMIT" ) || true
docker compose up -d db
if ! docker compose exec -T db psql -U odoo -d postgres -tAc "select 1 from pg_database where datname='gxp'" 2>/dev/null | grep -q 1; then
  docker compose run --rm odoo odoo -d gxp \
    -i mrp,stock,quality_control_oca,quality_control_stock_oca,quality_control_mrp_oca \
    --stop-after-init --without-demo=all
  echo "env.ref('base.user_admin').password='gxp-admin'; env.cr.commit()" \
    | docker compose run --rm -T odoo odoo shell -d gxp --no-http
fi
docker compose up -d odoo
for _ in $(seq 1 60); do
  curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18069/web/login | grep -q 200 && { echo "odoo up on http://127.0.0.1:18069 (db gxp)"; exit 0; }
  sleep 2
done
echo "odoo did not come up"; exit 1
