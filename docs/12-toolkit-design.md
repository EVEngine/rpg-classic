# 可复用 RPG 开发工具套件

## 目标与边界

让人、脚本、AI 和任意编辑器使用同一套制作能力：项目检索 → 候选编辑 → 引擎校验 → 暂存与导出 → 测试 → 分发。借鉴 RPG Maker 的数据库、地图和事件工作流，以及 GameMaker 的资源组织、自动化构建与调试能力，不复制 UI，不强制整合 IDE。

当前已有 16 类内容、五个编辑器、Squirrel 运行时、schema 与跨文档校验。本次以这些契约为基础交付标准库 Python 包 `tools/rpgc_toolkit`，通过现有 `rpgc.py toolkit` 提供 JSON CLI。Python 不复述 Eve Schema 或战斗公式。

## 能力对照与交付层次

| 工作流 | 既有基础 | 本次实现 | 后续扩展边界 |
|---|---|---|---|
| 项目/数据库 | workflow 的 16 类内容 | 分类检索、schema 查询、克隆、JSON Pointer 补丁、版本指纹 | 通用数据库 UI 由调用方实现 |
| 地图/房间 | 等距图层、对象、地形契约 | 指定格绘制、洪水填充、尺寸变更候选 | 自动地形笔刷、其他投影与 Tiled 全格式导入未承诺 |
| 事件/演出 | 13 种步骤、分支、并行 | 步骤插入/替换/删除/移动、变量及引用摘要 | 剧情DAG/任务阶段编译至现有事件；不引入另一套解释器 |
| 角色/职业/物品/技能/敌人 | party/art/heart/item/skill/enemy | 同一数据库候选操作，遭遇数值汇总 | 不用简化公式冒充真实战斗模拟 |
| 引用与重构 | 各 Squirrel 模块 references() | 权威引用图、反向影响查询 | 图驱动的重命名候选、隔离副本全量验证；不自动跨文档提交 |
| 精灵/动画/音画资源 | anim、tileset、battle | 资源存在性、PNG 尺寸、哈希清单 | PNG 网格动画导入、PCM WAV检查/帧裁剪；压缩转码和图集压缩仍用专业工具 |
| 本地化 | 文档文本与外部 reference | 明确文本字段提取、带源文本检查的翻译候选 | 外部 dialogue/message reference 对应文本不在内容树内，不能猜测翻译 |
| 调试/测试 | engine script、selftest、模块探针 | 无引擎单元测试、doctor、无窗口校验、固定种子真实战斗模拟 | 技能命令录制/回放与背包存档恢复检查均调用真实 VM |
| 构建/分发 | encounter 投影、tileset baker | 可复现源码 ZIP、逐文件哈希校验 | 用户提供SDK的三平台发布目录与启动器；不交叉编译、不包办OS依赖 |
| 扩展 | Squirrel 模块、独立 apps | 可直接 import 的 Python 函数和 CLI | 新内容类型必须同时提供 schema/语义/运行时适配 |

## 架构

1. `project.py`：严格 JSON、清单驱动的内容索引、路径边界、指纹、通用补丁和遭遇报表。
2. `authoring.py`：纯函数地图/事件/本地化变换；深拷贝输入，只返回候选。
3. `assets.py`：检查真实文件与图片元数据，不重复内容语义校验。
4. `build.py`：确定性源码归档与完整性校验，构建物明确标为未经引擎验证。
5. `cli.py`：参数和 JSON 输出；离线命令不发现/启动 eve。
6. `runtime.py` / `rpgc.py graph`：直接调用 VM 的 references()；simulate 调用真实 RpgcBattle；无窗口适配器支持 validate/graph/simulate，避免 Python 维护第二份引用字段表或战斗公式。

Python API 是复用边界；CLI 是其适配器。命令始终提供机器可读 JSON；失败退出非零，结构化诊断包含 code/path/message。索引与资产报告不等于内容合法性证明。

## 写入与并发约束

所有内容制作命令默认只向 stdout 输出候选 JSON，可重定向到项目外临时文件。它们不会直接修改 content。通用补丁可带 `--expect` SHA-256 做乐观并发检查，补丁 `test` 操作支持字段级前置条件。候选仍须使用原有 `stage` / `export` 及全项目 `validate`。现有 stage/export 属于宿主会话，跨命令必须通过相同 `--port` 连接活宿主；自动启动的短命宿主不适合跨命令暂存。

不声称多文档事务：现有 export 是逐文件原子替换。涉及双向引用的变更应在隔离副本/分支完成，并跑全量门后合入。新工具不静默覆盖用户文件，不执行来自内容文档的 shell，也不绕过路径边界。

## 可复现与测试

源码包使用排序路径、固定 ZIP 时间、固定权限与逐文件 SHA-256 清单；拒绝输出覆盖与危险路径，不包含引擎二进制。输出限定为项目外或顶层 dist/build，避免历史包递归入包。校验清单检查丢失/额外/篡改成员。测试覆盖候选不污染输入、坐标边界、数组补丁、翻译源冲突、路径逃逸、资源尺寸、归档确定性与篡改。仓库 CI 执行 Python 测试；真实引擎检查单独报告，环境失败不能记作 PASS。

## 演进路径

第二阶段已提供上述方向的独立适配器，范围见下节。后续仍可扩展交互式多选项对话、完整世界存档版本链、物品指令/世界输入回放、自动地形和专业媒体压缩；这些需要进一步的运行时消费契约，不宣称已经复制两款商业引擎全部能力。

## 本次验收记录（2026-10-29）

- Python 33 项测试全部通过，包含启用 `RPGC_TEST_EVE` 的真实 VM 引用图与双次相同种子战斗重现；普通无 SDK 的 CI 会显式跳过该集成用例。
- `validate --headless` 调用全项目权威门得到 `ok:true`；保留既有 `systems.encounter-quest-unregistered` warning（quest.bounty / quest.main.boneseal 的注册不在此工具链内）。
- 真实引用图读取 151 个节点与 383 条边；真实 `RpgcBattle` 以 seed 42/43 完成村郊遭遇模拟。
- `build_encounters.py --check` 通过（14 场遭遇，43 名投影成员）；Python 编译和 diff 空白检查通过。
- 真实项目源码归档生成并通过逐成员哈希验证；确定性、已有文件保护、畸形清单和篡改拒绝另外由单元测试覆盖。
- 资源审计检测到 5 个既有缺失动画文件：content/anims/blade.png、fireball.png、hero.png、palm.png、thunder.png。门只验证文档契约，故文档通过与资产失败并不矛盾。
- 普通 MCP validate 在本环境因 SDL 无显示设备未启动；新增 headless 路径完成同一门。另行执行未修改的 `tools/modules_check.nut`，在 cross.encounter-hosted-twice / cross.battle-capacity 两条探针失败后出现原生 `free(): invalid next size (fast)` 崩溃。该旧自检当时未计入通过项目；现已修复，见文末“已知问题修复验收”。

## 第二阶段：制作到发布的独立适配器

- `narrative.py`：有限无环剧情图与守卫式任务阶段编译为现有 event；拒绝不可达/循环/展开超限、重复自动触发器。没有第二份事件解释器。
- `refactor.py` / `changes.py`：权威引用图驱动的精确ID/路径重命名，带指纹前置条件的change-set；临时副本全量验证后销毁，原项目不改。
- `saves.py`：库存v1 ID/槽位迁移候选，真实restore/snapshot恢复检查；拒绝数值精度损失，世界存档和跨版本迁移另需适配。
- `replay.py`：真实战斗技能命令录制、逐步事件/状态指纹和回放差异报告；不复述战斗公式。
- `importers.py`：PNG网格到动画候选、PCM WAV审计及精确帧裁剪；源资源保留，写出不覆盖。
- `packaging.py`：已有SDK + 游戏源码封装、三平台启动器和完整性清单；原子排他发布，平台依赖明确交由目标系统。

可直接运行的源示例位于 `examples/toolkit/`，所有入口、协议和限制见 `13-toolkit-usage.md` 的新增章节。新增候选操作不改变原有 stage/export 内容写入约定。

第二阶段还修复了游戏入口的事件发现：由两份硬编码文件改为 workflow 索引加载；补齐 always/ne/object_consumed 条件。条件任务编译以平坦守卫适应现有事件门的一层容器限制，真实游戏适配函数验证未接取/条件未满足不发奖，完成后不重复发奖。

第二阶段验收：64 项测试全部通过（启用真实 SDK 集成测试），全项目无窗口权威门通过，遭遇投影新鲜度检查通过。真实 item 重命名 change-set 在隔离副本验证通过且 applied:false；真实战斗录制/回放 matched:true；实际 Linux SDK 发布目录的 5,153 个文件校验通过，复制后的 eve 可报告版本。Windows/macOS 发布适配由 stub SDK 测试覆盖，未在目标系统启动游戏。此时的5张缺失图片与旧模块自检崩溃未计作本阶段通过项；后续修复结果见下。

## 已知问题修复验收

- 5张缺失动画已补为原创程序化开发素材，透明PNG与既有网格/片段匹配；生成器 `tools/build_placeholder_anims.py` 可离线重建、`--check` 检查字节一致性。CI新增生成物及完整资源审计。素材定位和MIT授权见 `content/anims/CREDITS.md`。
- 模块自检的两项误报及原生崩溃来自 SDK `-r` 与 `load.nut` 共享局部变量帧：原有109个顶层局部变量使帧越界风险暴露。将负例与战场覆盖探针放入独立函数后，顶层局部变量降为12；全部原断言与执行次序保留，无需修改业务校验规则或引擎。
- 新增 `selftest --headless`，同时要求逐项通过、唯一最终PASS、进程正常退出；不把脚本失败的零退出码或崩溃前的PASS误判为成功。原MCP selftest保持原职责。
- 修复后69项测试全部通过（含真实SDK集成），完整模块探针372项通过、0失败、退出码0；23项资源审计通过且零诊断，全项目权威门与遭遇投影新鲜度检查通过。原外部quest注册warning与未实现的运行时能力仍按原有边界记录，不以本次修复冒充新功能。

## 第三阶段：基于主流引擎对照的生产效率改进

工作流矩阵及依据见 [14-engine-comparison.md](14-engine-comparison.md)。本轮选择三个独立能力，继续沿用候选与权威门，而不是引入IDE：

- `terrain.py`：完整16-mask四邻域自动地形，绘制/擦除及相邻重连，稳定seed变体，拒绝覆盖外来GID；不是八邻域或多地形混合系统。
- `database.py`：显式JSON Pointer列的类型化CSV导出/导入，携带身份与前置指纹；导入输出change-set，未编辑字段/文档保留；CSV不求值公式，空change-set可验证当前项目。
- `pipeline.py`：严格数据profile、固定检查白名单、逐项超时及失败聚合；quick用于离线检查，release要求引擎/资源/两类生成物，并可加强模块套件为required。不存在profile任意shell执行通道。

完整规则与严格发布profile示例位于 `examples/toolkit/terrain.rules.json` 和 `release.profile.json`。地形示例的GID映射仅展示协议，实际使用须对应自己的图集美术。对比明确保留完整对话、世界存档、性能分析、媒体压缩和目标平台实机验证等差距。

第三阶段验收：92项测试全部通过（启用真实SDK集成）；真实CSV数值变更通过隔离全量门且原文档未修改。严格release profile的engine、assets、placeholder-anims、encounters、modules五项全部pass；模块套件仍为372项通过。Python编译与diff空白检查通过。没有执行四款外部引擎的性能基准，横向结论限定为文档与实现范围对照。
