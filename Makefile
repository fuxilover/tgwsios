ifndef THEOS
$(error THEOS is not set. `git clone --recursive https://github.com/theos/theos $$THEOS`)
endif

ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:16.0

# Build twice, once per scheme:
#   make package THEOS_PACKAGE_SCHEME=rootless   (roothide / Dopamine / palera1n rootless, iOS 15-18)
#   make package                                  (rootful, e.g. checkra1n/unc0ver-era or rootful Dopamine)

include $(THEOS)/makefiles/common.mk

TOOL_NAME = tgwsproxyd
tgwsproxyd_FILES = tgwsproxyd.m
tgwsproxyd_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
tgwsproxyd_FRAMEWORKS = Foundation

TWEAK_NAME = TGWSProxyAutoConnect
TGWSProxyAutoConnect_FILES = Tweak.xm
TGWSProxyAutoConnect_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/tweak.mk

# The plist content itself hardcodes an absolute path in its Program /
# ProgramArguments keys, which Theos cannot rewrite automatically (it
# only rewrites *file locations* for THEOS_PACKAGE_SCHEME=rootless, not
# path strings living inside file content) - so pick the right template
# for the scheme before Theos stages layout/ into the package.
before-stage::
	mkdir -p layout/Library/LaunchDaemons layout/etc
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
	cp templates/com.local.tgwsproxy.rootless.plist layout/Library/LaunchDaemons/com.local.tgwsproxy.plist
else
	cp templates/com.local.tgwsproxy.rootful.plist layout/Library/LaunchDaemons/com.local.tgwsproxy.plist
endif
	cp config/tgwsproxy.conf layout/etc/tgwsproxy.conf

after-install::
	install.exec "rm -f /tmp/tgwsproxy_autoconnect_done /var/jb/tmp/tgwsproxy_autoconnect_done; \
		(launchctl unload /Library/LaunchDaemons/com.local.tgwsproxy.plist 2>/dev/null || true); \
		(launchctl unload /var/jb/Library/LaunchDaemons/com.local.tgwsproxy.plist 2>/dev/null || true); \
		(launchctl load /Library/LaunchDaemons/com.local.tgwsproxy.plist 2>/dev/null || true); \
		(launchctl load /var/jb/Library/LaunchDaemons/com.local.tgwsproxy.plist 2>/dev/null || true)"
