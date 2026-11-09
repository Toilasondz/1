TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = VideoStar

include $(THEOS)/makefiles/common.mk

# Tên tweak = tên file .dylib output
TWEAK_NAME = ZZZZZZVideoStarTool

# File nguồn vẫn giữ tên VideoStarTool.m
ZZZZZZVideoStarTool_FILES = VideoStarTool.m
ZZZZZZVideoStarTool_CFLAGS = -fobjc-arc
ZZZZZZVideoStarTool_FRAMEWORKS = UIKit Foundation AVFoundation CoreImage PhotosUI

include $(THEOS_MAKE_PATH)/tweak.mk
