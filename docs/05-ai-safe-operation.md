# 05 · AI 安全操作

本文解释为什么 rpg-classic 的形状是「严格文档 + 多层校验 + 暂存导出」，
以及一个 Agent 具体怎么在这套约束下工作。

## 1. 前提：为什么不能交给 AI 直接写文件

`eve mcp` 宿主里的 Squirrel **写不了项目文件**：

- `installScriptFileApi`（`src/modules/filesystem/physfs/FileApi.cpp:129`）用只读 PhysFS 句柄
  替换了 stdlib 的 `file()`，没有写方法；
- `Filesystem::setupWriteDirectory()` 需要 `setIdentity()`，写目录落在引擎存档目录，
  永远不是项目根；在 MCP 宿主里它直接失败。

这不是缺陷，是**让「AI 改内容」可审计**的机会：既然脚本写不了盘，那么
**所有落盘都必须经过一个可以插入校验的窄口**。整个工具链就是围绕这个窄口建的。

窄口只有一个：

```text
RpgcValidate.commitRaw / commitDocument   →   RpgcStore.stage（暂存）
                                          →   tools/rpgc.py export（原子写盘）
```

## 2. 六层校验

| 层 | 实现 | 位置 | 抓什么 |
|----|------|------|--------|
| 0 严格 JSON 解析 | `RpgcJson.parse` | `lib/rpgc_json.nut:30-61` | UTF-8 BOM（`:37-46`）、重复键（`:154-159`）、尾随逗号（`:176-181`、`:224-229`）、注释、`NaN`/`Infinity`、裸控制字符、非法/未闭合转义、前导零、`+` 号、无数字的 `-`、指数溢出、尾随内容（`:55-59`）、深度 > 64（`:90-93`） |
| 1 Eve Schema v1 | `eve.Schema().validateJson(schemaId, text)` | `lib/rpgc_validate.nut:118-135` | **权威层**。字段类型/必填/枚举/区间/数组长度/未知字段拒绝。用的是**引擎自己的 C++ 校验器**，不是复刻品——所以工具链接受的文档就是引擎 schema 语言接受的文档，不会漂移 |
| 2 文档语义门 | `module.semanticDiagnostics(document)` | `rpgc_tilemap.nut` / `rpgc_skill.nut` / `rpgc_event.nut` | `eve.Schema` 表达不了的规则：重复 GID、GID 范围、图层 data 长度、对象重名、有无 spawn、拾取一致性、图集与地图尺寸一致、clip id 唯一、事件帧升序且在范围内、等级行升序唯一、步骤字段表、嵌套深度、duration > 0、facing 恰好一轴 |
| 3 跨引用门 | `RpgcValidate.validateReferences` | `lib/rpgc_validate.nut:206-237` | 悬空引用（`ref.dangling`）。每个模块的 `references()` 产出 `{kind, id, path}`，逐个查 `RpgcProject.pathOf` |
| 4 模块额外检查 | `module.extraDiagnostics()` | `:281-286`；`rpgc_skill.nut:257-295`、`rpgc_event.nut:257-295` | schema 与引用门都表达不了的跨文档约束：**技能/事件引用的 clip 必须在目标动画集里真实存在**（`skill.unknown-clip` / `event.unknown-clip`） |
| 5 失败关闭 | `:36-40`、`:105-108` | | `eve.Schema()` 模块不存在 → 报 `validate.no-schema-module` 并**拒绝**；`schema/` 目录为空 → `validate.no-schemas` 并拒绝。**缺一层就是失败，不是跳过** |

外加一条不属于分层的守卫，但同样重要：**文件 stem 与文档 id 必须一致**
（`RpgcValidate.idMatchesFile`，`:182-191`，`ref.id-file-mismatch`）。
它防止同一份内容出现两个 id。

编码前，值会被**重新规范化编码**再送审（`validateDocument`，`:141-154`）：
"re-encode first so the schema sees exactly the bytes that would be written"。
也就是说**被校验的字节 = 将被写出的字节**，不存在「校验一份、写另一份」。

诊断本身是机器可读的：

```json
{
  "ok": false,
  "summary": "2 error(s): [/layers/0/data] layer 'ground' has 22 cells, expected 24 (6x4)",
  "errors": 2,
  "diagnostics": [
    { "code": "map.layer-size",
      "severity": "error",
      "message": "layer 'ground' has 22 cells, expected 24 (6x4)",
      "path": "content/maps/forest.json:/layers/0/data",
      "hint": "the engine rejects a mismatched data array at load time" }
  ],
  "value": { "documents": { "map": 1, ... }, "references": { "tileset": 1 }, "backend": "deferred" }
}
```

`code` 是稳定标识符（永不变），`path` 是 JSON-Pointer 风格文档路径（带文件前缀），
`hint` 是面向人的修复建议（可能为空），`severity` 是 `error` / `warning` / `info`。
**门只看 `error`**：warning 会让 `ok` 为真，但保留在列表里供人判断。

## 3. Agent 循环

### 3.1 三个工具的分工

| 工具 | 返回 | 用途 |
|------|------|------|
| `eve_host_script {"source": "..."}` | **只有 `"ok"` 或 `"error: ..."`** | 在宿主 VM 里**执行**动作用（改 VM 状态、调 RpgcValidate、调 RpgcStore） |
| `eve_run_script {"source": "..."}` | **只有 `"ok"` 或 `"error: ..."`**（编译/运行失败会带格式化错误） | 在活 VM 上执行。调试库代码时更友好，因为错误信息完整（见 `tools/rpgc.py:270-276` 的注释） |
| `eve_eval {"expression": "..."}` | **JSON**：`{expression, name, value, type, ok}` | **读回结构化结果**。表达式求值，不执行语句 |

前两个的返回值来自 `McpServer.cpp:1463-1471`（`eve_run_script` 结尾 `return "ok";`）
与 `:1274-1276`（`eve_host_script` 直接返回 `runScript` 的结果，同样只有 ok/error）。
`eve_eval` 的 JSON 形状在 `McpServer.cpp:1288-1299`。

**因此「动作」和「读回」必须分成两次调用。** 这是 Agent 最容易踩的坑：
以为 `eve_host_script` 会把结果告诉你。

### 3.2 读回结构化结果的标准配方

`eve_eval` 返回的 `value` 是**展示形式**：字符串会被加上引号
（`Debugger.cpp:131-136`：`info.value = "\"" + s + "\""`），
数值/布尔/null 是它们的字面量，**table 和 array 只给出 `<table (n)>`**。

所以要把一份文档读回来，必须**先把规范化 JSON 存进一个全局，再用 `eve_eval` 读那个字符串**：

```text
# 1) 动作：把规范 JSON 存进全局
eve_host_script {"source": "RpgcGateGlobal <- RpgcValidate.reportJson(RpgcValidate.validateProject());"}

# 2) 读回：eve_eval 得到的是带引号的字符串
eve_eval {"expression": "RpgcGateGlobal"}
# -> {"expression":"RpgcGateGlobal","name":"RpgcGateGlobal",
#     "value":"\"{\\\"ok\\\":true,...}\"","type":"string","ok":true}

# 3) 客户端剥掉最外层引号，得到 JSON 文本，再解析
```

第 3 步就是 `tools/rpgc.py` 里的 `Engine.eval_string`：

```python
# tools/rpgc.py:255-262
def eval_string(self, expression: str) -> str:
    payload = self.eval(expression)
    value = str(payload.get("value", ""))
    if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
        value = value[1:-1]
    return value
```

以及 `eval_json`（`:263-268`）在剥引号后 `json.loads`，失败则明确报错而不是静默返回。

配套的两个便利函数已经放在宿主脚本里，避免 Agent 手拼表达式
（`mcp.nut:67-75`）：

```text
eve_eval {"expression": "RpgcGateJson()"}
# -> 等价于 RpgcValidate.reportJson(RpgcValidate.validateProject())，返回带引号的 JSON 字符串

eve_host_script {"source": "RpgcCommit(\"content/maps/forest.json\", <doc>);"}
# -> 校验 + 暂存，结果同样经 reportJson 编码
```

### 3.3 稳定的结果信封

`RpgcValidate.reportJson(result)`（`lib/rpgc_validate.nut:297-305`）是所有结果的统一信封：

```json
{ "ok": true|false,
  "summary": "<一行摘要>",
  "errors": <int>,
  "diagnostics": [ { "code", "severity", "message", "path", "hint" } ],
  "value": <结果负载> }
```

- 门结果：`value` 是 `{documents, references, backend}`（`validateProject`，`:288-292`）；
- 提交结果：`value` 是 `{path, kind, fingerprint, bytes}`（`commitRaw`，`:351-356`）。

`summary` 由 `Rpgc.summary` 生成（`lib/rpgc_core.nut:96-110`），格式是
`"N error(s), M warning(s): [<第一个错误的路径>] <消息>"`。

### 3.4 编辑器状态回读

编辑器自己的状态用另一个信封：

```text
eve_eval {"expression": "RpgcHost.reportJson()"}
# -> {"active":"tilemap","frames":1234,"lastError":"","backend":"deferred","pending":0,
#     "editors":[{"id":"tilemap","status":"forest | layer ground | paint gid 1 | cursor 3, 2 | DIRTY"}]}
```

`RpgcHost.reportJson()`（`lib/rpgc_host.nut:100-109`）。`lastError` 是 drawer 抛异常时的
`"<id>.update: <message>"` 或 `"<id>.draw: <message>"`（`:57-61`、`:70-75`）——
**单个数错误不会让其他编辑器停摆**，但也不会被吞掉。

### 3.5 完整的一次编辑会话

```text
# 0. 先看现状
eve_eval   RpgcHost.reportJson()
eve_eval   RpgcGateJson()                     # 读回并剥引号 → JSON

# 1. 发现
eve_eval   RpgcProject.idsOf("map")           # → 字符串数组的展示形式，用 RpgcJson 包一层
eve_host_script {"source":"RpgcGateGlobal <- RpgcJson.encodeCompact(RpgcProject.idsOf(\"map\"));"}
eve_eval   RpgcGateGlobal

# 2. 修改（动作 + 校验 + 暂存，一次调用）
#    RpgcCommit(path, document) = RpgcValidate.reportJson(RpgcValidate.commitDocument(...))
#    <document> 是 Agent 在 source 里构造的 Squirrel 表。
eve_host_script {"source":"RpgcGateGlobal <- RpgcCommit(\"content/maps/forest.json\", <document>);"}

# 3. 读回结果
eve_eval   RpgcGateGlobal                     # 剥引号后即 §3.3 的信封 JSON

# 4. 确认门通过后，唯一落盘路径
python tools/rpgc.py export
```

注意第 2 步的赋值：`eve_host_script` 只回 `"ok"`，所以**必须显式把结果写进一个全局**，
否则第 3 步无从读起。`RpgcCommit` / `RpgcGateJson` 本身只返回字符串，不做赋值。

或者完全走 CLI，等价且不需要 Agent 管理全局：

```bash
python tools/rpgc.py check content/maps/forest.json
python tools/rpgc.py stage content/maps/forest.json /tmp/forest.json
python tools/rpgc.py export --dry-run
python tools/rpgc.py export
```

### 3.6 四个实测出来的坑（本机实测）

前两条只在 Agent 路径上暴露；第三条是这台 VM 的语言语义，人和 AI 都会踩。

**坑一：成员名与引擎原生绑定同名，编译器会拿原生的签名去检查这次调用。**

EveScript 编译器把 `VM.名字(...)` 按**名字**解析到原生绑定表，不看接收者到底是不是那个原生类型。
一旦撞名，调用被拒绝：

```text
eve_run_script {"source": "SkillVM.setClip(null, null);"}
# -> error: memory://mcp/snippet:1 (anonymous): value is not assignable to the declared type
```

因为 `src/modules/graphics/Graphics.cpp:957` 绑定了 `Outline::setClip(float, float)`。
ImGui 按钮走 C++ 派发（`EditorHost::callTableFunc`），不受影响，所以这个坑**只在 Agent 路径上暴露**。
本仓库的原生绑定名有 6000+ 个（`addFunc("...")`），实测撞上的四个是：

| 工作流里原来的名字 | 撞到的原生绑定 | 改名为 |
|-------------------|----------------|--------|
| `SkillVM.setClip` | `Outline::setClip`（graphics） | `selectClip` |
| `TilemapVM.applyBrush` | `HeightmapTargetModule::applyBrush`（procgen） | `stampBrush` |
| `TilemapVM.addObject` | `Grid2D::addObject`（procgen） | `spawnObject` |
| `SkillVM.addLevel` | `RuntimeGeneration::addLevel`（procgen） | `appendLevel` |

`lib/rpgc_core.nut:24-27` 里 `warning` 改名成 `warn` 是同一类事故（撞 `SceneLoader::warning`）。
**新增 ViewModel 命令时，先 grep 一下 `addFunc("<名字>"`。**

**坑二：整项目校验走 `eve_eval` 要几十秒，别把它放在交互循环里。**

同一台机器上的实测（`eve mcp` 宿主）：

| 调用 | 耗时 |
|------|------|
| `eve_eval 1 + 1` | ~1.3 s |
| `eve_eval eve.Schema().validateJson("eve.rpgc.map", ...)` | ~2.0 s |
| `eve_eval RpgcValidate.validateFile("map", "...")` | ~5–6 s |
| `eve_eval RpgcValidate.reportJson(RpgcValidate.validateProject())`（12 份文档） | **~35 s** |
| `python tools/rpgc.py validate`（起宿主 + 读启动横幅） | **~10 s** |

启动门本身很快：宿主启动到打印 `[rpgc] rpg-classic PASS ...` 只要约 2 秒
（同一条 `RpgcValidate.validateProject()` 在宿主 VM 里跑，而不是在调试 VM 里）。
所以**别把 `RpgcGateJson()` 当成廉价的心跳**：一次 35 秒，任何 30 秒超时的 MCP 客户端都会先报错，
而宿主其实还在正常算。要在循环里反复拿门的结论，走 `python tools/rpgc.py validate`。

**坑三：`t.newSlot = v` 在这台 VM 上是错的，`t.newSlot <- v` 才对。**

文档是从 JSON 解出来的，可选字段**根本不存在**（例如 `presentation.segments[i].atEvent`
只在需要时出现）。这个 VM 里给不存在的槽位赋值直接抛：

```text
eve_run_script {"source": "local t = {}; t.k = 1;"}
# -> error: memory://mcp/snippet:1 (main): the index 'k' does not exist
```

`<-`（newslot）既创建又覆盖，是唯一安全的写法；键是算出来的时用 `rawset`。
实测记录：

| 写法 | 结果 |
|------|------|
| `local t = {}; t.k <- 1;` | ok，`t.k == 1` |
| `local t = {k=1}; t.k <- 2;` | ok，`t.k == 2`（覆盖） |
| `local t = {k=1}; t.k = 2;` | ok（槽位本来就在） |
| `local t = {}; t.k = 1;` | **error: the index 'k' does not exist** |
| `t.rawset(k, v)` | ok，等价于 `<-` |

这条踩中过两次，都是「编辑器面板点了没反应」级别的事故：

- `skill.vm.nut` 的 `storePresentation` 写 `segment.atEvent`：`skill.fireball` 的第 1、3 段
  没有 `atEvent`，于是 `appendLevel` / `saveSkill` 整条路径直接抛错；
- `event.vm.nut` 的 `storeStep` 写各 kind 专属字段（`reference` / `actorId` / `x` / …），
  同一原因。

同一轮实测还修掉一处不同性质的错：四个笔刷入口把 `this.applyBrush()` 写成零参调用，
而 `applyBrush` 声明为 `(editor, widget)`，Squirrel 抛
`wrong number of parameters (1 passed, 3 required)`，**四个笔刷按钮全部无法落笔**。
ViewModel 命令的参数表必须与每一个调用点一致（`editors/tilemap.vm.nut:140-167`）。

**新增 ViewModel 时，凡是往文档对象上写字段，一律用 `<-` 或 `rawset`。**

**坑四：带 UTF-8 BOM 的文件。** Windows 编辑器和 PowerShell 的
`Set-Content -Encoding utf8` 都会在文件头写 `EF BB BF`。这三个字节不是 JSON 空白，
以前的第一条诊断是 `unexpected character '\xef' at offset 0`——它指向了字节，
却没说那是什么。现在 layer 0 直接给出：

```text
[json.bom] $ document starts with a UTF-8 byte-order mark
           hint: save the file as UTF-8 without BOM; the first byte must be '{' or '['
```

**拒绝仍然是对的**（引擎不替调用方猜编码），改的只是诊断：agent 和人都能一眼看懂。

### 3.7 怎么重验这一整节

上面每一条结论——启动门、三套编辑器与 ViewModel 注册、每个 drawer 的 `status()`、
**View JSON 里声明的每一条 `command` 是否能从 `eve_run_script` 调用**、store 后端、
校验门接受好文档 / 拒绝未知字段且不暂存、`stage → takePendingJson → export` 往返——
都由一条命令实测：

```bash
python tools/rpgc.py selftest      # 8 项检查；失败退出码非 0
```

命令清单直接从 `editors/*.editor.json` 的 `command` 字段推导，所以按钮改名时
检查集自动跟着变，不会出现「文档说 59 条、实际 40 条」这种脱节。

## 4. 运维拿到的具体安全性质

| 性质 | 由什么保证 |
|------|-----------|
| **没有未校验的字节能到磁盘** | `commitRaw` 只有在 layer 0+1+2 全无 error 时才 `stage`（`lib/rpgc_validate.nut:337-350`）；`export` 只写暂存区里的东西（`tools/rpgc.py:429-461`）；Squirrel 侧根本没有直接写项目文件的 API |
| **校验的字节 = 写出的字节** | `validateDocument` 先 `RpgcJson.encode(document)` 再送 schema（`:141-143`）；`commitRaw` 就是这个文本 |
| **不覆盖别人的改动** | `RpgcStore.checkRevision`（`lib/rpgc_store.nut:238-250`）在写前比对 FNV-1a 指纹，不一致返回 `store.stale-revision`，hint 是 "reload the document before saving" |
| **id 出不了项目根** | `Rpgc.validId`（`lib/rpgc_core.nut:215-226`）：只允许 ASCII 字母数字加 `._-`，1..64 字节——**没有 `/`、`\`、`:`**，所以 id 不能拼出路径 |
| **路径出不了项目根** | `Rpgc.validRelPath`（`:231-242`）：拒绝绝对路径、`\`、`:`、空段、`.`、`..`，长度 1..240。`RpgcStore.readText` / `stage` / `save` 都先过它 |
| **文档大小有界** | `Rpgc.limits`（`:313-323`）：地图 512×512、图层 ≤16、对象 ≤2048、技能 ≤512、事件 ≤256、步骤 ≤512、轨道 ≤32、等级行 ≤64；JSON 深度 ≤64（`rpgc_json.nut:26`）；公式 ≤160 字符（`rpgc_skill.nut:199`）。这些是**防挂死**上限，不是玩法预算 |
| **拒绝是机器可读的** | 每条诊断都有稳定 `code` 与 JSON-Pointer 风格 `path`；严重度分 error/warning/info。Agent 可以按 `code` 分类、按 `path` 定位，不需要解析自然语言 |
| **缺失的检查是失败不是跳过** | layer 5，见 §2 |
| **暂存 ≠ 落盘** | `deferred` 后端下 `save()` 返回 `store.deferred` warning 且 `persisted = false`（`lib/rpgc_store.nut:206-212`）。调用方**不可能**把暂存误认为已保存 |

## 5. 一次「AI 改错了」的完整追踪

**目标**：给 6×4 的森林地图加一列地板。

**动作**：Agent 想加一列地板，于是手工编辑 `layers[0].data`，
但漏掉了一个元素（实际 23 个，期望 24 个），并且顺手把其中一个格子的 GID 写成 `9`
（图集只到 3）。`height` 没有改。

```text
eve_host_script {"source":"RpgcCommit(\"content/maps/forest.json\", d);"}
eve_eval        RpgcGateGlobal
```

**诊断**（剥引号后的 JSON）：

```json
{
  "ok": false,
  "summary": "1 error(s): [content/maps/forest.json:/layers/0/data] layer 'ground' has 23 cells, expected 24 (6x4)",
  "errors": 1,
  "diagnostics": [
    { "code": "map.layer-size",
      "severity": "error",
      "message": "layer 'ground' has 23 cells, expected 24 (6x4)",
      "path": "content/maps/forest.json:/layers/0/data",
      "hint": "the engine rejects a mismatched data array at load time" }
  ],
  "value": { "documents": { "map": 1 }, "references": { "tileset": 1 }, "backend": "deferred" }
}
```

**Agent 从诊断能推断出什么**：

1. `code = map.layer-size` → 这是长度问题，不是类型问题；
2. `path = .../layers/0/data` → 精确到 `data` 数组本身，不是某个元素；
3. `message` 里同时给了「实际 23」和「期望 24（6x4）」→ 矩阵形状是对的，是元素少了一个；
4. **只有一条 error** → GID 越界那一处**没有被报告**。

第 4 点是关键：**语义门在 `data.len() != expectedCount` 时 `continue`**
（`lib/rpgc_tilemap.nut:203-209`），根本不会去扫 GID。所以这次修复之后会冒出**第二条**
error：

```json
{ "code": "map.gid-out-of-range",
  "severity": "error",
  "message": "layer 'ground' uses 1 GID(s) outside the atlas range 1..3 (9)",
  "path": "content/maps/forest.json:/layers/0/data",
  "hint": "the engine only verifies the cell count and would render a debug colour" }
```

这不是缺陷，是**逐层收敛**：长度错了就修长度，修完再看内容。
Agent 应该循环「读诊断 → 修 → 重校验」，而不是一次修完所有能猜的问题。

**修复**：把 `data` 补齐到 24 个元素，并把那个越界 GID 改成 `1`。

```text
eve_host_script {"source":"RpgcCommit(\"content/maps/forest.json\", d);"}
eve_eval        RpgcGateGlobal
# -> {"ok":true,"summary":"ok","errors":0,"diagnostics":[],
#     "value":{"path":"content/maps/forest.json","kind":"map",
#              "fingerprint":"3f2a91c4","bytes":1104}}
```

`fingerprint` 是规范编码文本的 FNV-1a 32 位散列（`lib/rpgc_json.nut:714-716`），
可以拿来做「我记下的版本和你现在写的是不是同一份」的比对。

**落盘**：

```text
python tools/rpgc.py export
# wrote content/maps/forest.json (1104 bytes, 3f2a91c4)
# 1 document(s) exported
```

**一个反例**：如果 Agent 跳过校验，直接想让 Squirrel 写盘——

```text
eve_host_script {"source":"local f = file(\"content/maps/forest.json\", \"w\");"}
```

在 MCP 宿主里 `file()` 是只读 PhysFS 句柄（§1），这一步不可能成功。
这正是设计目标：**越权在物理上不可行，而不只是被禁止**。

## 6. 给 Agent 的清单

1. **先读门，再动手。** 一次 `RpgcGateJson()` 建立基线。
2. **动作和读回分开。** `eve_host_script` / `eve_run_script` 只回 `ok`；用
   `eve_eval` 读全局字符串并剥引号。
3. **只改内容，不改规则。** 不要为了让自己通过而改 `schema/` 或 `lib/`——
   那会让工具链与引擎脱离；改库是人的决定，改完保存 `mcp.nut` 让宿主重载依赖闭包。
4. **一次只修一类问题。** 看到第一条 error 就修它，重跑门。
   门的层是短路推进的，一次性的「全量修复」通常修不干净。
5. **暂存不等于保存。** 结束时确认 `export` 真的跑了，并且 `RpgcStore.pendingCount()`
   回到 0，或者明确说明还有什么留在暂存区。
6. **不要绕过 `RpgcStore`。** 没有任何其他合法写路径；
   `tools/rpgc.py export` 是唯一的原子项目写入者。
7. **改库之前先导出。** `lib/` 里任一模块改动后保存 `mcp.nut`，宿主会重载
   `mcp.nut` 的整条 `import` 依赖闭包，这会清空暂存、指纹与索引。
   （没有 `RpgcWorkflow.reload()` 了：模块只实例化一次，需要重载哪些模块由
   `import` 依赖图决定，不再由手工维护的文件名列表决定。）
