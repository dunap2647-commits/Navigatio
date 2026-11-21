include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Navigatio

# Добавляем Swift-файлы И напрямую C/Obj-C файлы из папки common
Navigatio_FILES = $(shell find Sources -name '*.swift') \
                  ../common/NIPCFrame.c \
                  ../common/NIPCMessage.m

Navigatio_FRAMEWORKS = UIKit Foundation

# Флаги для компиляции Objective-C/C частей
Navigatio_CFLAGS = -fobjc-arc -I../common

# Флаги для Swift
Navigatio_SWIFTFLAGS = -ISources/IPC

# Мост для Swift
Navigatio_SWIFT_BRIDGING_HEADER = Bridging-Header.h

# Подпись
Navigatio_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
