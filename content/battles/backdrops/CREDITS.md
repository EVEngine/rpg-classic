# 战斗背景素材来源与授权（rpg-classic）

## 当前状态：四张 CC0 战斗背景

本目录的战斗背景全部由 `tools/import_battle_backdrops.py` 生成。该脚本是唯一的
来源入口：它按固定 URL 下载上游文件、比对写在脚本里的 SHA-256、把上游原始字节
缓存在 `assets/<pack>/`，再裁切缩放到 `content/battles/backdrops/`。`--check`
不写盘，只重算一遍并逐字节比对磁盘上的文件——素材漂移会变成一次构建失败，
而不是一次静默的美术替换。

```bash
cd .  # repository root
python tools/import_battle_backdrops.py           # 下载 + 解包 + 裁切缩放
python tools/import_battle_backdrops.py --check   # 只校验，不写盘
```

### 背景文件

| 文件 | 尺寸 | 大小 | 上游包 | 作者 | 授权 |
|---|---|---|---|---|---|
| `backdrop.snow-mountain-pass.png` | 1920×1080 | 1,823,128 B | Oil painting landscapes | JAP | CC0-1.0 |
| `backdrop.golden-plain.png` | 1920×1080 | 1,426,671 B | Oil painting landscapes | JAP | CC0-1.0 |
| `backdrop.desert.png` | 1920×1080 | 1,281,514 B | Oil painting landscapes | JAP | CC0-1.0 |
| `backdrop.waterfront.png` | 1920×1080 | 615,141 B | Few Water Backgrounds (1366×768) | rh0 | CC0-1.0 |

文件名按**地貌**命名（而不是按上游的 `coldmountain` / `sunsetintheswamp`），
因为战斗文档要按含义引用它：`battle.snowfield.json` 类文档引用雪山，
水的场景引用 `waterfront`。逐包的上游信息记录在 `assets/<pack>/SOURCE.json`：
作者、上游页面、每个文件的下载直链、SHA-256、授权与直链。上游文件本身也留在
`assets/<pack>/`，所以一次离线重算（`--check`）不需要网络。

### 两个上游包

| 包 | 作者 | 上游页面 | 授权 |
|---|---|---|---|
| Oil painting landscapes | JAP | <https://opengameart.org/content/oil-painting-landscapes> | CC0-1.0 |
| Few Water Backgrounds (1366×768) | rh0 | <https://opengameart.org/content/few-water-backgrounds-1366%C3%97768> | CC0-1.0 |

授权直链（两包相同）：<https://creativecommons.org/publicdomain/zero/1.0/>

### 授权要求：什么也不需要做

两个包都选择 **CC0 1.0 Universal**，而不是 CC-BY / CC-BY-SA：CC0 不要求署名，
所以下游游戏即使完全没有 credits 界面也不构成侵权，而 BY-SA 的传染性会波及整个
项目。上游页面上的 "License(s): CC0" 是 OpenGameArt 的机器可读授权字段，由上传者
在提交时选择；CC0 的全部法律内容就是上面那条 `creativecommons.org/publicdomain/
zero/1.0/` 链接。

**署名仍然照写，但这些记录是为了可审计，不是因为法律义务。** 这一点必须说清楚，
否则以后有人会以为漏写 credits 需要补救。

### 做了哪些变换，为什么

上游原始尺寸不一致：三张油画是 **1000×700（10:7）**，那张水是 **1366×768**
（本身就是 16:9）。战斗画布是 1920×1080（见 `content/battles/battle.*.json` 的
`canvas`），一套混着不同宽高比的背景没法被同一个战斗场景摆位，所以每个源都做
了两步，**没有任何重绘或调色**：

1. **居中裁切到 16:9** —— 裁切保住了构图，而非等比拉伸会把画面压扁；
2. **Lanczos 放大到 1920×1080** —— 1000×700 放大约 1.9×。放大只是插值已有像素，
   不发明结构；但它是**软**的，这一点请按「够用」而不是「原生 1080p」来理解。

另外把文件名从上游的 `coldmountain` 等改成按地貌命名（见上表），理由同前。

### 明确没有引入的东西

- **`Forest Background Art`（Tamara Ramsay）被放弃**：它的授权是
  **CC-BY-SA 3.0**（OGA 页面 "License(s): CC-BY-SA 3.0"，正文要求
  "Attribution Instructions: Tamara Ramsay http://vectorgurl.com/"）。
  BY-SA 的传染性会波及整个项目，也不满足本工作流「只用 CC0」的硬约定，所以不用。
  代价是**这一组里没有森林背景**——本轮的雪原/平原/沙漠/水面四张覆盖了四种地貌，
  森林缺口留在下面的「已知缺口」里，不假装已经解决。
- **`Seamless HD landscape in parts`（PWL）没有引入**：作者自己写的
  "Credit as PWL is appreciated"，虽然 OGA 授权字段是 CC0，但一句「希望署名」
  会让「CC0 无需署名」的卖点变成需要解释的模糊地带；而且在库版本是 800×500，
  放大到 1080p 太软。宁缺毋滥。
- **`Mixed Fantasy Backgrounds` 没有引入**：最大一张只有 900×531，且上游是
  委托稿（"backgrounds I commisioned but never uesed"），来源链比作者本人作品长。
- **所有照片类素材（Winter Backgrounds 33 张等）没有引入**：它们是真实照片，
  和本目录的油画风格不一致，混在一起会让一套背景看起来像两套。

### 已知缺口（不掩盖）

1. **`backdrop.waterfront.png` 严格说是一张水面纹理，不是一个场景构图**：
   上游 `water1_1.png` 整幅都是水波，没有岸线、船或远景。它给水面战斗提供了一个
   可用但单调的底，够用；如果以后要一个有岸的场景，得另找一个 CC0 源。
2. **没有森林、洞穴、城镇三张**。上面已说明森林那个源因 BY-SA 被放弃；洞穴与
   城镇本轮没有找到同时满足「CC0 可确认 + 尺寸够 + 风格统一」的源，所以没有硬凑。
3. **上游 `rh0` 的水系列一共 4 张**（`water1_1`/`water2`/`water3`/`water4`），
   本目录只引入了 `water1_1`。四张彼此非常相似，引入全部只会增加体积而不增加
   可区分的地貌——这不是抓不到，是**故意只取一张**。
4. **`--check` 只校验本地字节，不联网核对上游**。这是刻意的：让它能离线运行。
   因此上游重新上传**不会**被 `--check` 发现，只有 `--refresh`（或缓存被删后
   重跑）才会撞上 SHA-256 不匹配并以非零退出。要审计上游是否变过，跑 `--refresh`。

### 战斗文档怎么引用

战斗文档（`content/battles/battle.*.json`）用 **`background`** 字段引用本目录。路径是
**相对文档本身**的（语义与 `tileset.image`、`anim.image` 一致），所以写的是
`backdrops/backdrop.<地貌>.png`，再由 `Rpgc.resolveFrom` 相对文档路径解析成工程路径。
编辑器画的是它，`docs/10-battle-scene.md` §7 说明为什么这个字段没有 `fit` / `tint` 开关。

当前接线（5 / 6 份战场）：

| 战场 | `background` | 说明 |
|---|---|---|
| `battle.snowfield` | `backdrops/backdrop.snow-mountain-pass.png` | 雪山 = 雪原 |
| `battle.mountain-pass` | `backdrops/backdrop.snow-mountain-pass.png` | **与雪原共用一张**；schema 说明了为什么两块战场可以共用一张背景 |
| `battle.open-field` | `backdrops/backdrop.desert.png` | 该战场承接 `encounter.yumen-dunes`（玉门沙丘） |
| `battle.waterfront` | `backdrops/backdrop.waterfront.png` | 渡口 |
| `battle.forest-clearing` | `backdrops/backdrop.golden-plain.png` | 上游是 `sunsetintheswamp`（沼泽落日）；**这是本组里最弱的一次匹配**，没有森林源（见上），只能取最接近的 |
| `battle.town-square` | *（字段缺席）* | 城镇广场没有合规的 CC0 源，`background` 是可选字段，所以留空而不是硬凑一张错的 |

两处缺口是**有意的**：`forest-clearing` 的匹配不理想、`town-square` 没有背景。
`tools/modules_check.nut` 的 `battle-backdrop.files-exist` 断言每份声明过的路径都能
解析到磁盘上真实存在的文件——因为运行期 `newTextureFromFile` 会吞掉缺文件，
不检查的话场景只是安静地不画背景。
