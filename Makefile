#
# GSPlayerInfo — 纯 dylib（library.mk，不依赖 CydiaSubstrate）
# 参考 DYYY：必须用 Theos + iphone:clang + iOS SDK 编译。
#
# 编译：
#   make clean package
# 产物：
#   packages/GSPlayerInfo.dylib  （用于 @executable_path/GSPlayerInfo.dylib 注入）
#
TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GSPlayerInfo

GSPlayerInfo_FILES = Tweak.m
GSPlayerInfo_CFLAGS += -Wno-arc-retain-cycles
GSPlayerInfo_FRAMEWORKS = UIKit Foundation AVFoundation CoreGraphics QuartzCore
GSPlayerInfo_INSTALL_PATH = /usr/local/lib

include $(THEOS_MAKE_PATH)/library.mk

after-all::
	@mkdir -p packages
	@DY=$$(find .theos/obj -name 'GSPlayerInfo.dylib' 2>/dev/null | head -1); \
	if [ -n "$$DY" ]; then \
		cp -f "$$DY" packages/GSPlayerInfo.dylib; \
		echo "==> copied $$DY -> packages/GSPlayerInfo.dylib"; \
		ls -la packages/GSPlayerInfo.dylib; \
	else \
		echo "==> WARN: GSPlayerInfo.dylib not found under .theos/obj"; \
		find .theos -name '*.dylib' 2>/dev/null || true; \
	fi
