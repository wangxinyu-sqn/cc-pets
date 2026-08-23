# 参与贡献

[English](./CONTRIBUTING.md) | 简体中文

感谢你参与 CC Pets。提交改动前，请先确认：

1. 改动聚焦于一个明确问题，并避免提交无关格式化。
2. 新素材必须是原创作品，或具有允许修改和再分发的明确许可证。
3. 不要提交 Codex/Claude 会话、额度缓存、API Key、Cookie、个人路径或其他敏感信息。
4. 运行 `npm test`，确保原生构建、Hooks、额度采集、卸载和包装器测试全部通过。
5. 对用户可见的行为变化同步更新 `README.zh-CN.md` 和 `CHANGELOG.zh-CN.md`。

建议先开一个 GitHub Issue 描述较大的功能改动，达成一致后再提交 Pull Request。

## 素材规范

- 支持 PNG 或 WebP，背景必须透明。
- 内置素材按 `8×9` 网格切分。外部 Codex/PetDex 素材支持
  `spriteVersionNumber` v1（`1536×1872`、`8×9`）和
  v2（`1536×2288`、`8×11`），每格均为 `192×208`。
- 九行动画帧数依次为 `6/8/8/4/5/8/6/6/6`，未使用单元格必须保持透明。
- 请在 Pull Request 中说明素材作者、来源和许可证。
