export ARCHS = arm64
TARGET = iphone:clang:latest:12.0

TOOL_NAME = navigatiod
navigatiod_INSTALL_PATH = /usr/libexec
navigatiod_FILES = main.m NVDaemonServer.m NVCoreSupervisor.m NVRouteManager.m \
                   ../common/NIPCFrame.c ../common/NIPCMessage.m
navigatiod_CFLAGS = -fobjc-arc -I../common -Wall -Wextra -Wno-unused-parameter
navigatiod_FRAMEWORKS = Foundation Security SystemConfiguration
navigatiod_CODESIGN_FLAGS = -S=entitlements.plist

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tool.mk
