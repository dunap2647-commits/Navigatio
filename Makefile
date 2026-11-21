export ARCHS = arm64
export TARGET = iphone:clang:latest:12.0
export THEOS_PACKAGE_SCHEME =
export THEOS_DEVICE_IP := 192.168.1.10

INSTALL_TARGET_PROCESSES = navigatiod

# app временно закомментирован, пока не готовы файлы интерфейса
SUBPROJECTS += common daemon

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
