# 贡献

- **内容、脚本、编辑器、资源**：在本仓库开 PR。
- **引擎 C++ / 公共 API**：开 PR 到 [EVEngine/EVEngine](https://github.com/EVEngine/EVEngine) 的 `dev` 分支，流程见 [ENGINE.md](ENGINE.md)。

内容文档改完后在仓库根目录跑：

```bash
python tools/rpgc.py validate
python tools/rpgc.py selftest
```

需要本机有可用的 `eve`（SDK 或本地构建）。
