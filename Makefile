TARGET := iphone:clang:latest:14.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = Video Star

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZZZZZZVideoStarTool

ZZZZZZVideoStarTool_FILES = VideoStarTool.m
ZZZZZZVideoStarTool_FRAMEWORKS = UIKit Foundation Photos PhotosUI CoreImage Vision QuartzCore
ZZZZZZVideoStarTool_CFLAGS = -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
