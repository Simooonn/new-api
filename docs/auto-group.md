# 自动分组链（auto group）配置指南

令牌分组填 `auto` 时，系统会按预设的分组顺序**从前往后**查找，命中第一个「有该模型可用渠道」的分组。适合把多个逆向/低价分组串成降级链，用一个令牌覆盖所有模型。

**注意区分：**

| | 普通分组 | 自动分组（auto） |
|---|---|---|
| 令牌分组填什么 | 具体分组名，如 `default` | `auto` |
| 走哪个分组 | 固定 | 按 `AutoGroups` 顺序动态选 |
| 按什么计费 | 该分组的倍率 | **实际命中分组**的倍率 |
| 是否需要配倍率 | 需要 | 不需要，`auto` 不是真实计费分组 |

配置入口：系统管理 → 计费与支付 → 分组定价。

## 一、四项配置的关系

| 字段 | 界面标题 | 作用 |
|---|---|---|
| `GroupRatio` | 分组比例 | 各**真实分组**的计费倍率 |
| `UserUsableGroups` | 可选分组 | 用户建令牌时下拉里能选到的分组 |
| `AutoGroups` | 自动分配顺序 | `auto` 令牌的尝试顺序 |
| `DefaultUseAutoGroup` | 默认使用自动分组 | 新建令牌是否默认填 `auto` |

三份 JSON 必须互相对齐，缺一处链就不完整。

## 二、配置步骤

### 1. 定义真实分组倍率

```json
{
  "cheap-a": 0.1,
  "cheap-b": 0.2,
  "default": 0.2,
  "official": 1
}
```

**不要**把 `auto` 写进这里。它不是真实计费分组，`middleware/auth.go` 的令牌校验对它有专门豁免。写进去会让 `/api/group/` 多返回一项，污染**用户管理页的「用户分组」下拉**——那里选的是 user group，与令牌分组是两个概念。

### 2. 开放可选分组（含 `auto`）

```json
{
  "auto": "自动分组",
  "cheap-a": "低价 A",
  "cheap-b": "低价 B",
  "default": "默认组合",
  "official": "官方"
}
```

**`auto` 必须显式写在这里**，否则用户建令牌时下拉框里搜不到它。系统默认值（`setting/user_usable_group.go`）只有 `default` 和 `vip`，不含 `auto`。

后端返回可选分组时，`auto` 走的是一个独立分支（`controller/group.go`），只检查它在不在 `UserUsableGroups` 里，与 `GroupRatio` 无关：

```go
if _, ok := userUsableGroups["auto"]; ok {
    usableGroups["auto"] = map[string]interface{}{
        "ratio": "自动",
        "desc":  setting.GetUsableGroupDescription("auto"),
    }
}
```

### 3. 定义链顺序

```json
["cheap-a", "cheap-b", "default", "official"]
```

必须是 **JSON 字符串数组**，逗号分隔的纯文本（`cheap-a,cheap-b`）会被前端校验拒绝。

链上每个分组还必须出现在 `UserUsableGroups` 里，否则会被交集过滤掉（`service/group.go`）：

```go
func GetUserAutoGroup(userGroup string) []string {
    groups := GetUserUsableGroups(userGroup)
    autoGroups := make([]string, 0)
    for _, group := range setting.GetAutoGroups() {
        if _, ok := groups[group]; ok {
            autoGroups = append(autoGroups, group)
        }
    }
    return autoGroups
}
```

全局顺序保持不变，但只保留当前用户可用的分组。这意味着**同一条链对不同用户可能长度不同**。

### 4. 建令牌

- 分组选 `auto`
- 需要「渠道报错后换组」→ 勾选**跨分组重试**（见下节）

## 三、选组与切组规则

### 切组条件是「没有渠道」，不是「渠道报错」

这是最容易误解的一点。核心逻辑在 `service/channel_select.go`：

```go
channel, _ = model.GetRandomSatisfiedChannel(autoGroup, param.ModelName, priorityRetry, param.RequestPath)
if channel == nil {
    // 当前分组没有该模型的可用渠道，尝试下一个分组
    common.SetContextKey(param.Ctx, constant.ContextKeyAutoGroupIndex, i+1)
    continue
}
```

只有 `channel == nil`（该分组压根没绑这个模型）才会往下走。如果分组里有渠道但上游返回 500/超时，**默认不会自动降级到下一组**。

想让报错也触发换组，必须在令牌上开启**跨分组重试**（`cross_group_retry`）。开启后，当前分组内先按渠道优先级重试，重试次数用尽（`priorityRetry >= common.RetryTimes`）才切到下一分组。

### 选组不看余额

`GetRandomSatisfiedChannel` 只筛「分组 + 模型 + 请求路径」匹配且启用的渠道，按优先级降序、权重随机。用户余额在选组之后的预扣费阶段单独校验。

### 顺序不看倍率

链是纯粹的顺序遍历，**不会自动挑便宜的**。如果两个分组绑了同一个模型，排在前面的先命中，哪怕它更贵。

因此链的排序原则是：**便宜 → 贵 → 官方兜底**。配置后建议核对各分组的模型绑定有无重叠。

### 计费按实际命中的分组

`relay/helper/price.go` 的 `HandleGroupRatio` 会用 context 里的 `auto_group` 覆盖 `UsingGroup`，再取倍率。所以日志里记录的是真实分组，不是字面的 `auto`。

## 四、常见问题

**令牌下拉里搜不到 `auto`**
`UserUsableGroups` 里没写 `auto`。补上后需刷新页面，分组列表是接口拉取的。

**报错 `auto groups is not enabled`**
`AutoGroups` 是空数组。

**链配好了但只命中最后一个分组**
前面的分组不在 `UserUsableGroups` 里，被交集过滤掉了。

**一直命中同一个分组，上游明明已经报错**
令牌没开跨分组重试。

**下拉里的分组顺序很奇怪**
前端不排序，直接用接口返回的顺序（`Object.entries`）。后端返回的是 Go `map`，`encoding/json` 序列化时按 key 的**字节序**排列——大写字母开头的在前，小写次之，中文名永远最后。**这个顺序与链的优先级无关。**

**「分组间覆盖」里的 `{"vip": {"edit_this": 0.9}}` 是什么**
出厂占位模板（`setting/ratio_setting/group_ratio.go` 的 `defaultGroupGroupRatio`），`edit_this` 不是真实分组。不用可清成 `{}`——写入是全量替换（`types/rw_map.go`），空对象能真正清空，之后计费回落到 `GroupRatio` 的基础倍率。

## 相关代码

| 主题 | 位置 |
|---|---|
| 链的存储与读取 | `setting/auto_group.go` |
| 按用户过滤链 | `service/group.go` |
| 选组核心逻辑 | `service/channel_select.go` |
| 可选分组接口 | `controller/group.go` |
| 令牌分组校验 | `middleware/auth.go` |
| 倍率与计费 | `relay/helper/price.go`、`setting/ratio_setting/group_ratio.go` |
| 前端配置表单 | `web/src/features/system-settings/models/group-ratio-form.tsx` |
| 前端令牌抽屉 | `web/src/features/keys/components/api-keys-mutate-drawer.tsx` |
