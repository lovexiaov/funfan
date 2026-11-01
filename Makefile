# FunFan —— 开发入口
#
# 说明：本机 SPM 的 sandbox-exec 受限，所有 swift 命令必须带 --disable-sandbox，
# 否则连 Package.swift 都无法编译（Operation not permitted）。

SWIFT_FLAGS := --disable-sandbox

.PHONY: help build release test run run-raw run-app app app-debug stop-running icon sign-info notarize notary-check dmg publish publish-unsigned publish-dry doctor diagnose raw status spin install-helper uninstall-helper purge-legacy clean

help:
	@echo "FunFan 开发命令："
	@echo "  make build              调试构建（含 CLI / helper / probe / GUI）"
	@echo "  make release            release 构建"
	@echo "  make test               跑全部单测"
	@echo "  make run                开发态启动（debug 二进制装进 .app，行为与正式包一致）"
	@echo "                          ARGS=\"--log-popover\" 可透传给 App"
	@echo "  make run-raw            启动裸二进制（没有 bundle 身份，只用于快速调试）"
	@echo "  make app                打包成 dist/FunFan.app（登录项/helper/公证都要它）"
	@echo "  make run-app            打包并启动 dist/FunFan.app"
	@echo "  make icon               重新生成应用图标（SVG + PNG + icns，几何见 packaging/gen-icon.py）"
	@echo "  make sign-info          看当前会自动选用的签名身份"
	@echo "  make notary-check       体检：证书 / 公证凭据 / 硬运行时，缺什么说什么"
	@echo "  make notarize           Developer ID 签名 + 公证 + 装订 + Gatekeeper 验收"
	@echo "  make dmg                打 dist/FunFan-<版本>.dmg（有证书就顺带签）"
	@echo "  make publish-unsigned   发 GitHub Release（草稿，未公证内测包）—— 当前默认路径"
	@echo "  make publish            发 GitHub Release（草稿，需 Developer ID 证书，没有会拒绝）"
	@echo "  make publish-dry        演练发布：跑到打包为止，只打印 gh 命令"
	@echo "  make doctor             硬件诊断（只读）"
	@echo "  make diagnose           系统信息采集：能力逐项实测 + 排查建议"
	@echo "  make raw KEY=TR0Z       看原始字节与候选解码（也可 TYPE=ioft 扫全表）"
	@echo "  make status             风扇状态（只读）"
	@echo "  make spin               真机写入验证（需要 sudo）"
	@echo "  make install-helper     安装特权 helper（需要 sudo，开发期直装）"
	@echo "  make uninstall-helper   卸载特权 helper（需要 sudo）"
	@echo "  make purge-legacy       体检：列出改名前的旧包残留（只读，真清加 --apply）"

build:
	swift build $(SWIFT_FLAGS)

release:
	swift build -c release $(SWIFT_FLAGS)

test:
	swift test $(SWIFT_FLAGS)

run: app-debug
	@$(MAKE) --no-print-directory stop-running
	@echo "→ 启动 dist/FunFan.app（debug 二进制；bundle 身份 / 偏好域 / 登录项与正式包一致）"
	@echo "  注意：dist/FunFan.app 里现在是 debug 二进制，要正式包请跑 make app"
	@open dist/FunFan.app $(if $(ARGS),--args $(ARGS))

# 裸二进制：没有 bundle 身份 —— 偏好落在进程名域 FunFan（不是 cn.lovexiaov.fun.fan），
# 登录项与 SMAppService 安装走不了，日志也和打包版混在同一份文件里。
# 只用来快速跑逻辑，别用它判断「用户看到的行为对不对」。
run-raw: build
	@echo "⚠️  裸二进制：偏好域 / 启动项 / bundle 身份都与正式包不同，行为差异不一定是 bug"
	./.build/debug/FunFan

app-debug:
	./scripts/build-app.sh --debug

# `open` 对已在运行的应用只是「激活」，不会换掉旧进程里的旧二进制 ——
# 重新构建后不做这步，你测的还是上一次的代码。
stop-running:
	-@pids=$$(pgrep -x FunFan); if [ -n "$$pids" ]; then \
	    echo "→ 结束已在运行的 FunFan（$$pids）…"; \
	    kill -TERM $$pids; \
	    for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x FunFan >/dev/null || break; sleep 0.2; done; \
	  fi

icon:
	python3 packaging/gen-icon.py

app:
	./scripts/build-app.sh

run-app: app
	@$(MAKE) --no-print-directory stop-running
	@open dist/FunFan.app

sign-info:
	@./scripts/build-app.sh --print-identity

notary-check:
	@./scripts/notarize.sh --check

notarize:
	./scripts/notarize.sh

dmg: app
	./scripts/make-dmg.sh

publish:
	./scripts/release.sh

# 当前主力路径：没有 Developer ID 证书，发的是未公证内测包。
# release notes 会自动插入解除隔离属性的说明，README「安装」一节讲的是同一件事。
publish-unsigned:
	./scripts/release.sh --allow-unsigned

publish-dry:
	./scripts/release.sh --dry-run

doctor: release
	./.build/release/funfanctl doctor

diagnose: release
	./.build/release/funfanctl diagnose

# 原始字节取证：make raw KEY=TR0Z   /   make raw TYPE=ioft
raw: release
	@if [ -n "$(TYPE)" ]; then ./.build/release/funfanctl raw --type $(TYPE); \
	elif [ -n "$(KEY)" ]; then ./.build/release/funfanctl raw $(KEY); \
	else echo "用法：make raw KEY=TR0Z   或   make raw TYPE=ioft"; exit 1; fi

status: release
	./.build/release/funfanctl status

spin: release
	sudo ./scripts/spin-test.sh

install-helper: release
	sudo ./scripts/install-helper.sh

# 只做体检；真删要显式带 --apply，避免一个 make 目标就把系统改了
purge-legacy:
	bash scripts/purge-legacy.sh

uninstall-helper:
	sudo ./scripts/install-helper.sh uninstall

clean:
	swift package clean
