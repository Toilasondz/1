TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = VideoStar

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VideoStarTool
VideoStarTool_FILES = VideoStarTool.m
VideoStarTool_CFLAGS = -fobjc-arc
VideoStarTool_FRAMEWORKS = UIKit Foundation AVFoundation CoreImage PhotosUI
VideoStarTool_PRIVATE_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk
