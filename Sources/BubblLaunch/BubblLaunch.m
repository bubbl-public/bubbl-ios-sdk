#import "BubblLaunch.h"
#import <Foundation/Foundation.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

// Bubbl's own start at launch, with no app code (as Android's App Startup). Swift has no +load, so
// this Objective-C class registers, before main(), for the end of every launch. There it asks the
// Swift side (BubblLaunchHook, found by name, since this target can't import the one that depends
// on it) to start Bubbl again if an earlier launch started it and it wasn't stopped. So an app that
// iOS launches for a geofence, a push or a tap has Bubbl running before a wrapper's JavaScript or
// Dart could call start.
@interface BubblLaunchLoader : NSObject
@end

@implementation BubblLaunchLoader

+ (void)load {
#if TARGET_OS_IOS
    // Below iOS 17 Bubbl does nothing (Bubbl.isSupported): no background task, no start at launch.
    if (@available(iOS 17.0, *)) {} else { return; }

    // Background refresh's handler must be registered before launch finishes: now, before main().
    Class hook = NSClassFromString(@"BubblLaunchHook");
    SEL registerTasks = NSSelectorFromString(@"registerBackgroundTasks");
    if ([hook respondsToSelector:registerTasks]) {
        ((void (*)(id, SEL))[hook methodForSelector:registerTasks])(hook, registerTasks);
    }

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *notification) {
        Class hook = NSClassFromString(@"BubblLaunchHook");
        SEL launched = NSSelectorFromString(@"applicationDidFinishLaunching");
        if ([hook respondsToSelector:launched]) {
            ((void (*)(id, SEL))[hook methodForSelector:launched])(hook, launched);
        }
    }];
#endif
}

@end

void BubblLaunchLinked(void) {}
