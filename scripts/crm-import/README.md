# CRM 导入脚本（官方设计 → 开源实例）

把 `crm_ref` 参考库（官方 CRM 2.0 备份还原出的 PostgreSQL 库）中的设计资产，
手术式导入到本地源码安装的 NocoBase 2.2.1 开源实例主库 `nocobase`。

## 原理

官方 `.nbdata` 备份本质是全库 pg_dump。本脚本做同样的事，但：
- 只挑 CRM 业务资产（nb_crm_* / nb_cbo_* 集合、页面流、角色权限、工作流、演示数据）
- 剥离商业插件依赖（邮件 email-manager、审批 workflow-approval、AI 知识库、记录历史）
- 不碰主库的 applicationPlugins / systemSettings / migrations

所有关键键（uiSchemas.x-uid、flowModels.uid、desktopRoutes.id）在主库为空或互不冲突，
因此原样搬运，无需 id 映射。

## 用法

```bash
# 前置：参考库 crm_ref 已存在（见 docs/superpowers/specs/2026-08-25-crm-rebuild-design.md）
cd scripts/crm-import
./run.sh            # 依次执行 S1..S5
./run.sh s3         # 只跑某阶段
./verify.sh         # 导入后核对行数
```

执行完需重启 dev 服务（`yarn dev`）使应用重新加载集合与页面缓存。

## 阶段

| 阶段 | 内容 |
|------|------|
| S1 | collections/fields 元数据（nb_* 业务集合 + 系统集合新增字段） |
| S2 | nb_* 物理表结构 + 演示数据（pg_dump 管道） |
| S3 | 页面：desktopRoutes + uiSchemas + flowModels + treePath（含商业组件剪枝） |
| S4 | 角色/ACL/演示用户/部门 |
| S5 | 工作流 + 节点（剔除审批、演示日期漂移） |
| S6 | 路由挂载到默认 UI 布局（2.2.1 新增的 uiLayouts 体系，官方 2.1 备份无此表） |
| S6b | flowSql / flowModelTemplates / flowModelTemplateUsages（图表区块的数据源与模板） |
| S7 | 报价审批工作流（开源 workflow-manual 实现，替代商业 workflow-approval） |

剪枝规则见 `prune_flows.py`：Mail*/CustomMail*/Approval*/ApplyTask*/ProcessForm*/RecordHistory*
组件子树整支剔除，Emails 菜单剔除。

## 报价审批（S7）设计说明

- 触发：action 触发器，全局监听 `nb_crm_quotations` 的 update；
  condition 节点限定 `status == pending_approval` 才继续。
- 审批：manual 节点，审批人为销售经理（演示数据用户 1/5/11/12/13），
  两个 **update 型表单**（approve/reject）——这是关键：update 型表单的
  `filter` 会经 `getParsedValue` 解析（支持 `$context` 变量），action 的
  `values` 会合并进提交值直接写回目标记录，因此不需要下游 update 节点。
  注意：`$jobsMapByNodeKey` 变量在 resume 阶段的 update 节点中解析不到值，
  不要用它传审批结果。
- 验证：提交报价单（status→pending_approval）→ `workflowManualTasks:listMine`
  出现待办 → `workflowManualTasks:submit` 提交 `{result:{approve:{},_:"resolve"}}`
  → 报价单状态自动变为 approved / rejected。

## 工具

- `ui-acceptance.mjs`：Playwright 无头浏览器冒烟验收（登录→各业务页输出菜单/表头/行数/错误）。
  用法：`PW_CHROMIUM=<chromium路径> node scripts/crm-import/ui-acceptance.mjs [菜单名...]`

## 回滚

主库导入前快照：`storage/backups/pre-crm-restore-*.dump`。
回滚：drop 主库 → 从快照 pg_restore → `yarn nocobase upgrade`（如需要）。
