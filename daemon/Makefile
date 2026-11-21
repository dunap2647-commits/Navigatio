export ARCHS = arm64
TARGET = iphone:clang:latest:12.0

# Эта строка должна быть ОБЯЗАТЕЛЬНО здесь, до TOOL_NAME!
include $(THEOS)/makefiles/common.mk

TOOL_NAME = navigatiod
navigatiod_INSTALL_PATH = /usr/libexec
navigatiod_FILES = main.m NVDaemonServer.m NVCoreSupervisor.m NVRouteManager.m \
                   ../common/NIPCFrame.c ../common/NIPCMessage.m
navigatiod_CFLAGS = -fobjc-arc -I../common -Wall -Wextra -Wno-unused-parameter
navigatiod_FRAMEWORKS = Foundation Security SystemConfiguration

# Флаг подписи
navigatiod_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
