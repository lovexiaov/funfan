## 这个 PR 做了什么

<!-- 一句话说清目的。如果修了某个 issue，写 Fixes #123。 -->

## 为什么

<!-- 背景、取舍、被放弃的方案。涉及 SMC 键表或硬件行为的，写清真机验证结果。 -->

## 怎么验的

- [ ] `make test` 全绿
- [ ] 真机验证（机型 / macOS 版本：  ）

<!-- 改了 UI 的请贴截图；改了 SMC 的请贴 make raw / funfanctl diagnose 片段。 -->

## 自检

- [ ] 没有引入第三方运行时依赖
- [ ] 没有触碰安全红线（写 `F0Mn`/`F0Mx`、发 0 RPM、放宽签名校验、移除租约看门狗）
- [ ] 安全相关常量仍然只有一个真源
- [ ] 如果改了 bundle id 相关文件，已说明原因（fork 构建请勿提交到上游）
- [ ] 我已阅读 [CONTRIBUTING.md](https://github.com/lovexiaov/funfan/blob/main/CONTRIBUTING.md)，代码按 MIT 授权
