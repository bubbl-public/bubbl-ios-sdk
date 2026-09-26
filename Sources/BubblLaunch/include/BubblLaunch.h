#import <Foundation/Foundation.h>

/// Called by the Swift side so the linker keeps this target's object file, and with it the class
/// whose +load watches for the end of launch (a static library's unreferenced files are dropped).
FOUNDATION_EXPORT void BubblLaunchLinked(void);
