# 04 · 运行时集成

[`01`](01-tilemap-editor.md) / [`02`](02-skill-editor.md) / [`03`](03-event-editor.md)
描述的是**文档**。本文描述游戏怎么消费它们。

核心原则只有一条：

> **文档是唯一真值，适配器是纯投影。**
> 适配器不缓存第二份状态、不在加载时改写文档、不在运行时回写文档。

仓库里这份适配器就是 workflow 根目录的 `main.nut`：`eve run .`。

引擎侧与项目侧的边界也很明确：**工作流定义文档形状与校验；引擎定义运行时行为。**
任何「文档里写了但引擎不认」的字段，都必须由项目适配器解释，工作流不会替它解释。

## 1. 图集与地图

### 1.1 让引擎自己读（推荐）

地图文档的 `tilesets[0].source` 就是引擎自己的字段。走这条路时，图集**不需要**
项目适配器做任何事：`Map` 的读取器（`src/modules/map/TileConfig.cpp`）会解析 figure 的
`tiles` 逐项并调用 `setTileVisual` / `setTileMetadata` 等价路径
（`readTileVisual`，`TileConfig.cpp:143-176`；`applyTilesets`，`:536-540`）。

```squirrel
local map = eve.Map();

// 对象契约先准入：类型/属性不合法就整体拒绝，当前地图保持不变
local contract = fs.readText("data/world-object-contract.json");
local admitted = map.loadFromFileWithObjectContract("content/maps/forest.json", contract);
if (!admitted.ok) {
    print("map rejected: " + admitted.status.summary + "\n");
    return false;                       // 注意：旧地图仍在，不需要回滚
}

local layer = map.getLayer(0);
local path  = map.newPathfinder(layer);
```

`loadFromFileWithObjectContract(path, contractJson)` 的语义（`src/modules/map/Map.h:66-76`）：
**先解析并校验对象，再原子发布**；失败时返回结构化 `Result<int>`，且**保留之前的地图**。
Squirrel 绑定在 `src/modules/map/Map.cpp:570-581`，返回的是 Result 投影而不是裸 int。

对象契约本身是版本化文档（`"schema": "eve.map.object-contract"`，`"version": 1`），
示例见 `examples/rpg-classic/data/world-object-contract.json`：

```json
{
  "schema": "eve.map.object-contract",
  "version": 1,
  "requireUniqueNames": true,
  "allowUnknownTypes": false,
  "types": [
    { "type": "spawn", "properties": [] },
    { "type": "loot",  "properties": [
      { "name": "itemId", "kind": "string", "required": true },
      { "name": "gold",   "kind": "int", "min": 0 }
    ] }
  ]
}
```

`requireUniqueNames` 与工作流的 `map.duplicate-object` 是同一个意图的两层：
工作流在编辑期拦，契约在加载期拦。**两层都要**——第一层给出好诊断，第二层保证运行时不半途失败。

### 1.2 手工把图集文档投影到 `TileLayer`

如果项目从别处拿图集（比如运行时生成、或从 registry 取），可以自己投影。
工作流图集文档的每个字段都有对应 API：

```squirrel
function applyAtlas(layer, atlas, texture) {
    // schema 层：图片 + 规则网格
    layer.setTileset(texture, atlas.firstGid, atlas.columns,
                     atlas.margin, atlas.spacing);
    layer.setTilesetTileSize(atlas.tileWidth, atlas.tileHeight);

    // 逐 GID：不规则区域 + 脚点 + 排序偏移
    foreach (tile in atlas.tiles) {
        local r = tile.region;
        local pivot = ("pivot" in tile) ? tile.pivot : [0, 0];
        local bias  = ("sortBias" in tile) ? tile.sortBias : 0.0;
        layer.setTileVisual(tile.gid, r[0], r[1], r[2], r[3], pivot[0], pivot[1], bias);
    }
}
```

签名（`src/modules/map/TileLayer.h`）：

| API | 签名 | 说明 |
|-----|------|------|
| `setTileset` | `(texture, firstGid, columns, margin = 0, spacing = 0)` | `:270-271`，绑定 `Map.cpp:422` |
| `setTilesetTileSize` | `(tileW, tileH)` | `:273` |
| `setTileVisual` | `(gid, x, y, w, h, pivotX, pivotY, sortBias = 0)` | `:285-286`；`gid <= 0` 或尺寸非正时**静默返回**（`TileLayer.cpp:441`） |
| `setTileMetadata` | `(gid, footprintW, footprintH, walkable, cost = 1)` | `:292-293`；`cost <= 0` 被夹到 1（`TileLayer.cpp:480`） |
| `setTileNavigationProfile` | `(gid, walkable, cost, enterMask, exitMask, opaque, semanticFlags = 0)` | `:295-296`；`cost` 下限夹到 0.001（`TileLayer.cpp:496`） |
| `loadTilesetManifest` | `(path) -> bool` | `:298`，加载 `eve.tileset/1` manifest |
| `setCamera` | `(Camera2D*)` | `:306` |

**注意重复 GID 的静默覆盖**：`setTileVisual` / `setTileMetadata` 都是
「找到就改、找不到才追加」（`TileLayer.cpp:443-449`、`:470-476`），
而渲染的 `visualForGid` 取**第一个**匹配（`src/modules/map/TileSystem.cpp:81-85`）。
这两套语义在「重复 GID」时不一致——所以工作流的 `map.duplicate-gid` 是 error，不是 warning。

**注意 `footprintW/H` 没有消费者**：`setTileMetadata` 会存，渲染不读
（见 [`01-tilemap-editor.md`](01-tilemap-editor.md) §5.8）。多格占地要项目自己在
布局与寻路里实现，`RpgcIso.footprintCells` 提供了约定好的枚举。

### 1.3 玩家走行

```squirrel
local pf = map.newPathfinder(layer);   // Map.h:37，绑定 Map.cpp:582
pf.setDiagonal(false);                 // 四方向，匹配「走方格」
pf.blockGid(2);                        // 墙：GID 2 不可走
pf.blockGid(3);                        // 树：同样不可走
pf.setBlockEmpty(true);                // GID 0 也不可走
pf.syncFromLayer();                    // 从图层 GID 重建阻挡与成本

local path = pf.findPath(px, py, tx, ty);   // -> Path*
if (path != null) {
    local total = path.getTotalCost();
    for (local i = 0; i < path.getLength(); i += 1) {
        local wx = path.getX(i);
        local wy = path.getY(i);
    }
}
pf.isWalkable(tx, ty);
```

相关绑定（`src/modules/map/Map.cpp:470-490`，实现 `Pathfinder.h:38-47`）：

| API | 用途 |
|-----|------|
| `setTopology` / `setDiagonal` | 邻接拓扑与是否允许斜向 |
| `blockGid(gid)` / `unblockGid(gid)` / `clearBlockedGids()` | 按 GID 标阻挡。**工作流图集里的 `walkable` 字段不会自动生效**，项目必须把它翻译成这组调用 |
| `setBlocked(x, y, bool)` / `setCellCost(x, y, cost)` | 单格覆盖 |
| `syncFromLayer()` | 从当前图层重建 |
| `isWalkable(x, y)` / `findPath(x0, y0, x1, y1)` / `buildFlowField` / `followFlow` | 查询 |

**这是「图集文档 ↔ 寻路」之间唯一的接缝，而且它是有意留白的**：工作流把
`walkable` / `cost` / `enterMask` / `exitMask` / `opaque` 定义为图集的**声明**，
但把它们变成 `Pathfinder` / `Fov` 状态的**执行**属于运行时，因为阻挡可能在游戏过程中变化
（门开了、桥塌了）。适配器应在每次地图加载后重建一次，而不是缓存。

### 1.4 等距坐标

```squirrel
// 渲染位置（与编辑器、与 grid::cellToWorld 完全同一公式）
local wx = layer.tileToWorldX(tx, ty);
local wy = layer.tileToWorldY(tx, ty);
local dy = layer.depthYAt(tx, ty);      // 统一 2D 队列的排序键

// 拾取：X 和 Y 必须一起传
local tx2 = layer.worldToTileX(mouseX, mouseY);
local ty2 = layer.worldToTileY(mouseX, mouseY);
```

`TileLayer.h:446-450`、`Map.cpp:446-450`。**`worldToTileX` / `worldToTileY` 不夹取**
（见 [`01-tilemap-editor.md`](01-tilemap-editor.md) §2），项目必须自己判断越界。

## 2. 动画与技能

### 2.1 从 `anim` 文档建播放器

```squirrel
local animModule = eve.Animation();

function buildSheet(doc, texture) {
    local sheet = animModule.newSpriteSheet();
    sheet.setTexture(texture);
    sheet.setGrid(doc.columns, doc.rows, doc.frameWidth, doc.frameHeight,
                  ("margin" in doc) ? doc.margin : 0,
                  ("spacing" in doc) ? doc.spacing : 0);
    return sheet;
}

function buildClip(animModule, doc, clipDoc) {
    local clip = animModule.newSpriteClip(clipDoc.id);
    local period = 1.0 / clipDoc.fps;
    foreach (sheetFrame in clipDoc.frames) clip.addFrame(sheetFrame, period);
    clip.setLoop(("loop" in clipDoc) ? clipDoc.loop : true);
    if ("events" in clipDoc) {
        foreach (ev in clipDoc.events) clip.addEvent(ev.frame, ev.name);
    }
    return clip;
}
```

签名（`src/modules/animation/SpriteSheet.h`、`SpriteClip.h`）：

| API | 签名 | 文件 |
|-----|------|------|
| `newSpriteSheet()` | `-> SpriteSheet` | `Animation.cpp:1288` |
| `setGrid` | `(columns, rows, frameW, frameH, margin=0, spacing=0, originX=0, originY=0) -> int` | `SpriteSheet.h:40-41` |
| `addFrame` | `(sheetFrameIndex, duration=0.1)` | `SpriteClip.h:30` |
| `setFPS` | `(fps)`，把每帧时长重写为 `1/fps` | `SpriteClip.h:38` |
| `setLoop` | `(bool)` | `SpriteClip.h:26` |
| `addEvent` | `(clipFrame, name)`，**clip 帧下标** | `SpriteClip.h:42` |
| `newSpriteClip(name)` | `-> SpriteClip` | `Animation.cpp:253` |
| `newSpriteAnim()` | `-> SpriteAnim`，自动进模块帧泵 | `Animation.cpp:255-258,410-417` |

`bindSprite` 只在**裁剪过**的帧上产生差异：它会同步 trimmed-frame 布局
（`SpriteSheet::addFrameTrimmed` / `getFrameSourceWidth` 一族，`SpriteSheet.h:31-33,57-60`）。
普通规则网格用 `bindQuad` 也可：`bindQuad(quad)` + `quad` 挂到 `Renderable2D`，
这是 `examples/sprite-animation-vfx/main.nut:10-41` 的做法。

### 2.2 驱动技能表现：轮询 cast 事件

**引擎没有 cast → 动画的绑定**（见 [`02-skill-editor.md`](02-skill-editor.md) §1.4、§6.2）。
项目必须自己维护一张表现表，并靠轮询推进：

```squirrel
// 每个 actor 一套表现资源：每个 on 目标一个 SpriteAnim
performance <- {};    // actorId -> { caster = <SpriteAnim>, target = ..., impact = ... }

function beginPerformance(actorId, skillId, level) {
    local skill = skillById(skillId);
    local plan  = resolvePresentation(skill.presentation, level);   // 见 §2.3
    local slots = performance[actorId];
    slots.caster.play(clipOf(plan.segments[0]));
    slots.segmentIndex = 0;
    slots.plan = plan;
}

function pumpPerformance(actor, dt) {
    local slots = performance[actor.id];
    if (slots == null) return;
    local player = slots.caster;

    // 剪辑内事件：段内的相对时刻（如弹道释放点）
    local ev = player.consumeEvent();
    if (ev == "release") spawnProjectile(actor);

    // 段结束：推进到下一段
    if (player.consumeCompleted()) {
        slots.segmentIndex += 1;
        if (slots.segmentIndex < slots.plan.segments.len()) {
            player.play(clipOf(slots.plan.segments[slots.segmentIndex]));
        } else {
            performance[actor.id] = null;
        }
    }
}

// 主循环顺序：先推引擎，再把引擎事实投影成表现
rpg.update(dt);
for (local i = 0; i < rpg.getCastEventCount(); i += 1) {
    local caster = rpg.getCastEventCaster(i);
    local target = rpg.getCastEventTarget(i);
    local skillId = rpg.getCastEventSkillId(i);
    local actorId = idOf(caster);            // 见下
    if (actorId == "") continue;
    beginPerformance(actorId, skillId, caster.getLevel());
    if (target != null) attachTargetSlot(actorId, idOf(target));
}
foreach (actor in actors) pumpPerformance(actor, dt);
```

`idOf(actor)` 必须是**项目自己的映射**：`RPGActor` 的 Squirrel 绑定里没有任何名字或 id 访问器
（`src/modules/rpg/RPG.cpp:553-702` 的 actor 绑定表里只有属性、状态、技能、成长、特征、职业）。
项目在建 actor 时把 `actor -> 自己的 id（如 "hero" / "elder_1"）` 记进一张表即可。
`target` 也可能是 `null`（`src/modules/rpg/SkillTypes.h:27` 注释：自身或无目标技能）。

`consumeEvent()` 是**一次性**的（`SpriteAnim.h:63`，内部是单个 `pendingEvent_`，
`SpriteAnim.h:144`）；`consumeCompleted()` 同理（`:75`）。在错误的帧读就会丢事件，
所以这个泵必须每帧跑一次、且在 `rpg.update` 之后。

cast 事件的签名（`src/modules/rpg/RPG.cpp:1336-1339`）：

```text
rpg.getCastEventCount()            -> int
rpg.getCastEventCaster(index)      -> RPGActor*
rpg.getCastEventTarget(index)      -> RPGActor*
rpg.getCastEventSkillId(index)     -> string
```

事件只带 `{caster, target, skillId}`（`src/modules/rpg/SkillTypes.h:25-29`），
没有前摇/命中/后摇边界、没有 payload。**段内时序必须来自 `SpriteClip` 的命名事件**，
不是来自 cast 事件。

### 2.3 等级覆盖的解析

`presentation.levels[]` 已由语义门保证**升序且唯一**（
[`02-skill-editor.md`](02-skill-editor.md) §5.2），所以解析是「取最后一个 `level <= n` 的行」：

```squirrel
function resolvePresentation(presentation, level) {
    local chosen = null;
    foreach (row in presentation.levels) {
        if (row.level <= level) chosen = row;
        else break;                       // 已升序，可以提前退出
    }
    local out = {
        segments = presentation.segments,
        vfx      = presentation.vfx,
        magnitude = 1.0
    };
    if (chosen != null) {
        if ("segments" in chosen) out.segments = chosen.segments;   // 整段替换
        if ("vfx" in chosen)      out.vfx      = chosen.vfx;        // 覆盖
        if ("magnitude" in chosen) out.magnitude = chosen.magnitude;
    }
    return out;
}
```

三条语义必须照抄，否则表现会和作者的意图不一致：

1. `segments` 是**替换**不是追加；
2. `vfx` 是**覆盖**技能级的同名键；
3. 没有匹配行时用技能级 `segments`（不是空）。

### 2.4 登记玩法半段

```squirrel
rpg.registerSkillsFromJson(skillJson);            // Skill.cpp:163-188
rpg.registerSkillDamage(
    skill.id,
    "hp",                                         // damageType
    skill.damage.formula,
    ("element" in skill.damage) ? skill.damage.element : "",
    ("critChance" in skill.damage) ? skill.damage.critChance : 0.0,
    (("hitChance" in skill.damage) ? skill.damage.hitChance : 1.0) * 100.0);   // ← 单位换算
rpg.registerEffectsFromJson(effectJson);          // Effect.cpp:71-96
```

三条必须记住的现状：

1. **不存在 `replaceSkillsFromJson` / `replaceEffectsFromJson`。**
   `src/` 全库 grep 为零。这两个加载器是**宽松、按 id 覆盖、无原子替换**的：
   `parseSkillObject` 遇到空 id 会**静默跳过该元素**（`Skill.cpp:176`），
   没有任何错误信息，也没有 Result。所以「加载失败」在这里是不可观测的——
   **校验必须在加载之前完成**（`RpgcValidate` + schema），不能指望加载器告诉你。
2. **`registerSkillDamage` 不检查技能是否存在。** 它只校验 skillId 非空与公式可解析
   （`src/modules/rpg/BattleSystem.cpp:28-39`）。给一个拼错的 id 登记伤害不会报错。
   工作流的 `id`/文件名一致性与引用门是唯一的保护。
3. **`hitChance` 单位不一致**：文档里是 0..1，`registerSkillDamage` 要百分数
   （`examples/rpg-classic/main.nut:253-258` 用 100 / 95）。适配器负责乘 100。

## 3. 事件

### 3.1 解释器

```squirrel
function runEvent(doc) {
    local session = { steps = doc.steps, cursor = 0, pending = [] };
    while (session.cursor < session.steps.len()) {
        local step = session.steps[session.cursor];
        if (!executeStep(step, session)) return;      // 挂起（等对话、等动画、等时长）
        session.cursor += 1;
    }
}

function executeStep(step, session) {
    if (step.kind == "load_map") {
        return loadWorldMap(step.mapId, step.x, step.y);
    }
    if (step.kind == "wait")      return waitFor(step.duration);
    if (step.kind == "camera_focus") {
        cam.setPosition(step.x, step.y);
        if ("zoom" in step) cam.setZoom(step.zoom);
        return true;
    }
    if (step.kind == "dialogue")  return dialogueFlow.startChecked(step.reference, {}).ok;
    if (step.kind == "message")   { showMessage(tr(step.reference)); return true; }
    if (step.kind == "set_variable") {
        if (step.op == "set")        gameState.setVariable(step.name, step.value);
        else if (step.op == "add")   gameState.addVariable(step.name, step.value);
        else if (step.op == "sub")   gameState.addVariable(step.name, -step.value);
        else if (step.op == "switchOn")  gameState.switchOn(step.name);
        else if (step.op == "switchOff") gameState.switchOff(step.name);
        return true;
    }
    if (step.kind == "consume_object") {
        return worldState.consumeObject(step.mapId, step.objectName).ok;
    }
    // 项目钩子
    if (step.kind == "move_actor")   return moveActorTo(step.actorId, step.x, step.y);
    if (step.kind == "face_actor")   return setActorFacing(step.actorId, step.facingX, step.facingY);
    if (step.kind == "play_animation") return playClipFor(step.actorId, step.anim, step.clip);
    if (step.kind == "camera_pan")   return panCameraTo(step.x, step.y, step.duration);
    if (step.kind == "parallel")     return startParallel(step.steps, session);
    if (step.kind == "branch")       return runBranch(step, session);
    return false;    // 不该发生：schema + 语义门已排除未知 kind
}
```

各步骤对应的引擎绑定与文件位置见 [`03-event-editor.md`](03-event-editor.md) §3 的总表。

### 3.2 两个必须遵守的约束

**约束一：并行子步骤不得各自确认游标。**

引擎的 `StoryEventSession::advance` 是比较并设置（`src/modules/rpg/StoryEvent.cpp:224-233`，
详见 [`03-event-editor.md`](03-event-editor.md) §5.1）。如果 `parallel` 的每个子步骤
都推进一次 `GameState` 的游标，第二次就命中 `Conflict`。正确形状是父步骤持有一个子游标数组，
全部子步骤完成后由父步骤推进**一次**。

**约束二：事件加载前先校验。**

```squirrel
local checked = RpgcValidate.validateFile("event", "content/events/forest-arrive.json");
if (!checked.ok) { print(Rpgc.summary(checked) + "\n"); return; }
local read = RpgcStore.readDocument("content/events/forest-arrive.json");
runEvent(read.value);
```

在运行时才发现 `anim` 不存在，意味着一个过场播到第 5 步才炸，前面的
`load_map` / `consume_object` / `set_variable` 已经生效了。工作流的整个设计前提是
**失败发生在写盘/加载之前**，见 [`05-ai-safe-operation.md`](05-ai-safe-operation.md)。

## 4. 适配器不得做的事

| 反模式 | 为什么 |
|--------|--------|
| 把 `anim` 文档转成一份「运行时动画表」并当作真值 | 真值在文档。适配器是投影，每次加载重建即可 |
| 在运行时回写文档 | Squirrel 在 MCP 宿主里根本写不了项目文件；只有 `RpgcStore.stage` + `tools/rpgc.py export` 是合法路径 |
| 复制 schema 的约束到 Squirrel 里做二次校验 | 会产生第二份会漂移的规则。用 `RpgcValidate`，它调的是引擎自己的 `eve.Schema()` |
| 用 `RpgcProject.index()` 之外的方式枚举内容 | 会得到与编辑器/CLI 不一致的「哪些内容存在」 |
| 把 `presentation.levels` 当成「追加段」 | 它是替换。见 §2.3 |
| 假设 `registerSkillsFromJson` 会报错 | 它返回计数，空 id 静默跳过，无 Result |

## 5. 最小可运行的接线清单

```text
1. 启动时
   - 读并注册所有 content/effects/*.json  → rpg.registerEffectsFromJson
   - 读并注册所有 content/skills/*.json   → rpg.registerSkillsFromJson
   - 对每个技能的 damage 调 rpg.registerSkillDamage（注意 hitChance × 100）
   - 为每个 content/anims/*.json 建 SpriteSheet（需要 texture）与按 id 索引的 SpriteClip 表
   - 为每个 content/events/*.json 跑一次 RpgcValidate.validateFile

2. 进入地图时
   - map.loadFromFileWithObjectContract(mapPath, contractText)
   - 从 content/tilesets/<id>.json 把 walkable/cost 翻译成 pf.blockGid / setCellCost
   - pf.syncFromLayer()

3. 每帧
   - map.update(dt); rpg.update(dt)
   - 读 rpg.getCastEvent* → 启动/切换表现
   - 泵每个 SpriteAnim（consumeEvent / consumeCompleted）
   - 泵事件解释器（wait / camera_pan / dialogue 完成回调）

4. 内容改动时（开发期）
   - 改的是 content/ 下的 JSON
   - 校验：python tools/rpgc.py validate
   - 热重载：重跑第 1 步（工作流不做版本迁移，见 README「明确不提供的东西」）
```

第 4 步值得强调：**这些文档没有 migration，也没有部分重载语义**。
改一份 `skill` 文档意味着重新注册那个技能；改一份 `anim` 文档意味着重建那个 sheet 的 clip 表。
这是 v1 的有意取舍——把复杂度留给「重新加载」，而不是「增量演进」。
