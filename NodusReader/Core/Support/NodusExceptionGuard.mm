// SPDX-License-Identifier: AGPL-3.0-only
#import "NodusExceptionGuard.h"

BOOL NodusPerformCatchingExceptions(NS_NOESCAPE void (^block)(void)) {
    // Objective-C exceptions are C++ exceptions in the 64-bit runtime, so
    // one handler takes both.
    try {
        block();
        return YES;
    } catch (...) {
        return NO;
    }
}
