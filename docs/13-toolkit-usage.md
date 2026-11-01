# 工具套件使用指南

设计与能力边界见 [12-toolkit-design.md](12-toolkit-design.md)。Python 3.10+，离线工具仅用标准库；`validate`、`graph`、`simulate` 的无窗口模式需要 eve SDK，但不需要显示器或 MCP 服务。所有命令在项目根执行；全局 `--root`、`--eve` 放在子命令前。

## 查找与数据库制作

```bash
python tools/rpgc.py toolkit catalog
python tools/rpgc.py toolkit catalog --kind item --query 药
python tools/rpgc.py toolkit schema skill
python tools/rpgc.py toolkit clone content/items/potion.heal.json potion.strong --title 大还丹 > /tmp/potion.strong.json
```

支持 workflow 声明的全部内容类型（当前18类）；`catalog` 返回规范 JSON 的 SHA-256 指纹，属于编辑并发检查，不是引擎验证结果。克隆保留原有引用，不自动修正 art/skill、combo/skill 的反向关系。

将以下内容保存为 `/tmp/patch.json`：

```json
[{"op":"test","path":"/id","value":"potion.heal"},
 {"op":"replace","path":"/displayName","value":"改良金创药"}]
```

```bash
python tools/rpgc.py toolkit patch content/items/potion.heal.json /tmp/patch.json > /tmp/potion.candidate.json
# 可添加 --expect <catalog 返回的 fingerprint>，拒绝基于过期内容的修改
```

补丁支持 RFC 6902 的 add/remove/replace/test，路径使用 JSON Pointer；不支持 move/copy。操作整体成功才输出候选，输入不变。

## 地图与事件

```bash
# layer 接受文档里的唯一 id 或 name；根据 catalog/源文档选取
python tools/rpgc.py toolkit map fill content/maps/village-outskirts.json --layer terrain --x 2 --y 3 --gid 1 > /tmp/map.candidate.json
python tools/rpgc.py toolkit map resize content/maps/village-outskirts.json --width 64 --height 64 > /tmp/map.large.json
# paint 的 --cells 指向 [[2,3],[3,3]] 这样的 JSON 文件
python tools/rpgc.py toolkit event analyze content/events/mist-forest.arrival.json
python tools/rpgc.py toolkit event move content/events/mist-forest.arrival.json --index 0 --destination 1 > /tmp/event.candidate.json
# insert/replace 另传 --step /tmp/step.json；步骤示例：{"kind":"wait","duration":0.5}
```

fill 是四邻域洪水填充。resize 保留左上重叠区域，所有瓦片层同步变化；若裁切会使对象锚点出界则拒绝。它不重排 portal、自动地形或外部事件坐标。事件专用操作处理顶层步骤，嵌套步骤可使用通用 patch；analyze 递归分析全部分支。

## 本地化

```bash
python tools/rpgc.py toolkit strings extract content/party/party.default.json > /tmp/party.zh-en.json
# 编辑 translations 中的值，保留 sources 原文
python tools/rpgc.py toolkit strings apply content/party/party.default.json --catalog /tmp/party.zh-en.json > /tmp/party.en.candidate.json
```

提取 title/description/displayName/text 以及地图 speaker 属性。ID、技能名引用和外部对话 reference 不翻译；这是文档文本候选工具，不是运行时 locale 切换器。数组变化可能改变 pointer，回填会检查源文本；相同原文的不同条目不能仅靠文本判断身份，结构调整后应重新提取。

## 内容写入闭环

候选输出只是草稿。不要重定向到原文件（shell 会先截断源文件）。启动持久宿主，再走既有门：

```bash
# 终端一，保持运行
eve mcp --root . --port 19100
# 终端二，所有暂存/导出连接同一宿主
python tools/rpgc.py --port 19100 stage content/items/potion.heal.json /tmp/potion.candidate.json
python tools/rpgc.py --port 19100 export --dry-run
python tools/rpgc.py --port 19100 export
python tools/rpgc.py --port 19100 validate --json
```

无显示器环境可在隔离工作副本制作候选并用 `validate --headless` 检查；它不提供另一个绕过 stage/export 的内容写入命令。`stage` 是单文档门，跨文档正确性仍须全项目 validate；多个 export 文件不是事务。

## 权威引用、战斗模拟与验证

```bash
python tools/rpgc.py validate --headless
python tools/rpgc.py graph --headless --impact skill/skill.strike
python tools/rpgc.py simulate encounter.outskirts-night --headless --seed 42 --runs 10
python tools/rpgc.py toolkit balance
```

可用全局 `--eve /path/to/eve` 指定 SDK。省略 `--headless` 则复用 MCP 路径；`--port` 可连接现有宿主。headless 的临时脚本在项目根创建并在 finally 清理，默认进程超时 120 秒；可传 `--timeout` 调整。

- graph 直接使用各模块的 `references()`，返回节点、带字段路径的边和反向传递影响；它不是合法性校验。未知节点拒绝查询。
- simulate 使用 `RpgcBattle.loadProject/newFight/runToEnd/settlement`，每次种子为 seed+i，输出战斗快照、日志和结算。相同内容与种子可重现；它不是玩家策略强度评估，也不替代全项目门。最多 100 次，每次默认 512 条命令；预算耗尽 stalled 退出非零。
- balance 只汇总 authored HP/attack、人数与奖励，不声称模拟胜率。
- validate --headless 调用原有 `RpgcValidate.validateProject()`，始终输出 JSON。崩溃/超时/缺失结果均失败，不能把 eve 的零退出码单独当作成功。

## 资源与分发

```bash
python tools/rpgc.py toolkit doctor
python tools/rpgc.py toolkit assets
python tools/rpgc.py toolkit bundle /tmp/rpg-classic-source.zip
python tools/rpgc.py toolkit verify-bundle /tmp/rpg-classic-source.zip
```

doctor 检查内容能否严格读取与资源 readiness，不启动引擎。assets 检查 tileset/anim 图片、battle 背景，输出文件大小与 SHA-256；PNG 仅读 IHDR 元数据，不保证整个图像可解码。

bundle 是源码分发，不包含 eve，不是可执行游戏；`validated:false` 明确表示包本身未触发引擎门。发布前分别跑 validate、assets 和投影新鲜度检查。输出只能位于项目外或顶层 dist/build，目标目录须存在，已有文件拒绝覆盖。归档固定路径顺序、时间和权限，忽略源码管理/缓存/派生目录。verify-bundle 校验包内清单与成员的一致性；这是完整性检查，不是数字签名或来源认证。

## Python 复用与自动化

```python
# PYTHONPATH=tools python your_script.py
from rpgc_toolkit.project import Project, patch_document
from rpgc_toolkit.authoring import fill_map, apply_strings
from rpgc_toolkit.assets import audit_assets
from rpgc_toolkit.build import build_bundle

project = Project('.')
rows = project.catalog(kind='item')['documents']
```

```bash
make toolkit-test
# 可选真实 VM 集成测试（引用图和相同种子重放）
RPGC_TEST_EVE=/path/to/eve python -m unittest discover -s tests -v
python tools/build_encounters.py --check
```

离线 CI 不把缺 SDK 当作内容通过；真实 VM 用例未配置时显式 skip。

## 剧情图和任务阶段编译

```bash
python tools/rpgc.py toolkit story examples/toolkit/story.graph.json > /tmp/story.toolkit-greeting.json
python tools/rpgc.py toolkit quest examples/toolkit/quest.plan.json > /tmp/quest-candidates.json
```

story 的 `rpgc.story-graph/1` 使用 `entry` 和节点列表。节点为 `{id,action,next?}`、`{id,condition,then,else}` 或 `{id,end:true}`；action 是现有事件步骤。编译器拒绝环、悬空边、不可达节点，限制为当前目标支持的一层分支容器及展开预算；action 必须是平坦步骤，输出一个现有 event 文档。分支后共享节点会在不同分支中展开；不生成新的运行时解释器。

quest 的 `rpgc.quest-plan/1` 将有序 stages 转为多个 event 候选。每阶段要求 `id/trigger/steps`，可提供 `condition`；为适配事件的一层容器限制，条件与进度守卫通过每次重置的 eligibility 计数器组合，阶段 steps 必须平坦，`quest.<id>.*` 命名空间由编译器保留。编译结果包含 `events` 和用于进度的 `quest.<id>.stage` 变量。步骤成功路径末尾才推进变量，状态守卫避免重复领赏；相同非 manual 触发器和无关触发字段被拒绝，防止同次分发连跳阶段。manual 由调用方按事件 ID 发起。现有游戏入口现在通过 workflow 索引加载全部 event 文档，不再限定两份示例文件；任务计划本身不是运行时内容，需将输出 events 分别走内容门；与项目已有事件的触发冲突仍需集成检查。

这是世界变量/事件适配，不会注册引擎 QuestDefinition；`quest.bounty` 等既有外部注册 warning 仍保留。当前游戏对 dialogue/message 主要显示 reference 字符串；图编译器不冒充多选项对话 UI 或外部本地化数据库。

## 多文档候选与重命名

`rpgc.change-set/1` 可将所有相关变更一起放到临时项目中，运行完整权威门。原始内容不改，临时目录退出即删除。文件只允许命中 workflow 的内容目录。

```json
{
  "format": "rpgc.change-set",
  "version": 1,
  "changes": [
    {"path": "content/events/story.toolkit-greeting.json", "source": "/tmp/story.toolkit-greeting.json", "expect": null}
  ],
  "deletions": []
}
```

```bash
# 保存以上内容为 /tmp/changes.json
python tools/rpgc.py check-changes /tmp/changes.json
# 权威图只跟踪内容引用，不扫描脚本里的任意字符串
python tools/rpgc.py graph --headless > /tmp/graph.json
python tools/rpgc.py toolkit rename item potion.heal potion.renew --graph /tmp/graph.json > /tmp/rename.json
python tools/rpgc.py check-changes /tmp/rename.json
```

change 支持 `source` 或内联 `document` 二选一。source 相对 change-set 文件目录；`expect` 为现存文档指纹，显式 null 表示目标不得存在。deletions 只在临时副本删除。rename 从引用图更新精确 ID/文档相对路径引用，合并一个文档内多个引用，生成带前置指纹的 change-set；无法定位的引用拒绝猜测。

check-changes 只验证该输入快照，不执行提交，也不锁住正在编辑的原项目。它复制 lib/schema/data 与清单内容目录，不执行资源完整性或外部脚本字符串引用审计。实际集成仍需按既有写入路径或受版本控制的工作副本操作；不要把验证成功理解为跨文件原子提交。

## 背包存档迁移与恢复检查

```bash
python tools/rpgc.py toolkit migrate-save examples/toolkit/inventory.snapshot.json examples/toolkit/inventory.mapping.json > /tmp/inventory.migrated.json
python tools/rpgc.py check-save /tmp/inventory.migrated.json
```

映射格式 `{items:{旧ID:新ID},slots:{旧槽:新槽}}`，只产生候选，不覆盖玩家存档。支持当前 `eve.rpgc.items.snapshot/1`，保留栈、数量和槽位，拒绝重复槽、碰撞、过期指纹和未知版本。数量限制在 VM 精确整数范围 `1..16777216`；迁移不自动合并超堆叠的物品。check-save 调用真实 `RpgcItems.restore/snapshot`，核心字段发生数值/物品损失时失败，扩展字段未持久化单独警告。它不迁移世界/任务/完整游戏存档，也不是新的运行时版本兼容层。

## 战斗录制与回放

```bash
python tools/rpgc.py record encounter.outskirts-night --seed 42 > /tmp/battle.record.json
python tools/rpgc.py replay /tmp/battle.record.json > /tmp/battle.replay.json
```

record 使用真实 AI 生成玩家侧命令，记录初始事件、每一步命令/事件/状态、最终结算及 SHA-256。replay 接受录制报告或其中的 tape，逐步核对 expected 指纹。tape 使用 `rpgc.battle-tape/1`，命令为 `{actor,skill,target}`；可以编辑成测试场景，但修改后须有意识地更新预期基线。错误角色、非法技能/目标、预算耗尽、漏命令和结束后多余命令均失败。

当前 tape 覆盖战斗技能/防御命令，不包括物品指令、实时 UI 输入或完整世界操作。命令数量默认上限 512，可用 `--max-orders` 调整；这些命令与 check-changes/check-save 均直接使用无窗口 VM，支持全局 `--eve` 与 `--timeout`。

## 精灵导入和音频处理

```bash
# clips.json 是 [{"id":"idle","frames":[0,1,2,3],"fps":8,"loop":true}] 这样的数组
python tools/rpgc.py toolkit import-animation /tmp/hero.png hero.new --image-reference hero.new.png --frame-width 32 --frame-height 48 --clips /tmp/clips.json > /tmp/hero.new.json
python tools/rpgc.py toolkit audio inspect /tmp/music.wav
python tools/rpgc.py toolkit audio trim /tmp/music.wav --start 0 --end 44100 --output /tmp/music.first.wav
```

动画候选根据实际 PNG 尺寸、margin/spacing 推导完整网格，保留命名片段和事件，仍须通过原有 schema/语义门；不复制或重绘源图片。`image-reference` 是目标动画文档相对路径，需要调用方将实际资源安置在那里。

音频支持无压缩 PCM WAV 8/16/24/32 位；start/end 是采样帧，不是字节或毫秒，区间为 `[start,end)`。裁剪保留采样率/声道/位深，拒绝截断文件和覆盖，只输出到项目外或顶层 dist/build。WAV 附加元数据不复制；不做重采样或 MP3/OGG 转码。

## 使用本地 SDK 发布

```bash
python tools/rpgc.py toolkit package /tmp/rpg-release --sdk /path/to/eve-sdk/linux --platform linux
python tools/rpgc.py toolkit verify-package /tmp/rpg-release
# Linux/macOS：发行目录中的 launch.sh；Windows：launch.cmd
```

支持 linux/macos/windows 启动器模板，SDK 分别需要 `bin/eve` 或 `bin/eve.exe`。生成 `game/` 源码、`engine/` 完整 SDK、启动器和 `RPGC-PACKAGE.json` 哈希清单；输出目录不得已存在，最后通过原子排他重命名发布，失败清理暂存目录。输入树拒绝符号链接，目标只能在项目外或顶层 dist/build，且不能与 SDK 重叠。

工具不下载 SDK，不替换系统动态库，也不交叉编译或验证可执行文件架构。platform 必须与用户提供的 SDK 对应。包标记 `validated:false` / `osDependenciesBundled:false`；发布前另跑内容/资源检查，目标系统仍须具备 SDK 所需原生依赖。verify-package 是发布前封装完整性检查，不是签名或运行测试；启动游戏后新增日志/存档会改变文件集合。

当前游戏适配器同时补齐 always、ne 和 object_consumed 条件处理；真实适配函数测试验证了任务未接取/条件未满足不奖励，满足后只奖励一次。moment 条件与完整时间系统、game_started/map_entered/quest_completed 的自动分发仍需应用自行连接；这些不是编译器新增的运行时能力。

## 开发资源与无窗口模块回归

```bash
python tools/build_placeholder_anims.py          # 确定性重建五张程序化开发图
python tools/build_placeholder_anims.py --check  # 只检查生成物新鲜度
python tools/rpgc.py toolkit assets
python tools/rpgc.py selftest --headless
```

hero/blade/palm/fireball/thunder 的开发图匹配现有动画网格与片段，透明背景、帧间动作可辨；它们是项目原创程序化占位素材，随仓库 MIT 授权，不是正式角色美术或八方向动画。补齐文件不会自动增加游戏适配器的动画播放能力。

`selftest --headless` 运行 `tools/modules_check.nut`，输出 JSON，默认180秒超时。脚本断言失败、无最终 PASS、重复摘要或原生进程异常都返回非零。它覆盖库/内容/编辑器静态探针；原有不带 --headless 的 selftest 继续检查活 MCP 宿主与编辑器调用，不以无窗口检查冒充交互端到端测试。

## 自动地形、表格调参与发布预检

```bash
python tools/rpgc.py toolkit terrain content/maps/village-outskirts.json --layer terrain --cells /tmp/cells.json --rules /tmp/terrain-rules.json --seed 42 > /tmp/map.autotile.json
# 擦除同一地形：另传 --erase
python tools/rpgc.py toolkit database export enemy --fields /displayName /combat/attack /combat/maxHp > /tmp/enemies.csv
# 在表格软件中修改数据，保留 _path/_id/_fingerprint 三列
python tools/rpgc.py toolkit database import enemy --source /tmp/enemies.csv > /tmp/enemy-changes.json
python tools/rpgc.py check-changes /tmp/enemy-changes.json
python tools/rpgc.py toolkit preflight --profile quick
python tools/rpgc.py --eve /path/to/eve toolkit preflight --profile release
python tools/rpgc.py --eve /path/to/eve toolkit preflight --profile-file /tmp/team-profile.json
```

terrain的cells为`[[x,y],...]`；完整16项规则示例见 [terrain.rules.json](../examples/toolkit/terrain.rules.json)，严格发布profile示例见 [release.profile.json](../examples/toolkit/release.profile.json)。规则示例展示mask→GID映射，**并不承诺现有图集1..16号图块就是一套地形边缘素材**；使用前按实际图集配置。mask bit为N=1/E=2/S=4/W=8，map外视为空；变体列表按seed和坐标稳定选择。绘制只允许空白或该地形，擦除也只允许该地形，保护其它瓦片；操作只重连修改格及四邻格。候选仍须引擎门验证GID与图层规则。

CSV列使用JSON Pointer，数据单元格使用JSON字面量：数字`12`、布尔`true`、字符串`"血蝠"`、空字符串`""`、null为`null`；真正空单元格表示保留当前字段。导出的CSV文本有CSV转义层，表格软件打开后才看到数据单元格，不要手工删除JSON引号。UTF-8 BOM可接受。导入只生成change-set，禁止修改id/schema/version；无修改时输出空changes，可用check-changes验证当前项目。

自定义profile示例：

```json
{"version":1,"id":"team","checks":[{"id":"engine","required":true,"timeoutSeconds":120},{"id":"assets","required":true,"timeoutSeconds":30},{"id":"modules","required":true,"timeoutSeconds":180}]}
```

quick检查资源和两类生成物；release要求引擎门、资源、开发动画新鲜度、遭遇投影新鲜度，并执行可选模块套件。自定义profile可将modules设为必需；release保留必需检查，不能通过配置取消。status为pass/fail/skipped，缺SDK只允许可选项skip，必需项失败。可选项fail不阻止聚合ok，因此消费者也应检查逐项结果。对比与优先级见 [主流引擎工作流对照](14-engine-comparison.md)。

## 共享剧情运行时与对话预览

`lib/rpgc_world_state.nut`、`lib/rpgc_event_runner.nut`、`lib/rpgc_dialogue.nut` 和 `lib/rpgc_quests.nut` 可分别导入。游戏与无窗口工具共用规则；Python 只负责输入与运行编排。

```bash
# 真实 SDK 能力操作探针，不代表窗口/音频已验证
python tools/rpgc.py --eve /path/to/eve capabilities
# 运行固定的世界状态、事件、对话、任务探针
python tools/rpgc.py --eve /path/to/eve world-checks
# 查看首个对话节点
python tools/rpgc.py --eve /path/to/eve dialogue dialogue.toolkit-guide --locale en
# 在真实 VM 中执行推进、选择、结束，输出文本轨迹及最终世界状态
python tools/rpgc.py --eve /path/to/eve dialogue dialogue.toolkit-guide \
  --actions examples/toolkit/dialogue.actions.json
```

对话 `--actions` 接受 `advance`、`choose`（`optionId`）、`cancel`、`locale`（`locale`）。`advance/choose` 可指定 `revision` 验证过期提交；省略时使用最新视图。`--state` 读取初始世界状态对象。预览不修改项目内容，不保存玩家存档；失败返回非零退出码及已提交状态，不能假设整段对话回滚。

`dialogue` 和 `quest` 已纳入 workflow、严格 schema、语义校验与引用图。删除被事件引用的对话会被 `check-changes` 阻止。严格发布示例 profile 新增必需的 `world-runtime` 检查，崩溃、空报告、重复结果或失败探针都不能通过。

任务通过 `activate/consume/claim` 区分接取、目标完成和领奖。目标消费统一 domainEvents；奖励批次调用共享状态与已有库存规则，背包满时保留 completed 状态并拒绝整批奖励。重复领取不会再次发放。定义发生变化后旧进度拒绝直接套用，须显式迁移；世界存档与显式迁移见下节，战斗及演出中途续接尚未实现。

主游戏操作：`T`访问向导，空格/Enter推进文本，数字键选择，`L`在中英文间切换，Esc取消当前演出。接取后打开村外 `old_chest`，再按 `T`领取5金币与1份金创药；先开箱后接取也可完成目标。箱子自身的物品、金币与消耗标记一起提交，容量不足时不消耗箱子。

首版边界：`move_actor`尚未提供游戏适配，会明确拒绝；现有镜头与精灵剪辑已接宿主确认，循环剪辑在启动后确认、由后续剪辑替换。任务每批最多256个事件、128个定义，去重日志最多16384条，达到上限会拒绝继续而非丢弃历史；日志压缩仍未实现；世界存档见下节。地图中其它尚无对话/物品定义的旧占位引用会报告缺失，不能视为已完成全部剧情内容。

### 真实窗口烟测

`tools/gameplay_smoke.py` 驱动真实地图、镜头、动画和游戏对话/任务函数，输出逐项JSON结果。它会修改游戏会话、开箱和领奖，**仅对全新的一次性项目副本运行**：在副本的 `config.nut` 设置 `hotReload=false`，启动 `eve run --mcp-port 19652 .`，再运行：

```bash
python tools/gameplay_smoke.py --port 19652 --timeout 30
```

可选 `--screenshot /absolute/path/gameplay.png` 在引擎宿主保存画面。MCP与脚本必须指向同一测试实例。该验证调用游戏函数，覆盖真实渲染及平台适配，不模拟操作系统键盘，也不代表Windows/macOS或音频播放已验证。

## 世界存档与内容迁移

主游戏 **F5** 请求保存、**F9** 在安全点读取槽1。保存涵盖当前地图/位置/朝向、金币、变量/开关、消耗对象、任务计数和领奖状态、完成事件、去重日志、库存装备、队伍定义ID、语言和输入序号。当前游戏没有跨战斗保留的成员HP/等级或世界随机流，格式不虚构这些状态。战斗、对话、事件、未确认切图或未消费领域事件期间，F5返回 `deferred` 并在下一安全点处理；F9拒绝忙碌期间替换世界。不支持战斗或演出中途续接。

`RpgcSave` 是可单独导入的纯快照校验/恢复模块；`RpgcSaveStore` 是显式调用才启用的原生持久化适配。文件放在 `eve.Filesystem().getSaveDirectory()` 对应的 `rpg-classic-player-v1` 用户目录中：`player-slot1.json` 和 `.backup`。不会写进项目内容目录。原子写入接口不可用时明确失败，无普通写入降级；主档无效时尝试上一代有效备份，不自动覆盖损坏文件。恢复先检查候选，真实地图和落点加载成功后才替换当前状态；失败保留当前世界及原存档。

```bash
# 当前内容版本清单（canonical JSON 的 Adler-32，不是发布签名）
python tools/rpgc.py world-save manifest
# 从明确的世界上下文及库存v1生成快照；不猜测玩家位置
python tools/rpgc.py world-save capture examples/toolkit/world.capture.json --output /tmp/new-world.json
python tools/rpgc.py world-save check /tmp/new-world.json
# 旧库存导入：context包含world/partyId/locale/inputSequence，不包含inventory
python tools/rpgc.py world-save import-inventory old-inventory.json --context world-context.json --output /tmp/imported-world.json
# 默认只预览；--output仅允许创建新文件，不覆盖历史档
python tools/rpgc.py world-save migrate old-world.json migration-plan.json
python tools/rpgc.py world-save migrate old-world.json migration-plan.json --output /tmp/migrated-world.json
```

这些命令通过同一个真实VM模块验证；可按其它命令方式指定全局 `--eve /path/to/eve`。`capture/migrate/import-inventory` 的成功结果在 `value.snapshot` 中，状态为 `ready` 才能输出文件；`deferred` 不产生快照。CLI不应用玩家状态，也不运行地图表现端，因此 `nativePlacementValidated:false`；真实游戏读档还会检查实际可行走落点。校验和用于发现意外损坏，不用于防作弊或身份认证。

迁移计划固定为 `{"format":"rpgc.world-migration-plan","version":1,"steps":[...]}`。每步含唯一 `id`、完整 `fromContent` 和 `toContent` 清单，可选 `maps/items/events/objects` 显式ID映射；`objects` 使用 `mapId/objectName`。源清单从旧快照取，目标清单由 `world-save manifest` 获取。步骤必须连续，缺中间版本、回到旧版本、身份冲突和未知字段会被拒绝。映射只改变明确的身份引用，不合并物品数量，不修改历史命令/事件日志，不丢弃任务状态。已保存任务的定义若改变，需专用任务迁移适配，首版明确拒绝自动处理；未知未来快照格式也拒绝读取。

格式为 `eve.rpgc.world.snapshot/1`，顶层包含gameId、content、payload和Adler-32校验和。内容改变后必须显式迁移，即使只改文本也不会直接套用旧档。原生原子替换和进程重启恢复经过实际检查，未做断电故障注入或跨平台持久性认证。


复跑跨进程存档烟测（需要可用窗口与 Vulkan 环境）：

```bash
python tools/save_gameplay_smoke.py --eve /path/to/eve --project /path/to/disposable-copy --data-home /tmp/empty-save-test --screenshot /tmp/save-test.png
```

使用 `hotReload=false` 的一次性项目副本，以及空的独立 `--data-home`；脚本负责启动、停止并重启两个引擎进程。通过 MCP 调用与 F5/F9 相同的游戏处理函数，验证真实磁盘和地图恢复，不模拟操作系统按键。本轮 Linux 验收报告位于 `build/verification/w3/gameplay-smoke.json`。

## W4 地图制作、模板和原生 QA

### 八邻域与双地形

旧 `rpgc.terrain-rules/1` 的16-mask与seed行为保持不变。v2的 `mode:"blob8"` 使用47种归一化mask：N/E/S/W=1/2/4/8，NE/SE/SW/NW=16/32/64/128；对角只有两条相邻正交边都连接时才有效。必须提供全部47项，缺项不自动选择替代图块。这不是RPG Maker的48子图块拼接格式。

`mode:"transition8"` 明确声明两个terrain及高→低 `priority`，使用 `--terrain-id` 选择材质。高优先可覆盖低优先，反向覆盖拒绝；擦除选中材质恢复低优先材质。受影响区域及读取邻域必须只有这两种材质，空白或第三材质报错；地图外延续当前材质。两侧边缘都会重新连接。示例规则仅演示协议，不附带专用过渡美术。

```bash
python tools/rpgc.py toolkit terrain content/maps/village-outskirts.json --layer terrain --cells examples/toolkit/terrain.blob8.cells.json --rules examples/toolkit/terrain.blob8.json --seed 42 --change-set > /tmp/terrain-report.json
```

默认仍输出普通地图候选；`--change-set` 输出带源指纹的 `changeSet`、实际变化格数和包围范围。提取 `changeSet` 后使用 `check-changes` 或 `map-qa --changes` 验证，再走既有stage/export流程；本工具不覆盖地图。

### 数据库模板与地图对象组

```bash
python tools/rpgc.py toolkit template expand examples/templates/expand.request.json > /tmp/template-report.json
python tools/rpgc.py toolkit template check /tmp/template-report.json
python tools/rpgc.py toolkit template objects examples/templates/objects.request.json > /tmp/object-report.json
python tools/rpgc.py toolkit template check /tmp/object-report.json
```

数据库模板首版支持item/enemy/skill/effect/party整文档，使用单继承、带类型参数、显式引用重写和允许覆盖的JSON Pointer。展开报告包含普通候选、源指纹及实例sidecar。接受候选后，调用者保存相应sidecar；不要在候选尚未接受时把新sidecar当成实例当前版本。

`template update request.json` 请求为 `{templates:[...],instances:[{path,sidecar},...]}`，读取实际实例文件，对旧base、新base、手工实例做三方比较。只合并互不冲突的变化，数组按整体比较；冲突报告保留三方值，`template check` 会拒绝整份有冲突报告。调用者须传入完整sidecar清单，工具不会声称自动发现未登记实例。

地图对象组使用独立 `rpgc.object-group-template/1`，显式声明 `coordinateSpace:"world"`、完整且唯一的名称映射和world-space偏移。只重写声明的对象名称引用，不猜测字符串含义，不在Python复制等距投影；重复名称、非有限坐标和未知字段拒绝。

对象组升级入口为 `python tools/rpgc.py toolkit template objects-update request.json`。请求包含 `templates`（新版模板）、`instances`（调用者登记的实例清单），可附加 `previousTemplates`（原版模板）。每个实例记录包含 `path`、`sidecar`，可显式提供新的 `nameMap`、`worldOffset` 和 `renames`。`renames` 将旧模板中的对象名映射到新版对象名；新增对象必须提供名称映射，不猜测改名关系。

旧版 `rpgc.object-group-instance/1` 侧车只有静态来源记录，升级时必须提供与其模板指纹匹配的原模板，重新展开并核对基线。新版侧车保存基线摘要，供后续更新核对内部一致性；摘要不代表签名或可信来源认证。

更新按旧模板展开值、新模板展开值和地图当前对象三方比较。对象按稳定名称匹配，`properties` 按属性名合并，其他数组整体比较。模板改金币、作者改坐标可同时保留；双方改同一字段、模板删除已手改对象等情况返回具体冲突及三方值。地图上不属于实例的对象保留。同一地图的多个实例合成一份带源指纹的候选；其中任一实例冲突，该整张地图都不进入 `changeSet`，`template check` 也拒绝整份冲突报告。

这些命令只生成候选。无冲突报告仍需 `template check` 的隔离全量校验；只有实际接受候选后才能保存对应新侧车作为下次更新基线。事件片段模板仍未实现。

对象属性的冲突路径采用 `/properties/属性名/value` 等稳定语义路径，不能直接作为原地图属性数组的 JSON Patch 索引。模板内容变化必须提高 `revision`。对象在地图中的名称是实例匹配依据；不要在工具外改名后期待自动识别，改名应通过显式映射生成候选。工具不自动重写其他对象或事件中未声明的外部引用。

可运行的更新示例会在新的输出目录建立项目副本，放入同一模板的两个实例，并手工移动其中一个宝箱。正常更新调整金币、删除旧对象并增加新对象；冲突更新同时修改作者移动过的坐标。原工程不变：

```bash
python examples/object-group-update/generate.py --eve /path/to/eve --output /tmp/rpgc-group-demo
python tools/rpgc.py --root /tmp/rpgc-group-demo/sandbox toolkit template objects-update /tmp/rpgc-group-demo/clean.request.json > /tmp/group-clean.json
python tools/rpgc.py --eve /path/to/eve --root /tmp/rpgc-group-demo/sandbox toolkit template check /tmp/group-clean.json
# 预期退出码 1：同字段冲突，该地图的 changeSet 为空。
python tools/rpgc.py --root /tmp/rpgc-group-demo/sandbox toolkit template objects-update /tmp/rpgc-group-demo/conflict.request.json
# 在原工程中查看整个示例的最终候选，包括初始实例和升级结果。
python tools/rpgc.py --eve /path/to/eve preview map village-outskirts --changes /tmp/rpgc-group-demo/root.change-set.json --window
```

可导入接口位于 `tools/rpgc_toolkit/templates.py`：`expand_template`、`plan_instances`、`update_instances`、`instantiate_object_group`、`update_object_groups`、`check_templates`。

### 原生地图 QA 与独立窗口预览

```bash
python tools/rpgc.py map-qa
python tools/rpgc.py map-qa village-outskirts
python tools/rpgc.py map-qa village-outskirts --changes /tmp/map.changes.json
python tools/rpgc.py preview map village-outskirts
python tools/rpgc.py preview map village-outskirts --screenshot /tmp/new-map-preview.png --timeout 120
```

`RpgcNavigation` 是游戏和工具共用的导航／图层适配器。`RpgcMapQA.inspect(id)` 与 `auditProject(id)` 调用原生地图加载器、Pathfinder和正反坐标转换，检查出生点、交互点、传送落点及结构图；未知地图或原生失败返回失败诊断。传送落点须与目标地图spawn连通，不能把“可站立但困在孤岛”的落点计为可用传送。NPC／箱子的可达范围与游戏一致（Chebyshev距离1）；portal要求到达所在格。

地图对象按当前游戏的点锚检查，同格重叠产生warning；尚未实现面积footprint碰撞体检查。结构图不执行剧情、时刻条件或事件转移，报告明确 `stateConditions:false`、`objectFootprints:false`，不代表所有剧情状态可达。

无 `--screenshot` 只输出数据报告，标记 `rendered:false`。截图模式复制输入到一次性项目，启动单用途原生窗口、绘制地图、等待真实帧回读并保存新PNG，随后停止其进程；无需主游戏运行，不写玩家存档，也不覆盖已有PNG。缺窗口／Vulkan会失败，不生成占位截图。预览为1280×720、全图取景与中性照明，共用游戏2倍图层视觉缩放；不会复现游戏HUD与剧情表现。

报告附带内容、图集图片、schema、共享模块和对象契约的SHA-256清单及SDK摘要；检查期间输入改变会失败。该清单是本次地图检查输入证据，不是W7完整平台发布证明。严格发布profile现已包含必需的 `map-qa` 检查。

本轮最终验收：147项测试通过；严格发布预检7项全部通过。原生QA覆盖14张地图、8024格坐标拾取、97个对象和26条传送边。独立地图窗口截图通过；共用导航改动后的游戏跨进程存读档15项窗口检查通过（MCP调用游戏处理函数，非OS按键注入）。证据位于 `build/verification/w4/summary.json`，截图为 `preview-final.png`，平台仅Linux/Xvfb/Mesa llvmpipe。


## 独立地图检查窗口与候选对比

地图截图入口现在默认带检查面板。`--window` 保持窗口打开，关闭窗口后结束；`--screenshot NEW.png` 自动捕获并结束；`--plain` 保留纯地图画面。未指定窗口／截图时仍只输出数据 QA。

```bash
python tools/rpgc.py preview map village-outskirts --window
python examples/map-inspector/generate.py --eve /path/to/eve --output /tmp/new-map-demo
python tools/rpgc.py preview map village-outskirts --window --changes /tmp/new-map-demo/good.change-set.json
python tools/rpgc.py preview map village-outskirts --changes /tmp/new-map-demo/good.change-set.json --actions examples/map-inspector/select-object.actions.json --screenshot /tmp/new-candidate.png
python tools/rpgc.py preview map village-outskirts --changes /tmp/new-map-demo/bad-landing.change-set.json --actions examples/map-inspector/diagnostic.actions.json --screenshot /tmp/new-diagnostic.png
```

面板提供阻挡（B）、对象（O）和候选差异（D）的显示切换、缩放和适配视图（R）。点击地图格子查看坐标、GID、可走状态及修改前后值；点击对象列表选择对象并查看传送目标。方向键平移视图。诊断按钮会定位当前地图的相关对象；其他地图或全图级诊断仍保留文字，不能伪造对象落点。

`--changes` 使用既有rpgc.change-set，包括源指纹检查，在隔离副本中全量验证后加载。报告记录source/candidate摘要、按格坐标比较的图层差异及按名称比较的对象差异；resize不会按数组平移误报。没有修改的原始地图也可以用同一面板检查。窗口是只读检查器，不直接绘制、导出或覆盖地图；候选应用仍走原有验证、stage/export流程。

结构／引用门失败时不启动窗口。结构合法、可原生加载但QA不通过（例如传送落点被阻挡）时仍渲染地图和诊断，报告 `ok:false, rendered:true`，CLI退出码1；生成截图不代表QA通过。示例坏落点专门验证这条路径，不会修改项目中的传送点。

演示生成器调用真实SDK读取可通行图块元数据和等距坐标，重涂3×3沙地区域并重算邻接格，再以对象模板加入传送点。最终变化格数以diff报告为准（邻接重算可能增加变化格）。示例使用现有纹理，不声称附带47方向专用过渡美术。输出目录必须是新的，不能指向原内容目录。

`--actions` 接受至多64项 `{action,arg?}`：`blocked/objects/changes/fit/zoom-in/zoom-out/select-object/select-cell/diagnostic`。索引动作参数为非负整数；select-cell是 `y*width+x`。这些动作走与面板相同的处理函数并记录前后状态，适合复现截图，不是任意脚本入口。

实际窗口回归可用 `python tools/map_inspector_window_smoke.py --eve /path/to/eve`，需要可用显示与Vulkan。脚本检查retained UI按钮事件、窗口长驻及native关闭后的进程清理；不声称操作系统鼠标按键注入。验证结果与截图存于 `build/verification/inspector/`。

检查器最终验收：158项测试、7项发布预检和13项真实窗口检查全部通过。UI检查通过 `eve_ui_click` 触发实际retained控件事件；选格另测共享handler。关闭检查等待SDK启动保护期结束，发送平台quit事件并确认进程／端口关闭，不将单独销毁native窗口当作退出循环。正常候选实际变化13格、1对象；错误候选仍显示地图并正确标记QA失败。汇总：`build/verification/inspector/summary.json`。
