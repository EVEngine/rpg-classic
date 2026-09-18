# 02 · 技能编辑器（skill）

对应 `lib/rpgc_skill.nut`、`schema/eve.rpgc.anim.json`、`schema/eve.rpgc.effect.json`、
`schema/eve.rpgc.skill.json`。

> 落地状态：人用入口是 `eve run apps/skill`。Agent 入口 `eve mcp` 会一并恢复该编辑器（`eve_host_status.viewModels` 里能看到 `SkillVM`）。主窗口画战斗场面（`battle.open-field` 画布等比缩放，右侧 inspector），`previewClip` 在阵位上播放演出分段。

## 1. 起点：引擎缺什么

要理解这份文档为什么长这样，先看引擎**没有**什么。

### 1.1 `SkillDefinition` 里没有任何动画引用

```cpp
// src/modules/rpg/Skill.h:25-39（字段罗列）
id, cooldown, castTime, targetType, cost, grantedEffects, tags, castCondition, extra
```

九个字段里没有一个能指向一段精灵动画。技能的 JSON 加载器
`SkillRegistry::loadFromJson` / `parseSkillObject`（`src/modules/rpg/Skill.cpp:118-188`）
读的就是这些，未知字段直接忽略。

### 1.2 `extra` 是唯一的理论载体，但它既不被引擎读、也没暴露给脚本

`Skill.h:9-10,36` 自己都写了「动画名、特效……」是 `extra` 的用途，
`docs/dev/RPG系统设计.md` 也这么描述。但：

- `src/` 里**没有任何代码读取 `SkillDefinition::extra`**——只有 `Skill.cpp:43,157`
  和 `SkillDefinitionRuntime.cpp:118` 在写它；
- Squirrel 侧**没有 `getSkillExtra` 之类的绑定**，脚本拿不到它。

所以「把动画名塞进 `extra`」在今天是一条死路。

### 1.3 没有等级缩放

技能上没有任何 per-level 字段。「等级」在 RPG 模块里只出现在两处：

- 职业学技能的等级门槛：`ClassLearnSkill{skillId, level}`（`src/modules/rpg/Class.h:18-21`），
  由 `ClassSystem::checkLevelSkills`（`src/modules/rpg/ClassSystem.cpp:40-56`）应用；
- 战斗胜利给的点数：`BattleVictory.cpp:74` 的 `pointsPerLevel`。

没有任何东西按等级改效果强度、冷却或表现。`EffectModifierSpec` 只有固定的 `value` + `priority`
（`src/modules/rpg/Effect.h:25-30`）。

### 1.4 `RPGActor` 完全没有渲染/动画面

```cpp
// src/modules/rpg/RPGActor.h:101-107（component 列表）
Attributes, Statuses, Skills, Progression, Vitals, Traits, ClassInfo
```

没有 sprite / render / animation component，也没有指向实体的 Link。

### 1.5 结论

**「技能 = 多段精灵动画 + 效果 + 等级变化」这个契约完全在项目侧。**
引擎只提供两半零件：

- 2D 精灵逐帧播放（`SpriteSheet` / `SpriteClip` / `SpriteAnim`）；
- 玩法判定（`rpg.registerSkillsFromJson` / `rpg.registerSkillDamage`）。

唯一的接缝是**轮询**：跑完 `rpg.update(dt)` 之后读
`rpg.getCastEventCount()/getCastEventCaster/Target/SkillId`（`src/modules/rpg/RPG.cpp:1336-1339`），
由项目自己维护「哪个 actor 现在在放哪段动画」。见
[`04-runtime-integration.md`](04-runtime-integration.md)。

## 2. 三份文档

一个技能被拆成三种文档，因为它们有三条不同的生命周期：

```text
content/anims/<animId>.json     图片 + 帧网格；被多个技能复用
content/effects/<effectId>.json 引擎效果模板；被多个技能复用
content/skills/<skillId>.json   玩法 + 表现脚本；引用上面两者
```

好处是：改一次动画集的帧率，所有引用它的技能一起变；改一个效果模板的数值，
所有施加它的技能一起变。这也是为什么校验层里有一整层专门查引用（`ref.dangling`）
和一层专门查「技能声明的 clip 在动画集里到底存不存在」（`skill.unknown-clip`）。

## 3. `anim` 文档（`eve.rpgc.anim`）

字段见 `schema/eve.rpgc.anim.json`。

| 字段 | 类型 | 必填 | 映射到的引擎 API |
|------|------|------|------------------|
| `image` | string | 是 | `SpriteSheet::setTexture(gfx.loadTexture(...))`（`SpriteSheet.h:46`）；工作流不检查文件存在 |
| `frameWidth` / `frameHeight` | integer 1..1024 | 是 | `SpriteSheet::setGrid` 的 `frameW` / `frameH` |
| `columns` | integer 1..256 | 是 | `SpriteSheet::setGrid` 的 `columns` |
| `rows` | integer 1..256 | 否 | `setGrid` 的 `rows`；有 rows 时工作流才能校验帧号范围 |
| `margin` / `spacing` | integer ≥0 | 否 | `setGrid` 的 `margin` / `spacing` |
| `clips[]` | array 1..32 | 是 | 每个元素 → 一个 `SpriteClip` |

`clips[]` 一项：

| 字段 | 类型 | 必填 | 映射 |
|------|------|------|------|
| `id` | string | 是 | `SpriteClip::setName`；同时也是技能段引用的名字 |
| `frames` | integer[] 1..512 | 是 | 依次 `SpriteClip::addFrame(sheetFrame, duration)`（`SpriteClip.h:30`） |
| `fps` | number 0.1..120 | 是 | `SpriteClip::setFPS(fps)`（`SpriteClip.h:38`，把每帧时长重写为 `1/fps`） |
| `loop` | bool | 否 | `SpriteClip::setLoop(bool)`（`SpriteClip.h:26`） |
| `events[]` | array ≤32 | 否 | `SpriteClip::addEvent(clipFrame, name)`（`SpriteClip.h:42`） |
| `events[].frame` | integer ≥0 | 是 | **clip 帧下标**，不是 sheet 帧下标 |
| `events[].name` | string | 是 | `SpriteAnim::consumeEvent()` 返回的字符串 |

语义门（`lib/rpgc_skill.nut:35-89`）：

- `clip.id` 必须是稳定 id（`Rpgc.validId`：ASCII 字母数字加 `._-`，1..64 字节）且**唯一**。
  引擎侧没有这个检查——两个同名 `SpriteClip` 各自独立，脚本手上是哪个就播哪个，
  「最后一个赢」只发生在项目自己的按名索引里；
- `events[].frame` 必须落在 `frames.len()` 内（`skill.event-out-of-range`），
  hint 明确写着 "SpriteClip::addEvent indexes clip frames, not sheet frames"；
- events 必须**按 frame 升序**（`skill.unsorted-events`）。引擎的 `events_` 是
  `unordered_map<int,string>`（`SpriteClip.h:73`），本身不排序；
- 有 `rows` 时，`frames[]` 里每个 sheet 帧必须是 `columns * rows` 内的合法格号
  （`skill.frame-out-of-range`，`lib/rpgc_skill.nut:78-86`）。

## 4. `effect` 文档（`eve.rpgc.effect`）

这份文档的形状**等于引擎自己的效果模板**，因为 `rpg.registerEffectsFromJson` 读的就是它。

| 字段 | 类型 | 映射（`src/modules/rpg/Effect.cpp:44-67`） |
|------|------|------|
| `id` | string | `Effect.cpp:47` |
| `durationPolicy` | `instant`\|`duration`\|`infinite`，默认 `instant` | `Effect.cpp:48` |
| `duration` | number 秒，默认 0 | `Effect.cpp:49` |
| `period` | number 秒，默认 0；>0 表示周期性 tick 事件、不再自动改属性 | `Effect.cpp:50`，`Effect.h:39-40` |
| `stackPolicy` | `none`\|`refresh`\|`extend`\|`stack`，默认 `none` | `Effect.cpp:51` |
| `maxStacks` | integer，默认 1 | `Effect.cpp:52` |
| `modifiers[]` | `{attribute, op=add, value=0, priority=0}` | `Effect.cpp:56-65` |
| `tags` | string[] | `Effect.cpp:53` |
| `extra` | object string→string | `Effect.cpp:54`；应用时**逐键复制到活状态实例上**（`StatusSystem.cpp:106`），可用 `actor.getStatusProp(instanceId, key, fallback)` 读回 |

> 命名注意：仓库里**只有** `rpg.registerEffectsFromJson` 与 `rpg.registerSkillsFromJson`
> （`src/modules/rpg/RPG.h:79,84`）；不存在 `replaceEffectsFromJson` / `replaceSkillsFromJson`
> （`src/` 全库 grep 为零）。技能与效果的加载是**宽松、按 id 覆盖、无原子替换**的，
> 不同于任务/商店/遭遇那一族 `replace*FromJsonStrict`。校验请以 schema + 语义门为准。

语义门（`lib/rpgc_skill.nut:93-121`）加的是引擎不查的一致性：

| code | 严重度 | 条件 | hint |
|------|--------|------|------|
| `skill.instant-duration` | warning | `durationPolicy == "instant"` 但 `duration > 0` | 引擎会忽略它 |
| `skill.period-requires-duration` | error | `period > 0` 但策略不是 `duration` | 否则引擎永远不 tick |
| `skill.period-exceeds-duration` | warning | `period > duration` | 第一次 tick 之前就到期了 |
| `skill.stacks-unused` | warning | `maxStacks > 1` 但 `stackPolicy == "none"` | 用 `stack` 或 `refresh` |

`extra` 是效果表现键唯一的合法容器。约定俗成的键是项目自己的（如
`{"vfx": "particles://fx/burn", "icon": "ui/burn.png"}`），引擎不理解它们，
只是把字符串搬到活状态实例上；读取靠 `RPGActor::getStatusProp`
（`src/modules/rpg/RPGActor.h:158-160`）与 `setStatusProp`。**不要**把 `extra` 当作校验载体：
`eve.rpgc.effect` 里 `extra` 是 `"type": "object"`，不约束内部结构。

## 5. `skill` 文档（`eve.rpgc.skill`）

字段见 `schema/eve.rpgc.skill.json`。它明确分成两半。

### 5.1 玩法半段（引擎直接消费）

| 字段 | 类型 | 引擎 API |
|------|------|----------|
| `id` | string | `SkillDefinition::id`（`src/modules/rpg/Skill.cpp:121`） |
| `targetType` | enum，7 个取值 | `Skill.cpp:124`；**引擎从不解释这个字符串**，`Skill.h:6-8` |
| `cooldown` | number 0..600 | `Skill.cpp:122` |
| `castTime` | number 0..60 | `Skill.cpp:123` |
| `costs[]` | `{attribute, amount}` | `Skill.cpp:128-155`，这里是**引擎会认真校验**的一段：资源名非空、amount 有限、>0、整数、<2^63 |
| `effects` | string[] ≤8 | 写进 `grantedEffects`（`Skill.cpp:125`） |
| `tags` | string[] ≤8 | `Skill.cpp:126` |
| `damage` | object | 不在技能 JSON 里。走独立的 `rpg.registerSkillDamage(skillId, damageType, formula, element, critChance, hitChance)`（绑定 `RPG.cpp:1309-1315`，实现 `RPG.cpp:366-377`）。该调用**不检查技能是否存在**（`BattleSystem.cpp:28-39` 只校验 id 非空与公式可解析） |

`title` / `description` 是工作流字段，引擎忽略（`additionalProperties:false` 只约束工作流自己）。

`damage.formula` 由 `RpgcSkill.formulaSanity`（`lib/rpgc_skill.nut:198-217`）做保守词法检查：
长度 ≤160、括号平衡、且不含 `<script`、`;`、`import `、`dofile`、`loadfile`、
`compilestring`、`::`。**引擎的表达式求值器才是权威**，这里只是让编辑器在作者运行游戏之前
就能拒绝明显不可能解析的文本。

### 5.2 表现半段（项目运行时消费）

```json
"presentation": {
  "segments": [
    { "anim": "hero", "clip": "cast", "on": "caster", "atEvent": "", "hold": 0.0 }
  ],
  "vfx": "particles://fx/fireball-impact",
  "screenShake": 0.2,
  "levels": [
    { "level": 5, "magnitude": 1.6, "vfx": "particles://fx/fireball-impact-large",
      "segments": [ { "anim": "hero", "clip": "cast_empowered" } ] }
  ]
}
```

| 字段 | 类型 | 含义 |
|------|------|------|
| `segments[]` | array 1..8 | 按顺序播放的表现段 |
| `segments[].anim` | string 必填 | 引用一个 `anim` 文档的 id |
| `segments[].clip` | string 必填 | 引用该动画集里的一个 clip id |
| `segments[].on` | `caster`\|`target`\|`impact`\|`screen` | 这段动画挂在谁身上。默认取 `caster` |
| `segments[].atEvent` | string | 等到前一段的命名事件触发后再开始本段；空表示顺序播放 |
| `segments[].hold` | number 0..10 | 本段结束后的额外停留秒数（`i > 0` 时不得为负） |
| `vfx` | string | 技能整体的特效资源名；项目侧解释 |
| `screenShake` | number 0..1 | 项目侧解释的震屏强度 |
| `levels[]` | array ≤16 | 等级覆盖行 |

**`levels[]` 的语义**：

- 每行必须有 `level`（1..99）；
- 行必须**按 level 升序**、且**不重复**（`skill.unsorted-levels` / `skill.duplicate-level`，
  `lib/rpgc_skill.nut:140-156`）；
- 一行的 `segments` **替换**整段表现（不是追加），`vfx` **覆盖**技能级 `vfx`，
  `magnitude` 是项目侧使用的强度系数；
- 「当前等级适用哪一行」是项目运行时的规则：取 `level <= 当前等级` 的**最大** level 行。
  工作流只保证行的有序唯一，**不实现这个选择逻辑**——它需要角色等级，
  而工作流不持有角色。

这是本设计里最需要说清楚的一点：**等级覆盖是纯数据，工作流不解释它。**

### 5.3 语义门

- `presentation` 必须存在（`skill.no-presentation`，error）；
- 每段必须有非空 `anim` 与 `clip`（`skill.segment-anim` / `skill.segment-clip`）；
- `hold` 在第一段之后不得为负（`skill.segment-hold`）；
- 等级行的 `segments` 走同一套段检查，路径是
  `/presentation/levels/<i>/segments/<j>`；
- `damage` 存在时公式必须通过 `formulaSanity`。

### 5.4 引用层

`RpgcSkill.references`（`lib/rpgc_skill.nut:221-252`）产出：

- `effects[i]` → `{kind: "effect", id}`，路径 `/effects/i`；
- 技能级与每个等级段的 `anim` → `{kind: "anim", id}`，
  路径 `/presentation/segments/i/anim` 与 `/presentation/levels/k/segments/i/anim`。

这些交给通用引用门 `RpgcValidate.validateReferences`
（`lib/rpgc_validate.nut:206-237`）解析，悬空则 `ref.dangling`，hint 会直接给出
应该新建的文件路径。

**`effects[]` 是否在 `EffectRegistry` 里真实存在，只有引用门查**：它按
`content/effects/<id>.json` 是否存在判断。引擎侧 `Skill.cpp:125` 完全不解析这些 id。

### 5.5 额外层

`RpgcSkill.extraDiagnostics`（`:257-295`）在整项目校验时跑一次，检查
「技能段引用的 `clip` 是否真的在它引用的 `anim` 文档里」。这是 schema 与引用门都表达不了的：
引用门只能保证 `anim` 文档存在，不能保证里面那个 clip 存在。报 `skill.unknown-clip`。

事件里的 `play_animation` 有对称的检查，见 [`03-event-editor.md`](03-event-editor.md)。

## 6. 引擎限制：多段技能是项目自己的链

### 6.1 `queue()` 只有一个槽位

```cpp
// src/modules/animation/SpriteAnim.cpp:135
void SpriteAnim::queue(SpriteClip *clip) { if (!clip) throw Exception("...clip is null"); queuedClip_ = clip; }
```

`queuedClip_` 是**一个指针**，不是列表。第二次 `queue()` 会直接覆盖第一次。
播完当前剪辑时才会取它（`SpriteAnim.cpp:269-271`）。

再叠上「一个 `SpriteAnim` 只有一个 playhead（`time_` / `clipFrame_`，`SpriteAnim.h:129-130`）」，
结论很清楚：

| 想要 | 引擎今天能给 |
|------|-------------|
| 两段线性衔接 | `play(A); queue(B);` 可以 |
| 三段以上线性衔接 | **不行**：第二次 `queue()` 覆盖 |
| 多段并行（施法者 + 命中特效两层） | **不行**：`SpriteAnim` 只有一个 playhead，需要**两个** `SpriteAnim` 实例 |
| 带事件的跨段共享时间轴 | **不行**：事件是 clip 帧下标（`SpriteClip::addEvent`），每段独立 |

所以 `presentation.segments` 是**项目运行时**的链式调度，不是引擎构造。
实践上：每个 `on` 目标（caster / target / impact / screen）各持一个 `SpriteAnim`，
段与段之间由项目代码在 `consumeCompleted()`（`SpriteAnim.h:75`）为真时推进下一段。

一个 `SpriteAnim` 不能被两个目标共用——它只有一个 `boundSprite_`
（`SpriteAnim.h:127`）和一个 playhead。需要 N 个同时播放的动画，就创建 N 个 `newSpriteAnim()`。
`eve.Animation()` 会把每个新建的实例注册进模块的帧泵
（`src/modules/animation/Animation.cpp:255-258,410-417`），所以它们的 `update` 是自动的；
项目只需要在正确的时机 `play` / `queue` / 推进链。

### 6.2 没有 clip → actor 的绑定

`RPGActor` 没有渲染面（§1.4），`SpriteAnim::bindSprite` 只接受
`graphics::Renderable2D*`（`SpriteAnim.h:90`）。所以「这个 actor 身上现在播什么」
必须由项目维护一张 `actorId -> { SpriteAnim, Renderable2D }` 的表，
并在轮询到施法事件时驱动它。

### 6.3 表现键怎么串起来

三个可用的接缝，按可靠性排序：

1. **技能文档 → 效果模板 `extra`**：`actor.getStatusProp(instanceId, "vfx", "")`
   能拿到施加时写进去的表现键。这是一条**引擎内**的链路。
2. **cast 事件轮询**：`rpg.getCastEventSkillId(i)` → 查技能文档 →
   按 `(skillId, level)` 选 `presentation` → 驱动本地动画表。这是一条**项目内**链路。
3. **`atEvent`**：段之间的相对时序，由项目的调度器解释。

引擎**没有**「技能 → 动画」的绑定，也没有「伤害数字 / 命中特效」的事件流：
`SkillCastEvent` 只带 `{caster, target, skillId}`（`src/modules/rpg/SkillTypes.h:25-29`），
在结算时发一次（`src/modules/rpg/SkillSystem.cpp:38-49`），没有前摇/命中/后摇边界，
也没有 payload。

## 7. 完整例子：火球

### 7.1 `content/anims/hero.json`

```json
{
  "schema": "eve.rpgc.anim",
  "version": 1,
  "id": "hero",
  "title": "主角精灵",
  "image": "textures/hero.png",
  "frameWidth": 64,
  "frameHeight": 64,
  "columns": 8,
  "rows": 4,
  "margin": 0,
  "spacing": 0,
  "clips": [
    {
      "id": "cast",
      "frames": [8, 9, 10, 11, 12, 13, 14, 15],
      "fps": 12.0,
      "loop": false,
      "events": [ { "frame": 4, "name": "release" } ]
    },
    {
      "id": "cast_empowered",
      "frames": [16, 17, 18, 19, 20, 21, 22, 23],
      "fps": 10.0,
      "loop": false,
      "events": [ { "frame": 4, "name": "release" } ]
    },
    {
      "id": "idle",
      "frames": [0, 1, 2, 3],
      "fps": 6.0,
      "loop": true
    }
  ]
}
```

`columns*rows = 32`，所以帧号 0..31 合法。`cast` 的第 4 个 clip 帧（sheet 帧 12）
带一个 `release` 事件——这是项目用来生成火球弹道的时刻。

### 7.2 `content/effects/burn.json`

```json
{
  "schema": "eve.rpgc.effect",
  "version": 1,
  "id": "burn",
  "title": "灼烧",
  "durationPolicy": "duration",
  "duration": 6.0,
  "period": 2.0,
  "stackPolicy": "refresh",
  "maxStacks": 1,
  "tags": ["dot", "fire"],
  "modifiers": [],
  "extra": {
    "vfx": "particles://fx/burn",
    "icon": "ui/burn.png"
  }
}
```

`period: 2.0 <= duration: 6.0`，不会触发 `skill.period-exceeds-duration`。
`modifiers` 为空是因为持续伤害由周期性 tick 事件驱动，项目读 `getTickEvent*` 自行结算。

### 7.3 `content/skills/fireball.json`

```json
{
  "schema": "eve.rpgc.skill",
  "version": 1,
  "id": "fireball",
  "title": "火球",
  "description": "对单体敌人造成火焰伤害并附加灼烧。",
  "targetType": "enemySingle",
  "cooldown": 3.0,
  "castTime": 0.6,
  "costs": [ { "attribute": "mana", "amount": 15 } ],
  "effects": ["burn"],
  "tags": ["attack", "magic"],
  "damage": {
    "formula": "a.attack * 2",
    "element": "fire",
    "critChance": 0.05,
    "hitChance": 0.95
  },
  "presentation": {
    "segments": [
      { "anim": "hero", "clip": "cast", "on": "caster", "hold": 0.0 }
    ],
    "vfx": "particles://fx/fireball-impact",
    "screenShake": 0.2,
    "levels": [
      {
        "level": 5,
        "magnitude": 1.6,
        "vfx": "particles://fx/fireball-impact-large",
        "segments": [
          { "anim": "hero", "clip": "cast_empowered", "on": "caster", "hold": 0.1 }
        ]
      }
    ]
  }
}
```

### 7.4 这些文档怎么被消费

```squirrel
// 1. 玩法半段：技能表 + 伤害登记
rpg.registerSkillsFromJson(RpgcJson.encode(skillDocument));
rpg.registerSkillDamage(
    "fireball",          // skillId，必须与文档 id 一致
    "hp",                // damageType
    "a.attack * 2",      // formula，必须与文档 damage.formula 一致
    "fire",              // element
    0.05,                // critChance
    95);                 // hitChance（注意这里是百分数，而文档里是 0..1）

// 2. 效果模板
rpg.registerEffectsFromJson(RpgcJson.encode(effectDocument));

// 3. 表现半段：项目自己建 sheet / clip / player
local sheet = anim.newSpriteSheet();
sheet.setTexture(gfx.loadTexture("textures/hero.png"));
sheet.setGrid(8, 4, 64, 64, 0, 0);      // 对应文档的 columns/rows/frameWidth/frameHeight

local cast = anim.newSpriteClip("cast");
foreach (i, f in [8, 9, 10, 11, 12, 13, 14, 15]) cast.addFrame(f, 1.0 / 12.0);
cast.setLoop(false);
cast.addEvent(4, "release");

local player = anim.newSpriteAnim();
player.setSheet(sheet);
player.bindSprite(heroSprite);
player.play(cast);
```

`registerSkillDamage` 的 `hitChance` 是**百分数**（`examples/rpg-classic/main.nut:253-258`
用的是 100 / 95），而技能文档里 `hitChance` 是 0..1。**这两个单位不一致，是引擎现状**，
适配层必须做换算（乘 100）。这条不一致无法从 schema 层消除，写进这里以免踩坑。

### 7.5 校验

```bash
python tools/rpgc.py validate
```

期望 `PASS`，`documents` 统计里 `anim=1 effect=1 skill=1`。

故意改坏：

```text
# 把 cast 的 events[0].frame 改成 99
ERROR  .../anims/hero.json:/clips/0/events/0/frame: event frame 99 is outside the clip's 8 frame(s)
       hint: SpriteClip::addEvent indexes clip frames, not sheet frames

# 把 frames[0] 改成 40（网格只有 32 格）
ERROR  .../anims/hero.json:/clips/0/frames/0: sheet frame 40 is outside the 8x4 grid

# 把 periods 改成 duration=3, period=6
ERROR  .../effects/burn.json:/period: a periodic effect needs durationPolicy "duration"   ← 若改成 instant
WARN   .../effects/burn.json:/period: period is longer than duration: the effect expires before its first tick

# 把 segments[0].anim 改成 "wizard"
ERROR  skill/fireball references missing anim 'wizard'
       hint: define content/anims/wizard.json

# 把 segments[0].clip 改成 "cast2"（hero 里没有）
ERROR  skill/fireball references clip 'cast2' which anim/hero does not define
       hint: add the clip to the animation set or fix the name

# 把 levels 顺序颠倒（level 5 写在 level 2 前面）
ERROR  .../skills/fireball.json:/presentation/levels/1/level: level rows must be ordered ascending

# 把 formula 写成 "a.attack * 2;"
ERROR  .../skills/fireball.json:/damage/formula: formula contains ';', which the engine evaluator does not accept
```
