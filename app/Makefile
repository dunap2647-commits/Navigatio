include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Navigatio

# Собираем все .swift файлы в папке Sources (включая подпапку IPC)
Navigatio_FILES = $(shell find Sources -name '*.swift')
Navigatio_FRAMEWORKS = UIKit Foundation
Navigatio_SWIFTFLAGS = -ISources/IPC

include $(THEOS_MAKE_PATH)/application.mk
