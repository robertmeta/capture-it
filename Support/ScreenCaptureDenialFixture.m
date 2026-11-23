// Inject a denial at the OS boundary in a test child without changing macOS permissions.
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

static NSError *accessError(void) {
    return [NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorUserDeclined userInfo:nil];
}

static void denyEnumeration(id receiver, SEL selector, BOOL desktop, BOOL onScreen,
                            void (^completion)(SCShareableContent *, NSError *)) {
    completion(nil, accessError());
}

static void denyStart(id receiver, SEL selector, void (^completion)(NSError *)) {
    completion(accessError());
}

__attribute__((constructor)) static void installFixture(void) {
    const char *phase = getenv("CAPTURE_IT_DENIAL_PHASE");
    if (phase && strcmp(phase, "start") == 0) {
        Method method = class_getInstanceMethod(SCStream.class, @selector(startCaptureWithCompletionHandler:));
        method_setImplementation(method, (IMP)denyStart);
    } else {
        Method method = class_getClassMethod(SCShareableContent.class, @selector(getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:));
        method_setImplementation(method, (IMP)denyEnumeration);
    }
}
