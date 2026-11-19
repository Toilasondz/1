# ============================================================
# Makefile cho tweak ZZZZZZVideoStarTool
# Target: iOS 14.0+ (arm64 / arm64e), ARC
# Build:  make clean && make
# ============================================================

# --- Tên tweak & package ---
TWEAK_NAME = ZZZZZZVideoStarTool
$(TWEAK_NAME)_FILES = VideoStarTool.m

# --- Frameworks cần link ---
$(TWEAK_NAME)_FRAMEWORKS = Foundation UIKit CoreGraphics CoreImage QuartzCore PhotosUI

# --- Compiler flags ---
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -O2 -Wno-unused-variable -Wno-unused-function

# --- Chỉ build arm64 (và arm64e nếu cần) ---
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

# --- Theos include (bắt buộc, đặt cuối) ---
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
