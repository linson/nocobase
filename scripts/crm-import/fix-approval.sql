-- 报价审批终版：manual 节点使用 update 型表单，提交即写回报价单状态
UPDATE flow_nodes SET "downstreamId" = NULL,
  config = '{
    "assignees": [1, 5, 11, 12, 13],
    "forms": {
      "approve": {
        "type": "update",
        "dataSource": "main",
        "collection": "nb_crm_quotations",
        "filter": {"id": "{{$context.data.id}}"},
        "actions": [{"status": 1, "key": "resolve", "values": {"status": "approved"}}]
      },
      "reject": {
        "type": "update",
        "dataSource": "main",
        "collection": "nb_crm_quotations",
        "filter": {"id": "{{$context.data.id}}"},
        "actions": [{"status": 1, "key": "resolve", "values": {"status": "rejected"}}]
      }
    }
  }'::json
WHERE id = 990000000000102;

DELETE FROM flow_nodes WHERE id = 990000000000103;
