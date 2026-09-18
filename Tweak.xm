// Tweak.xm
//
// Injected into Telegram only (see Tweak.plist Filter). On first launch
// after each reboot it opens Telegram's own "tg://socks?..." deep link,
// which is Telegram's officially supported way to add+select a SOCKS5
// proxy (the same mechanism the desktop client's "Open in Telegram" tray
// button uses). This does NOT patch any internal Telegram class, so it
// keeps working across Telegram app updates.
//
// IMPORTANT: Telegram will still show its own one-time "Enable this
// proxy?" confirmation sheet - that's a safety feature of Telegram
// itself and can't be (and shouldn't be) bypassed from outside. After
// the user taps once, Telegram remembers the choice.

#import <UIKit/UIKit.h>

static NSString *TGWMarkerPath(void) {
    BOOL rootless = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"];
    return rootless ? @"/var/jb/tmp/tgwsproxy_autoconnect_done" : @"/tmp/tgwsproxy_autoconnect_done";
}

static NSInteger TGWReadConfiguredPort(void) {
    NSInteger port = 1080;
    NSString *confPath = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/etc/tgwsproxy.conf"] ?
        @"/var/jb/etc/tgwsproxy.conf" : @"/etc/tgwsproxy.conf";
    NSString *contents = [NSString stringWithContentsOfFile:confPath encoding:NSUTF8StringEncoding error:nil];
    if (contents) {
        for (NSString *rawLine in [contents componentsSeparatedByString:@"\n"]) {
            NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([line hasPrefix:@"PORT="]) {
                port = [[line substringFromIndex:5] integerValue];
            }
        }
    }
    return port > 0 ? port : 1080;
}

%ctor {
    @autoreleasepool {
        NSString *marker = TGWMarkerPath();
        if ([[NSFileManager defaultManager] fileExistsAtPath:marker]) {
            return; // already offered this boot cycle
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIApplication *app = [UIApplication sharedApplication];
            if (!app) return;

            NSInteger port = TGWReadConfiguredPort();
            NSString *urlStr = [NSString stringWithFormat:@"tg://socks?server=127.0.0.1&port=%ld", (long)port];
            NSURL *url = [NSURL URLWithString:urlStr];
            if (!url) return;

            // Deployment target is iOS 16, so the completionHandler API is
            // always available - no need for the deprecated openURL: fallback.
            [app openURL:url options:@{} completionHandler:^(BOOL success) {
                if (success) {
                    [[NSFileManager defaultManager] createFileAtPath:marker contents:nil attributes:nil];
                }
            }];
        });
    }
}
