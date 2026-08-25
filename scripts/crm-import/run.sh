#!/usr/bin/env bash
# 分阶段把 crm_ref 参考库中的官方 CRM 设计导入主库 nocobase。
# 用法: ./run.sh [s1|s2|s3|s4|s5]   （无参数=全部）
set -euo pipefail

REF="postgresql://nocobase:nocobase@localhost:5432/crm_ref"
MAIN="postgresql://nocobase:nocobase@localhost:5432/nocobase"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$SCRIPT_DIR/../../storage/backups/crm-import-work"
mkdir -p "$WORK"

CRM_ROLES="sales_representative sales_manager executive finance marketing support_manager technical_support_specialist technical customer product"
ROLES_IN="'$(echo "$CRM_ROLES" | sed "s/ /','/g")'"
# 保留的工作流：线索分配/线索转化/跟进提醒/线索评分/客户合并(2条)/AI经营分析(2条)
WF_KEYS="8nb9lii02dh l8kv19go8hd gw5cx9s9ax4 0x8w1zroaje ykqda4g2xie xiydwkxu43m 6bqwy3eq73f 4jpfeyz0yp7"
WF_IN="'$(echo "$WF_KEYS" | sed "s/ /','/g")'"

psql_ref()  { psql "$REF"  -v ON_ERROR_STOP=1 "$@"; }
psql_main() { psql "$MAIN" -v ON_ERROR_STOP=1 "$@"; }

# 单会话内完成 temp 表装载 + 反连接插入（temp 表仅存在于当前会话）。
import_csv() { # <csv> <table> <cols> <anti> <tmp>
  local csv=$1 main_table=$2 cols=$3 anti=$4 tmp=$5
  local n
  n=$(psql_main -q <<SQL
DROP TABLE IF EXISTS $tmp;
CREATE TEMP TABLE $tmp (LIKE "$main_table" INCLUDING DEFAULTS);
\copy $tmp ($cols) FROM '$csv' WITH CSV HEADER
INSERT INTO "$main_table" ($cols) SELECT $cols FROM $tmp t WHERE NOT EXISTS (SELECT 1 FROM "$main_table" m WHERE $anti);
SELECT count(*) FROM $tmp;
DROP TABLE $tmp;
SQL
)
  echo "  $main_table <- $(echo "$n" | tr -d '[:space:]' | sed 's/count//;s/(1row)//') rows"
}

# copy_filtered <ref_table> <main_table> <select_expr> <insert_cols> <where_sql> <anti_join_sql>
copy_filtered() {
  local ref_table=$1 main_table=$2 sel=$3 cols=$4 where=$5 anti=$6
  local tmp="tmp_$(echo "$main_table" | tr -dc 'a-zA-Z0-9')"
  local csv="$WORK/$tmp.csv"
  psql_ref -q -c "\copy (SELECT $sel FROM \"$ref_table\" $where) TO STDOUT WITH CSV HEADER" > "$csv"
  import_csv "$csv" "$main_table" "$cols" "$anti" "$tmp"
}

s1_collections() {
  echo "[S1] collections / fields 元数据"
  copy_filtered collections collections \
    '"key","name","title","inherit","hidden","options","description","sort"' \
    '"key","name","title","inherit","hidden","options","description","sort"' \
    "WHERE \"name\" LIKE 'nb\_%' AND \"name\" NOT IN ('nb_crm_v_mail_contact','nb_crm_mail_associations')" \
    'm."name"=t."name"'
  copy_filtered fields fields \
    '"key","name","type","interface","description","collectionName","parentKey","reverseKey","options","sort"' \
    '"key","name","type","interface","description","collectionName","parentKey","reverseKey","options","sort"' \
    "WHERE \"collectionName\" NOT IN ('nb_crm_v_mail_contact','nb_crm_mail_associations')" \
    'm."name"=t."name" AND m."collectionName"=t."collectionName"'
}

s2_business_tables() {
  echo "[S2] nb_* 物理表结构 + 演示数据"
  # 注意：树形集合需要伴生闭包表（main_<集合名>_path），一并导出
  pg_dump "$REF" --no-owner --no-privileges --no-comments \
    -t 'public.nb_*' -t 'public.main_nb_*' \
    --exclude-table='public.nb_crm_v_mail_contact' --exclude-table='public.nb_crm_mail_associations' \
    --exclude-table='public.main_mail*' \
    -f "$WORK/nb_tables.sql"
  psql_main -q -f "$WORK/nb_tables.sql"
  psql_main -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'nb\_%';" | xargs echo "  nb_* 表总数:"
}

s3_pages() {
  echo "[S3] 页面（先剪枝再导入）"
  psql_ref -q -c "\copy (SELECT \"uid\",\"name\",\"options\" FROM \"flowModels\" ORDER BY \"uid\") TO STDOUT WITH CSV HEADER" > "$WORK/flowModels.csv"
  psql_ref -q -c "\copy (SELECT \"ancestor\",\"descendant\",\"depth\",\"async\",\"type\",\"sort\" FROM \"flowModelTreePath\" ORDER BY \"ancestor\",\"descendant\") TO STDOUT WITH CSV HEADER" > "$WORK/flowModelTreePath.csv"
  psql_ref -q -c "\copy (SELECT \"x-uid\",\"name\",\"schema\" FROM \"uiSchemas\" ORDER BY \"x-uid\") TO STDOUT WITH CSV HEADER" > "$WORK/uiSchemas.csv"
  psql_ref -q -c "\copy (SELECT \"ancestor\",\"descendant\",\"depth\",\"async\",\"type\",\"sort\" FROM \"uiSchemaTreePath\" ORDER BY \"ancestor\",\"descendant\") TO STDOUT WITH CSV HEADER" > "$WORK/uiSchemaTreePath.csv"
  psql_ref -q -c "\copy (SELECT \"id\",\"createdAt\",\"updatedAt\",\"parentId\",\"title\",\"tooltip\",\"icon\",\"schemaUid\",\"menuSchemaUid\",\"tabSchemaName\",\"type\",\"options\",\"sort\",\"hideInMenu\",\"enableTabs\",\"enableHeader\",\"displayTitle\",\"hidden\",\"createdById\" FROM \"desktopRoutes\" ORDER BY \"id\") TO STDOUT WITH CSV HEADER" > "$WORK/desktopRoutes.csv"
  python3 "$SCRIPT_DIR/prune_flows.py" "$WORK"
  import_csv "$WORK/desktopRoutes.kept.csv" desktopRoutes \
    '"id","createdAt","updatedAt","parentId","title","tooltip","icon","schemaUid","menuSchemaUid","tabSchemaName","type","options","sort","hideInMenu","enableTabs","enableHeader","displayTitle","hidden","createdById"' \
    'm."id"=t."id"' tmp_desktopRoutes
  import_csv "$WORK/uiSchemas.kept.csv" uiSchemas '"x-uid","name","schema"' 'm."x-uid"=t."x-uid"' tmp_uiSchemas
  import_csv "$WORK/uiSchemaTreePath.kept.csv" uiSchemaTreePath '"ancestor","descendant","depth","async","type","sort"' \
    'm."ancestor"=t."ancestor" AND m."descendant"=t."descendant"' tmp_uiSchemaTreePath
  import_csv "$WORK/flowModels.kept.csv" flowModels '"uid","name","options"' 'm."uid"=t."uid"' tmp_flowModels
  import_csv "$WORK/flowModelTreePath.kept.csv" flowModelTreePath '"ancestor","descendant","depth","async","type","sort"' \
    'm."ancestor"=t."ancestor" AND m."descendant"=t."descendant"' tmp_flowModelTreePath
  local route_ids; route_ids=$(paste -sd, "$WORK/keep-routes.txt" | sed "s/[0-9]\+/'&'/g")
  psql_ref -q -c "\copy (SELECT \"nodePk\",\"path\",\"rootPk\" FROM \"main_desktopRoutes_path\" WHERE \"rootPk\" IN ($route_ids)) TO STDOUT WITH CSV HEADER" > "$WORK/routes_path.csv"
  import_csv "$WORK/routes_path.csv" main_desktopRoutes_path '"nodePk","path","rootPk"' 'm."nodePk"=t."nodePk"' tmp_routes_path
}

s4_roles_users() {
  echo "[S4] 角色 / ACL / 演示用户"
  copy_filtered roles roles \
    '"name","createdAt","updatedAt","title","description","strategy","default","hidden","allowConfigure","allowNewMenu","snippets","sort"' \
    '"name","createdAt","updatedAt","title","description","strategy","default","hidden","allowConfigure","allowNewMenu","snippets","sort"' \
    "WHERE \"name\" IN ($ROLES_IN)" 'm."name"=t."name"'
  copy_filtered dataSourcesRoles dataSourcesRoles '"id","roleName","strategy","dataSourceKey"' \
    '"id","roleName","strategy","dataSourceKey"' \
    "WHERE \"roleName\" IN ($ROLES_IN)" 'm."id"=t."id"'
  copy_filtered dataSourcesRolesResources dataSourcesRolesResources \
    '"id","createdAt","updatedAt","dataSourceKey","roleName","name","usingActionsConfig"' \
    '"id","createdAt","updatedAt","dataSourceKey","roleName","name","usingActionsConfig"' \
    "WHERE \"roleName\" IN ($ROLES_IN)" 'm."id"=t."id"'
  copy_filtered dataSourcesRolesResourcesActions dataSourcesRolesResourcesActions \
    '"id","createdAt","updatedAt","name","fields","scopeId","rolesResourceId"' \
    '"id","createdAt","updatedAt","name","fields","scopeId","rolesResourceId"' \
    "WHERE 1=1" 'm."id"=t."id"'
  # all/own 两个默认 scope 归一到主库已有 id，其余原样导入
  local main_all main_own ref_all ref_own
  main_all=$(psql_main -tAc "SELECT id FROM \"dataSourcesRolesResourcesScopes\" WHERE key='all' AND \"resourceName\" IS NULL LIMIT 1;")
  main_own=$(psql_main -tAc "SELECT id FROM \"dataSourcesRolesResourcesScopes\" WHERE key='own' AND \"resourceName\" IS NULL LIMIT 1;")
  ref_all=$(psql_ref -tAc "SELECT id FROM \"dataSourcesRolesResourcesScopes\" WHERE key='all' AND \"resourceName\" IS NULL LIMIT 1;")
  ref_own=$(psql_ref -tAc "SELECT id FROM \"dataSourcesRolesResourcesScopes\" WHERE key='own' AND \"resourceName\" IS NULL LIMIT 1;")
  copy_filtered dataSourcesRolesResourcesScopes dataSourcesRolesResourcesScopes \
    "CASE WHEN key='all' AND \"resourceName\" IS NULL THEN $main_all::bigint WHEN key='own' AND \"resourceName\" IS NULL THEN $main_own::bigint ELSE id END, \"createdAt\",\"updatedAt\",\"key\",\"dataSourceKey\",\"name\",\"resourceName\",\"scope\"" \
    '"id","createdAt","updatedAt","key","dataSourceKey","name","resourceName","scope"' \
    "WHERE 1=1" 'm."id"=t."id"'
  psql_main -q -c "UPDATE \"dataSourcesRolesResourcesActions\" SET \"scopeId\"=$main_all WHERE \"scopeId\"=$ref_all;
UPDATE \"dataSourcesRolesResourcesActions\" SET \"scopeId\"=$main_own WHERE \"scopeId\"=$ref_own;"
  local route_ids; route_ids=$(paste -sd, "$WORK/keep-routes.txt" | sed "s/[0-9]\+/'&'/g")
  copy_filtered rolesDesktopRoutes rolesDesktopRoutes '"createdAt","updatedAt","desktopRouteId","roleName"' \
    '"createdAt","updatedAt","desktopRouteId","roleName"' \
    "WHERE \"desktopRouteId\" IN ($route_ids)" \
    'm."roleName"=t."roleName" AND m."desktopRouteId"=t."desktopRouteId"'
  copy_filtered users users \
    '"id","createdAt","updatedAt","nickname","username","email","phone","password","passwordChangeTz","appLang","resetToken","systemSettings","sort","createdById","updatedById","mainDepartmentId"' \
    '"id","createdAt","updatedAt","nickname","username","email","phone","password","passwordChangeTz","appLang","resetToken","systemSettings","sort","createdById","updatedById","mainDepartmentId"' \
    "WHERE id <> 1" 'm."id"=t."id"'
  copy_filtered rolesUsers rolesUsers '"createdAt","updatedAt","default","roleName","userId"' \
    '"createdAt","updatedAt","default","roleName","userId"' \
    "WHERE \"roleName\" IN ($ROLES_IN)" 'm."roleName"=t."roleName" AND m."userId"=t."userId"'
  copy_filtered departments departments '"id","createdAt","updatedAt","title","isLeaf","parentId","sort","createdById","updatedById"' \
    '"id","createdAt","updatedAt","title","isLeaf","parentId","sort","createdById","updatedById"' \
    "WHERE 1=1" 'm."id"=t."id"'
  copy_filtered departmentsUsers departmentsUsers '"createdAt","updatedAt","departmentId","userId","isOwner","isMain"' \
    '"createdAt","updatedAt","departmentId","userId","isOwner","isMain"' \
    "WHERE 1=1" 'm."departmentId"=t."departmentId" AND m."userId"=t."userId"'
}

s5_workflows() {
  echo "[S5] 工作流"
  copy_filtered workflows workflows \
    '"id","createdAt","updatedAt","key","title","enabled","description","type","triggerTitle","config","executed","allExecuted","current","sync","options","createdById","updatedById"' \
    '"id","createdAt","updatedAt","key","title","enabled","description","type","triggerTitle","config","executed","allExecuted","current","sync","options","createdById","updatedById"' \
    "WHERE \"key\" IN ($WF_IN)" 'm."id"=t."id"'
  copy_filtered flow_nodes flow_nodes \
    '"id","createdAt","updatedAt","key","title","upstreamId","branchIndex","downstreamId","type","config","workflowId"' \
    '"id","createdAt","updatedAt","key","title","upstreamId","branchIndex","downstreamId","type","config","workflowId"' \
    "WHERE \"workflowId\" IN (SELECT id FROM workflows WHERE key IN ($WF_IN))" 'm."id"=t."id"'
}

s6b_flow_templates() {
  echo "[S6b] 流模板与 SQL 查询定义（图表区块依赖）"
  copy_filtered flowSql flowSql '"id","createdAt","updatedAt","uid","dataSourceKey","sql"' \
    '"id","createdAt","updatedAt","uid","dataSourceKey","sql"' "WHERE 1=1" 'm."id"=t."id"'
  copy_filtered flowModelTemplates flowModelTemplates '"createdAt","updatedAt","uid","name","description","targetUid","useModel","type","dataSourceKey","collectionName","associationName","filterByTk","sourceId"' \
    '"createdAt","updatedAt","uid","name","description","targetUid","useModel","type","dataSourceKey","collectionName","associationName","filterByTk","sourceId"' \
    "WHERE 1=1" 'm."uid"=t."uid"'
  copy_filtered flowModelTemplateUsages flowModelTemplateUsages '"createdAt","updatedAt","uid","templateUid","modelUid"' \
    '"createdAt","updatedAt","uid","templateUid","modelUid"' "WHERE 1=1" 'm."uid"=t."uid"'
}

s6_layouts() {
  echo "[S6] 路由挂载到默认 UI 布局（2.2.1 新增体系，官方备份无此表）"
  psql_main -q -c "INSERT INTO \"desktopRoutesUiLayouts\" (\"createdAt\",\"updatedAt\",\"desktopRouteId\",\"uiLayoutUid\")
SELECT now(), now(), r.id, 'admin-layout-model' FROM \"desktopRoutes\" r
WHERE NOT EXISTS (SELECT 1 FROM \"desktopRoutesUiLayouts\" j WHERE j.\"desktopRouteId\"=r.id AND j.\"uiLayoutUid\"='admin-layout-model');"
  psql_main -tAc "SELECT count(*) FROM \"desktopRoutesUiLayouts\" WHERE \"uiLayoutUid\"='admin-layout-model';" | xargs echo "  admin-layout-model 挂载路由数:"
}

s7_approval() {
  echo "[S7] 报价审批工作流（workflow-manual 开源版）"
  psql_main -q <<'SQL'
INSERT INTO workflows ("id","createdAt","updatedAt","key","title","enabled","description","type","triggerTitle","config","executed","allExecuted","current","sync","options")
VALUES (990000000000001, now(), now(), 'quotation_approval_manual', 'Quotation Approval (Manual)', true,
        '报价单状态改为 pending_approval 后进入人工审批（开源 workflow-manual 实现）', 'action', 'Record update event',
        '{"global":true,"actions":["update"],"collection":"nb_crm_quotations","appends":[]}'::json,
        0, 0, true, false, '{}'::json)
ON CONFLICT (id) DO NOTHING;

INSERT INTO flow_nodes ("id","createdAt","updatedAt","key","title","upstreamId","branchIndex","downstreamId","type","config","workflowId") VALUES
 (990000000000101, now(), now(), 'cond-pending', 'Is pending approval', NULL, NULL, 990000000000102, 'condition',
  '{"rejectOnFalse":true,"engine":"basic","calculation":{"group":{"type":"and","calculations":[{"calculator":"equal","operands":["{{$context.data.status}}","pending_approval"]}]}}}'::json,
  990000000000001),
 (990000000000102, now(), now(), 'manualApprove', 'Manager approval', 990000000000101, NULL, NULL, 'manual', '{}'::json,
  990000000000001)
ON CONFLICT (id) DO NOTHING;
SQL
  # 终版：manual 节点使用 update 型表单，提交即写回状态（filter 支持 $context 变量）
  psql_main -q -f "$SCRIPT_DIR/fix-approval.sql"
  psql_main -tAc "SELECT count(*) FROM flow_nodes WHERE \"workflowId\"=990000000000001;" | xargs echo "  审批流节点数:"
}

stage=${1:-all}
case "$stage" in
  s1) s1_collections ;;
  s2) s2_business_tables ;;
  s3) s3_pages ;;
  s4) s4_roles_users ;;
  s5) s5_workflows ;;
  s6) s6_layouts; s6b_flow_templates ;;
  s7) s7_approval ;;
  all) s1_collections; s2_business_tables; s3_pages; s4_roles_users; s5_workflows; s6_layouts; s6b_flow_templates; s7_approval ;;
  *) echo "未知阶段 $stage"; exit 1 ;;
esac
echo "完成: $stage"
