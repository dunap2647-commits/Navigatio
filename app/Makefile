include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Navigatio

Navigatio_FILES = $(shell find Sources -name '*.swift')
Navigatio_FRAMEWORKS = UIKit Foundation
Navigatio_SWIFTFLAGS = -ISources/IPC

# Говорим компилятору Swift использовать наш мост для C-кода
Navigatio_SWIFT_BRIDGING_HEADER = Bridging-Header.h

# Подпись (если вы создали app/entitlements.plist)
Navigatio_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
