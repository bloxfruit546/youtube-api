export ARCHS = arm64
# Pinned SDK instead of "latest": against iOS 16.x the compiler silently accepts
# iOS 13+ calls behind a 12.0 deployment target, so "iOS 12 only" would be
# advisory. Against 12.4 they are hard compile errors.
export TARGET = iphone:clang:12.4:12.0

INSTALL_TARGET_PROCESSES = Camera

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PhotographicStyles16

PhotographicStyles16_FILES = Tweak.x \
	Sources/PS16ColorEngine.m \
	Sources/PS16DotMatrixPadView.m \
	Sources/PS16IntensitySlider.m \
	Sources/PS16ControlPanelView.m

PhotographicStyles16_CFLAGS = -fobjc-arc -Wall -Wno-unused-parameter \
	-Wno-deprecated-declarations \
	-I$(THEOS_PROJECT_DIR)/Headers \
	-I$(THEOS_PROJECT_DIR)/Sources

PhotographicStyles16_FRAMEWORKS = UIKit Foundation CoreImage CoreGraphics \
	QuartzCore Metal MetalKit AVFoundation CoreMedia CoreVideo

PhotographicStyles16_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Camera 2>/dev/null || true"
