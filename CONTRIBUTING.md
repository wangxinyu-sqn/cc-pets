# Contributing

English | [简体中文](./CONTRIBUTING.zh-CN.md)

Thank you for contributing to CC Pets. Before submitting a change:

1. Keep the change focused on one clear problem and avoid unrelated formatting.
2. Submit only original assets or assets with an explicit license that permits modification and redistribution.
3. Never submit Codex or Claude sessions, quota caches, API keys, cookies, personal paths, or other sensitive information.
4. Run `npm test` and confirm that the native build, hooks, quota collection, uninstall, and wrapper tests pass.
5. Update `README.md` and `CHANGELOG.md` for user-visible behavior changes.

For a substantial feature, open a GitHub Issue before sending a Pull Request so the
scope can be agreed on first.

## Asset requirements

- Use PNG or WebP with a transparent background.
- Built-in assets use an `8×9` grid. External Codex/PetDex assets support
  `spriteVersionNumber` v1 (`1536×1872`, `8×9`) and v2 (`1536×2288`, `8×11`),
  with `192×208` cells.
- The nine animation rows contain `6/8/8/4/5/8/6/6/6` frames. Keep unused cells transparent.
- State the asset author, source, and license in the Pull Request.
