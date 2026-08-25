#!/usr/bin/env python3
"""Prune commercial-plugin-dependent flow subtrees from the official CRM design.

Reads flowModels / flowModelTreePath / uiSchemas / desktopRoutes CSV dumps
(exported by run.sh from the crm_ref database), removes subtrees whose root
component belongs to a commercial plugin (mail, approval, record history), and
writes the surviving rows plus the keep-sets back as CSV for import.

Usage:
  prune_flows.py <work_dir>
    <work_dir>/flowModels.csv, flowModelTreePath.csv, uiSchemas.csv,
    uiSchemaTreePath.csv, desktopRoutes.csv  ->  *.kept.csv, keep-*.txt
"""

import csv
import re
import sys
from pathlib import Path

# Component families that only exist with commercial plugins installed.
BLACKLIST_USE = re.compile(r"^(Mail|CustomMail|Approval|ApplyTask|ProcessForm|RecordHistory)")
# Desktop menus to drop entirely (mail module).
DROP_MENUS = {"Emails"}


def load_csv(path: Path) -> list[dict]:
    with path.open() as f:
        return list(csv.DictReader(f))


def write_csv(path: Path, rows: list[dict], fieldnames: list[str]) -> None:
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def main(work_dir: Path) -> None:
    flow_models = load_csv(work_dir / "flowModels.csv")
    tree_path = load_csv(work_dir / "flowModelTreePath.csv")
    ui_schemas = load_csv(work_dir / "uiSchemas.csv")
    ui_tree_path = load_csv(work_dir / "uiSchemaTreePath.csv")
    routes = load_csv(work_dir / "desktopRoutes.csv")

    # --- 1. flowModels: drop blacklisted roots and everything below them ---
    use_by_uid: dict[str, str] = {}
    for row in flow_models:
        options = row.get("options") or ""
        match = re.search(r'"use"\s*:\s*"([^"]+)"', options)
        use_by_uid[row["uid"]] = match.group(1) if match else ""

    dropped_uids: set[str] = set()
    for row in flow_models:
        if BLACKLIST_USE.match(use_by_uid.get(row["uid"], "")):
            dropped_uids.add(row["uid"])
    for edge in tree_path:
        if edge["ancestor"] in dropped_uids:
            dropped_uids.add(edge["descendant"])

    kept_flow_models = [r for r in flow_models if r["uid"] not in dropped_uids]
    kept_flow_tree = [e for e in tree_path if e["ancestor"] not in dropped_uids and e["descendant"] not in dropped_uids]

    # --- 2. desktopRoutes: drop mail menus and their sub-trees ---
    route_ids = {r["id"] for r in routes}
    parent_by_id = {r["id"]: r["parentId"] or "" for r in routes}
    title_by_id = {r["id"]: r["title"] for r in routes}
    dropped_routes: set[str] = set()
    for rid in route_ids:
        cursor, guard = rid, 0
        while cursor and guard < 20:
            if title_by_id.get(cursor) in DROP_MENUS:
                dropped_routes.add(rid)
                break
            cursor = parent_by_id.get(cursor, "")
            guard += 1
    kept_routes = [r for r in routes if r["id"] not in dropped_routes]

    # --- 3. uiSchemas: keep those still referenced by kept routes or kept flow tree ---
    referenced: set[str] = set()
    for r in kept_routes:
        for col in ("schemaUid", "menuSchemaUid", "tabSchemaName"):
            if r.get(col):
                referenced.add(r[col])
    for e in ui_tree_path:
        if e["ancestor"] in referenced or e["ancestor"] == e["descendant"]:
            referenced.add(e["descendant"])
    kept_flow_uids = {r["uid"] for r in kept_flow_models}
    referenced |= kept_flow_uids
    kept_ui_schemas = [s for s in ui_schemas if s["x-uid"] in referenced]
    kept_ui_tree = [
        e for e in ui_tree_path if e["ancestor"] in referenced and e["descendant"] in referenced
    ]

    # --- 4. emit ---
    write_csv(work_dir / "flowModels.kept.csv", kept_flow_models, list(flow_models[0].keys()))
    write_csv(work_dir / "flowModelTreePath.kept.csv", kept_flow_tree, list(tree_path[0].keys()))
    write_csv(work_dir / "uiSchemas.kept.csv", kept_ui_schemas, list(ui_schemas[0].keys()))
    write_csv(work_dir / "uiSchemaTreePath.kept.csv", kept_ui_tree, list(ui_tree_path[0].keys()))
    write_csv(work_dir / "desktopRoutes.kept.csv", kept_routes, list(routes[0].keys()))

    kept_route_ids = {r["id"] for r in kept_routes}
    (work_dir / "keep-routes.txt").write_text("\n".join(sorted(kept_route_ids)))
    (work_dir / "keep-workflow-roles.txt").write_text("\n".join(sorted({"sales_representative", "sales_manager", "executive", "finance", "marketing", "support_manager", "technical_support_specialist", "technical", "customer", "product"})))

    print(f"flowModels: {len(flow_models)} -> {len(kept_flow_models)} (dropped {len(dropped_uids)})")
    print(f"desktopRoutes: {len(routes)} -> {len(kept_routes)} (dropped {len(dropped_routes)})")
    print(f"uiSchemas: {len(ui_schemas)} -> {len(kept_ui_schemas)}")
    print(f"uiSchemaTreePath: {len(ui_tree_path)} -> {len(kept_ui_tree)}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(Path(sys.argv[1]))
