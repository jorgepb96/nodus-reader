// SPDX-License-Identifier: AGPL-3.0-only
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns NO if it threw an Objective-C or C++ exception.
///
/// Swift cannot catch either, and an exception that leaves a system framework
/// through a Swift frame ends the process. PDFKit's text layout throws
/// `std::bad_alloc` on some pages (dense indexes); this lets the caller treat
/// such a page as having no text layer instead.
FOUNDATION_EXPORT BOOL NodusPerformCatchingExceptions(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
