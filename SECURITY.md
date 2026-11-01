# 安全策略

FunFan 会以 **root 权限** 安装一个后台组件（`cn.lovexiaov.fun.fan.helper`）来写 SMC 风扇键。这个设计决定了安全边界值得单独说明，也决定了漏洞请不要公开提交。

## 支持范围

| 版本 | 状态 |
|---|---|
| 最新 Release（当前为 `1.0.0-alpha.x`） | 接受报告 |
| 更早的预发布版本 | 建议先升级再复现，通常不单独修 |
| 自己改过的分支 / fork | 不接受，请先确认原版能否复现 |

项目仍是 alpha，接口与行为都可能变；安全修复会进下一个版本，不承诺 backport。

## 上报方式

**不要开公开 issue。** 请走 GitHub 的私密漏洞报告：

<https://github.com/lovexiaov/funfan/security/advisories/new>

一个有用的报告包含：

- 影响的版本（`FunFan` 版本号或 `git rev-parse --short HEAD`）
- 机型 / 芯片 / macOS 版本
- 复现步骤与最小 PoC
- 你判断的影响（本地提权？未授权控风扇？拒绝服务？）

这是个人项目，回复按尽力而为处理，不设 SLA。确认后会在 advisory 里同步进展，修完再公开细节。

## 信任模型

理解下面几条，能帮你判断某个现象是不是漏洞：

1. **GUI 进程永不持 root。** 菜单栏 App 以当前用户身份运行，只通过 XPC 请求 helper 执行写入。
2. **helper 只做一件事。** 它接受的目标转速会被 clamp 到系统区间，只写 `F0Tg`、风扇模式键与 `Ftst`；**绝不写 `F0Mn` / `F0Mx`**，**绝不发送 0 RPM**。
3. **连接方要过签名校验。** helper 只接受 bundle id 为 `cn.lovexiaov.fun.fan`、且证书锚定 Apple 的客户端（见 `FunFanCore/Helper/HelperSignature.swift`）。没有 TeamID 的 adhoc 构建走的是「管理员一次授权直装」那条路径，边界由文件权限（`root:wheel`）保证。
4. **有租约，会自己还权。** 每次写入附带 10 s 租约，GUI 心跳续租；GUI 崩溃、退出、合盖或租约过期，helper 会把风扇交还系统自动控制。
5. **没有网络行为。** 不联网、不收集数据、无遥测。诊断报告只在你点「复制」时生成并存在本机。
6. **安装脚本要 sudo。** `scripts/install-helper.sh` 与 App 内「一键启用」都会往 `/Library/PrivilegedHelperTools` 与 `/Library/LaunchDaemons` 写文件，这是功能本身要求的，不是漏洞——但**任何让你从网上 `curl | sudo bash` 的“安装方法”都不是本项目提供的**。

## 值得报告的问题

- 非授权本地进程能控制风扇，或绕过签名/权限校验
- helper 能被诱导写 SMC 区间以外的键、写 0 RPM、或绕过安全下限
- 安装/卸载流程存在任意文件写、路径穿越、TOCTOU 提权
- 退出、崩溃、睡眠、合盖后风扇未返还系统控制（尤其是静默失败）
- 诊断报告或日志泄露用户敏感信息（用户名、序列号、路径）

## 不算安全问题的

- Gatekeeper 拦截、「已损坏，无法打开」——这是未公证包的预期行为，见 README 安装一节
- 需要先拿到 root / 管理员密码才能做的事
- 自己改代码或改 SMC 键表导致的异常
