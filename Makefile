# FunFan —— 开发入口
#
# 说明：本机 SPM 的 sandbox-exec 受限，所有 swift 命令必须带 --disable-sandbox，
# 否则连 Package.swift 都无法编译（Operation not permitted）。

SWIFT_FLAGS := --disable-sandbox

.PHONY: help build release test run run-app app sign-info doctor diagnose raw status spin install-helper uninstall-helper clean

help:
	@echo "FunFan 开发命令："
	@echo "  make build              调试构建（含 CLI / helper / probe / GUI）"
	@echo "  make release            release 构建"
	@echo "  make test               跑全部单测"
	@echo "  make run                启动菜单栏 GUI（裸二进制，开发态）"
	@echo "  make app                打包成 dist/FunFan.app（登录项/helper/公证都要它）"
	@echo "  make run-app            打包并启动 dist/FunFan.app"
	@echo "  make sign-info          看当前会自动选用的签名身份"
	@echo "  make doctor             硬件诊断（只读）"
	@echo "  make diagnose           系统信息采集：能力逐项实测 + 排查建议"
	@echo "  make raw KEY=TR0Z       看原始字节与候选解码（也可 TYPE=ioft 扫全表）"
	@echo "  make status             风扇状态（只读）"
	@echo "  make spin               真机写入验证（需要 sudo）"
	@echo "  make install-helper     安装特权 helper（需要 sudo，开发期直装）"
	@echo "  make uninstall-helper   卸载特权 helper（需要 sudo）"

build:
	swift build $(SWIFT_FLAGS)

release:
	swift build -c release $(SWIFT_FLAGS)

test:
	swift test $(SWIFT_FLAGS)

run: build
	./.build/debug/FunFan

app:
	./scripts/build-app.sh

run-app: app
	open dist/FunFan.app

sign-info:
	@./scripts/build-app.sh --print-identity

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

uninstall-helper:
	sudo ./scripts/install-helper.sh uninstall

clean:
	swift package clean
