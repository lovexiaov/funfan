# 项目状态与验证记录

> 从 [README](../README.md) 拆出。逐版本改动见 [CHANGELOG.md](CHANGELOG.md)，逐项验收记录在本地台账 `tasks/todo.md`（该目录未纳入仓库）。

M1（SMC 地基）→ M5（GUI）已完成并在真机（Mac mini M4 / macOS 27）验证：180/180 温度键可读、风扇 1000–4900 RPM 写入生效、291 个单测全绿。

策略四态（自动 / 固定 / 曲线 / 规则）全部可用，曲线与规则编辑器均已落地；设置窗口支持登录启动、菜单栏显示开关、一键自检与免责声明。

曲线策略已在真机跑通端到端：接管后 `manualFixed`、目标随温度单调跟随（2116→2333）、实际转速误差 0–3 RPM、`kill -9` 后 8 s 由租约看门狗返还 `automatic`。规则策略的写入链路与曲线共用同一套下发路径。

M6（打包加固）已落地：`.app` 打包、Developer ID 签名 + 公证 + 装订脚本、helper 一次授权（`SMAppService`）、第三方接管检测与 `doctor` 自检。公证链路只验到失败路径与提交前预检；打包后的 helper 注册还差一次真机复验（见 `tasks/todo.md` M6 的 Verify 记录）。

**分发形态：未签名、未公证。** 已决定不购买 Apple Developer Program 会员（$99/年），对外发的就是 adhoc 签名的内测包，用户按 [INSTALL.md](INSTALL.md) 手动放行一次。签名 + 公证的脚本留在仓库里，将来有证书可以直接启用，不需要改代码。这个选择的代价很具体：每个下载的人多两步点击，而且每次升级都要重复。

已撤回：`v1.0.0-alpha.1` / `v1.0.0-alpha.2` 的包由改名前的 bundle id 构建，已从 Releases 删除，tag 与本地标签一并清掉（对应提交仍在历史里）。装过旧包的机器用 `sudo bash scripts/purge-legacy.sh --apply` 清残留。换用新标识 `cn.lovexiaov.fun.fan` 后已重新发版（`v1.0.0-alpha.3` 起），现存安装包都是新标识构建的。

未完成：T16b 端到端合盖验证（需笔记本机型）。
