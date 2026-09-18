# 03 · 事件编辑器（event）

对应 `lib/rpgc_event.nut`、`schema/eve.rpgc.event.json`。

> 落地状态：人用入口是 `eve run apps/event`。Agent 入口 `eve mcp` 会一并恢复该编辑器（`eve_host_status.viewModels` 里能看到 `EventVM`）。也可以直接写 JSON，用 `python tools/rpgc.py validate` 校验。

## 1. 引擎已有的那一份：`eve.rpg.story-events` v1

引擎**已经有**一个严格、版本化、可恢复的演出指令文档：
`StoryEventCatalogue::replaceFromJsonStrict`（`src/modules/rpg/StoryEvent.cpp:64-170`）。
先把它讲清楚，才能说明本工作流的 `eve.rpgc.event` 补的是哪一块。

### 1.1 结构

```json
{
  "schema": "eve.rpg.story-events",
  "version": 1,
  "events": [
    { "id": "forest.arrive", "repeatable": false,
      "steps": [ { "kind": "wait", "reference": "", "actorId": "", "x": 0, "y": 0, "duration": 1.5 } ] }
  ]
}
```

根字段只有 `schema` / `version` / `events`（`StoryEvent.cpp:74-78`），
事件字段只有 `id` / `repeatable` / `steps`（`:91`），
**步骤字段只有 `kind` / `reference` / `actorId` / `x` / `y` / `duration`**（`:92`）。
任何多余键直接报 `story-event document contains an unknown field`（`:76-78`、`:100-102`、`:127-129`）。

### 1.2 封闭的步骤集合

`parseKind`（`:33-47`）只认五种种：

| kind | 字段↔kind 的强耦合 |
|------|--------------------|
| `dialogue` | `reference` **必须非空**（`:146-152`） |
| `message` | `reference` **必须非空** |
| `move` | `actorId` **必须非空**（`:148-155`），`x`/`y` 是目标 |
| `wait` | `duration` **必须 > 0**（`:149`、`:156-158`） |
| `camera` | 只要求 `x`/`y`/`duration` 是有限数且 `duration >= 0`（`:140-145`） |

耦合是**双向**的：`reference` 在非 dialogue/message 步上出现也是错误
（`needsReference != !reference.empty()`）。这就是这份文档的核心设计——字段不是可选的，
而是由 kind 决定的存在性契约。

### 1.3 游标与完成事实

事件状态存在 `GameState` 的 **self-variable** 里，scope 是 `"story.event:" + eventId`
（`eventScope`，`:60`）：

- `cursor`：当前步骤下标；
- `completed`：0 / 1。

`StoryEventSession::begin`（`:180-215`）会校验持久化状态：
`completed` 必须是 0 或 1（`:190-192`），`cursor` 必须是非负整数且 `< steps.size()`（`:200-203`）。
非 repeatable 且已完成的事件再次 begin 返回 `Conflict`（`:194-196`）。

### 1.4 `camera` 被解析但没人应用

`parseKind` 接受 `camera`，字段校验也覆盖它，但**示例运行时没有消费它**：
`examples/rpg-classic` 的剧情事件只处理 dialogue / message / wait / move。
引擎提供的只是会话层（`current()` 返回当前步骤，`getStepKind/getX/getY/getDuration`，
`:246-279`），**应用**这一步是调用方的事。所以「camera 步骤」在今天的示例里是一条死信。

这条观察是本工作流设计 `camera_focus` / `camera_pan` 的直接理由：
把它挪到有明确执行者的文档里。

### 1.5 它没有的

- 没有加载地图步骤（地图切换在示例里是 portal 对象驱动的）；
- 没有动画步骤；
- 没有并行组；
- 没有分支；
- 没有变量/开关步骤；
- 步骤数上限 128（`:114`）。

## 2. `eve.rpgc.event`：补上这些缺口

结构见 `schema/eve.rpgc.event.json`：

```json
{
  "schema": "eve.rpgc.event",
  "version": 1,
  "id": "forest.arrive",
  "title": "抵达雾林",
  "repeatable": false,
  "trigger": { "kind": "map_entered", "mapId": "forest" },
  "steps": [ /* 有序步骤 */ ]
}
```

`trigger.kind` 的封闭集合：`manual` / `portal_entered` / `map_entered` /
`object_interacted` / `quest_completed` / `game_started`。语义门按 kind 要求对应字段
（`lib/rpgc_event.nut:51-71`）：

| trigger.kind | 必需字段 | code |
|--------------|----------|------|
| `portal_entered` / `map_entered` | `mapId` | `event.trigger-map` |
| `object_interacted` | `objectName` | `event.trigger-object` |
| `quest_completed` | `questId` | `event.trigger-quest` |
| `manual` / `game_started` | —— | —— |

`targetMap` 是 `portal_entered` 的目标地图，会被引用门当 `map` 引用解析
（`lib/rpgc_event.nut:218-221`）。

## 3. 步骤种类总表

`RpgcEvent.requiredFields`（`lib/rpgc_event.nut:29-43`）是权威的必填字段表；
schema 的 `kind` enum（`schema/eve.rpgc.event.json:21-25`）是封闭词表。
下表把每一步分类为 **引擎已有 API** 或 **项目钩子**。

| kind | 类别 | 必填字段 | 底层 API |
|------|------|----------|----------|
| `load_map` | engine-real | `mapId`, `x`, `y` | `map.loadFromFileWithObjectContract(path, contractJson)`（`src/modules/map/Map.h:75`，绑定 `Map.cpp:570-581`），失败保留当前地图 |
| `wait` | engine-real | `duration` (>0) | 任何 `dt` 累加；也可以是 `eve.Timer`/协程 |
| `camera_focus` | engine-real | `x`, `y` | `eve.Camera2D()`（`src/modules/graphics/RenderSystem.h:18`）的 `setPosition(x,y)`（`RenderSystem.cpp:104`，绑定 `Graphics.cpp:365`）、`setZoom`（`:368`），再由 `layer.setCamera(cam)`（`TileLayer.h:306`）挂到图层 |
| `dialogue` | engine-real | `reference` | `DialogueFlow::startChecked(id, bindings)` / `advanceChecked()` / `select(routeId)`（`src/modules/dialogue/DialogueFlow.cpp:888-905`） |
| `message` | engine-real | `reference` | 本地化 key + `ui.setText`；`reference` 是稳定 l10n key |
| `set_variable` | engine-real | `name`, `op`, `value` | `GameState::setVariable(name, v)` / `addVariable(name, delta)` / `switchOn(name)` / `switchOff(name)`（绑定 `src/modules/rpg/RPG.cpp:891-897`，实现 `GameState.cpp:40-58`）。有 scope 时用 `setSelfVariable(scope, name, v)`（`GameState.cpp:60`） |
| `consume_object` | engine-real | `mapId`, `objectName` | `RPGWorldState.consumeObject(mapId, objectId)`（绑定 `RPG.cpp:915-923`，实现 `WorldState.cpp:37-52`）。它把 `world.object:<mapId>` scope 下的 `<objectId>` 置 1，`isObjectConsumed` 读回 |
| `move_actor` | project-hook | `actorId`, `x`, `y` | **NPC 移动没有引擎 API**。玩家/队伍移动是项目代码；此步只是给项目调度器的指令 |
| `face_actor` | project-hook | `actorId`, `facingX`, `facingY` | 同上。项目维护朝向；门强制「恰好一个非零分量」（`lib/rpgc_event.nut:108-121`） |
| `play_animation` | project-hook | `anim`, `clip` | 用 `SpriteAnim`（`eve.Animation().newSpriteAnim()`）播放。**引擎里没有「事件步→动画」的绑定**，项目自己驱动，见 [`02-skill-editor.md`](02-skill-editor.md) §6 |
| `camera_pan` | project-hook | `x`, `y`, `duration` (>0) | `Camera2D::setPosition` 是瞬时设置，没有补间；项目在 `duration` 内插值 |
| `parallel` | project-hook | `steps` (≥1) | 项目调度器并发跑子步骤 |
| `branch` | project-hook | `condition`, `then` | 项目调度器求值条件后选分支 |

「engine-real」的意思是**引擎里有这个 API**，不是「引擎里有这个步骤」。整个
`eve.rpgc.event` 的**解释器是项目的**（见 §5）。

### 3.1 条件

`branch` 的 `condition` 是封闭的五选一。**条件词表只有一份**：
`schema/eve.rpgc.condition.json` 是它和 `eve.rpgc.world` 的门条件共同 `ref` 的 schema，
语义门也只有一处（`lib/rpgc_systems.nut` 的 `conditionDiagnostics`，
`lib/rpgc_event.nut` 只是转调）——两处各写一份枚举正是两套语法开始漂移的方式。

| kind | 必需字段 | 对应的引擎事实 |
|------|----------|---------------|
| `variable` | `name`, `compare`(`eq`/`ne`/`lt`/`lte`/`gt`/`gte`), `value` | `GameState::getVariable(name)` |
| `switch` | `name` | `GameState::isSwitchOn(name)` |
| `object_consumed` | `mapId`, `objectName` | `RPGWorldState.isObjectConsumed(mapId, objectId)` |
| `moment` | `any[]`（时刻 id 列表） | `DayNight::getTimeOfDay/isNight` + `eve.rpgc.world.clock.moments` |
| `always` | —— | 恒真 |

`moment` 是本工作流加在引擎面向集合之上的唯一一种。它把「现在是哪个时刻」交给
`world.clock.moments` 求值，所以 `any[]` 里的每个 id 都必须在该文档里存在，
否则条件永远为假、分支永远走不到——门报 `systems.condition-unknown-moment`，
而不是让它在运行期静默失灵（`docs/06-game-design.md` §1.5）。

`object_consumed` 的 `mapId` 会被引用门当 `map` 引用（`lib/rpgc_event.nut`）。

### 3.2 嵌套与深度

- `branch` 有 `then` 与 `else`，`then` 至少一个步骤（`event.empty-branch`）；
- `parallel` 至少两个步骤，否则给 `event.trivial-parallel` warning
  （「少于两步的 parallel 就是一个序列」，`lib/rpgc_event.nut:151-157`）；
- 嵌套深度上限 **2**（`maxDepth`，`:25`）。`stepDiagnostics` 在
  `depth >= maxDepth` 时对 `branch` / `parallel` 报 `event.depth`（`:139-143`、`:158-162`）。
  顶层步骤深度是 1，所以 v1 只允许**一层** branch/parallel 嵌套；
- `wait` 与 `camera_pan` 的 `duration` 必须 > 0（`event.bad-duration`，`:101-107`），
  hint 说明「引擎自己的 wait 步也拒绝零时长」。

### 3.3 未知 kind

`schema` 的 enum 先拦一层；即便绕过（例如程序侧构造文档），
`requiredFields.rawin(kind)` 也会给 `event.unknown-step`（`:86-91`），
hint 指向本文的封闭集合。**没有「未知步骤静默跳过」这条路。**

## 4. 引用与额外层

`RpgcEvent.references`（`lib/rpgc_event.nut:214-252`）递归走 `then` / `else` / `steps`，产出：

- trigger 的 `mapId` / `targetMap` → `map`；
- `load_map.mapId`、`consume_object.mapId` → `map`；
- `play_animation.anim` → `anim`；
- `object_consumed` 条件的 `mapId` → `map`。

`RpgcEvent.extraDiagnostics`（`:257-295`）再检查 `play_animation` 的 `clip`
确实存在于它引用的动画集里（`event.unknown-clip`）。

## 5. 解释器形状

`eve.rpgc.event` 的**文档**由工作流定义并校验，**执行**由项目运行时的适配器负责。
按 `Rpgc*` 库的一贯风格，解释器应是一个与文档解耦的纯投影：

```text
content/events/<id>.json
        │ RpgcStore.readDocument + RpgcValidate.validateFile（加载前必过门）
        ▼
RpgcEvent 解释器（项目侧）
        │ 每一步按 kind 调一个引擎 API 或一个项目钩子
        ▼
引擎事实：Map / Camera2D / DialogueFlow / GameState / RPGWorldState / SpriteAnim
```

建议的状态形状：

```squirrel
eventSession <- {
    steps   = [],      // RpgcEvent 校验过的步骤列表
    cursor  = 0,
    pending = [],      // parallel 的子游标；顺序执行时为空
    active  = false
};
```

### 5.1 游标必须由解释器持久化 —— 一个必须避开的坑

引擎的 `StoryEventSession::advance` 是**比较并设置**的：

```cpp
// src/modules/rpg/StoryEvent.cpp:224-233
const double persistedCursor = gameState->getSelfVariable(scope, "cursor");
if (!std::isfinite(persistedCursor) || persistedCursor != static_cast<double>(cursor_)
    || persistedCompleted != 0.0)
    return storyFailure<int>(Conflict, "story-event cursor changed since this step was presented", ...);
const int next = cursor_ + 1;
gameState->setSelfVariable(scope, "cursor", next);
```

也就是说：**每个被呈现的步骤只能确认一次。** 这条约束直接决定了
`eve.rpgc.event` 的 `parallel` 实现方式：

> **并行子步骤不得各自确认游标。** 如果 `parallel` 的每个子步骤都去
> `advance()` 一次，第二次就会命中 `persistedCursor != cursor_` 的 Conflict。
> 正确做法是：父步骤拥有游标，所有子步骤完成后由父步骤推进一次
> （或者由一个显式的聚合步骤推进）。

即使项目没有直接使用 `RPGStoryEventSession`，只要它复用了同一套
`GameState` self-variable 约定，这条约束同样成立。因此 `RpgcEvent` 把
`parallel` 当作**一个**步骤计数，而不是 N 个。

### 5.2 校验发生在加载，不在执行

运行时应该在 `begin` 之前做一次 `RpgcValidate.validateFile("event", path)`：
`schema` + 语义门 + 引用门一次跑完。**不要**在执行中才发现 `anim` 不存在——
第 5 步才失败的过场会留下半成品状态。这与 `RpgcStore` 的 fail-closed 设计一致
（[`05-ai-safe-operation.md`](05-ai-safe-operation.md)）。

## 6. 完整例子：一段过场

目标：玩家踏入雾林 → 镜头推近 → 长老说话 → 并行做两件事（弹一条提示 + 播 NPC 动画）
→ 消费掉一个世界对象 → 按支线是否完成选择不同收尾。

### 6.1 依赖的文档（先存在）

```text
content/maps/forest.json          等距关卡（含 spawn_1、chest_1）
content/anims/npc-elder.json      含 clip: "talk"、"idle"
```

### 6.2 `content/events/forest-arrive.json`

```json
{
  "schema": "eve.rpgc.event",
  "version": 1,
  "id": "forest-arrive",
  "title": "抵达雾林",
  "repeatable": false,
  "trigger": { "kind": "map_entered", "mapId": "forest" },
  "steps": [
    { "kind": "load_map", "mapId": "forest", "x": 1275, "y": 251.5 },
    { "kind": "wait", "duration": 0.4 },
    { "kind": "camera_focus", "x": 1670, "y": 420, "zoom": 1.4 },
    { "kind": "dialogue", "reference": "forest.elder.greet" },
    {
      "kind": "parallel",
      "steps": [
        { "kind": "message", "reference": "hint.forest.wolves" },
        { "kind": "play_animation", "anim": "npc-elder", "clip": "talk",
          "actorId": "elder_1" }
      ]
    },
    { "kind": "consume_object", "mapId": "forest", "objectName": "arrival_marker" },
    {
      "kind": "branch",
      "condition": { "kind": "switch", "name": "quest.wolves.accepted" },
      "then": [
        { "kind": "set_variable", "name": "forest.arrived", "op": "set", "value": 1 },
        { "kind": "message", "reference": "hint.forest.wolves_tip" }
      ],
      "else": [
        { "kind": "message", "reference": "hint.forest.explore" }
      ]
    },
    { "kind": "camera_pan", "x": 1275, "y": 251.5, "duration": 0.8 }
  ]
}
```

逐项对照：

1. `load_map` 的 `x/y` 是世界像素（和地图对象一样），项目传给
   `map.loadFromFileWithObjectContract` 之后自己决定把队伍摆在哪一格。
2. `wait` 让地图切换有一次可见的过渡，而不是同帧黑屏。
3. `camera_focus` 的 `zoom: 1.4` 由 schema 允许（0.1..8，`schema:39`），
   语义门不要求它，项目可选用。
4. `dialogue` 的 `reference` 是对话流 id；项目用
   `dialogueFlow.startChecked(reference, {})`。
5. `parallel` 下有两个步骤 —— 满足「至少两个」，不会触发
   `event.trivial-parallel`。深度：顶层是 1，`parallel` 的子步骤是 2；
   如果子步骤里再放 `branch`，深度检查会报 `event.depth`。
6. `consume_object` 落一次世界事实：`GameState` 的
   `world.object:forest` scope 下 `arrival_marker = 1`。
7. `branch` 的 `condition` 是 `switch`，只要求 `name`。
8. `camera_pan` 是项目钩子：`Camera2D::setPosition` 本身没有补间，
   项目在 0.8 秒里插值。

### 6.3 校验

```bash
python tools/rpgc.py check content/events/forest-arrive.json
```

期望 `PASS`。

### 6.4 故意改坏

```text
# 去掉 wait 的 duration
ERROR  .../events/forest-arrive.json:/steps/1/duration: step 'wait' needs 'duration'
       hint: the runtime cannot execute a step with an empty duration

# 把 duration 改成 0
ERROR  .../events/forest-arrive.json:/steps/1/duration: step 'wait' requires duration > 0
       hint: the engine's own wait step rejects a zero duration

# facing 同时给两个分量
ERROR  .../events/forest-arrive.json:/steps/0/facingX: face_actor must set only one of facingX/facingY
       hint: the project runtime keeps exactly one non-zero component

# parallel 只留一个步骤
WARN   .../events/forest-arrive.json:/steps/4/steps: parallel with fewer than two steps is just a sequence
       hint: use the plain step order instead

# 嵌套两层 branch
ERROR  .../events/forest-arrive.json:/steps/6/then/0: branch/parallel nesting is limited to 2 levels in v1

# 引用不存在的动画集
ERROR  event/forest-arrive references missing anim 'npc-ghost'
       hint: define content/anims/npc-ghost.json

# clip 名字写错（npc-elder 里没有 "talk_long"）
ERROR  event/forest-arrive references clip 'talk_long' which anim/npc-elder does not define

# 用不存在的 trigger kind
ERROR  .../events/forest-arrive.json:/trigger/kind: ...   ← 由 schema enum 拦下

# 用未知 step kind
ERROR  .../events/forest-arrive.json:/steps/0/kind: unknown step kind 'teleport'
       hint: see docs/03-event-editor.md for the closed set
```
