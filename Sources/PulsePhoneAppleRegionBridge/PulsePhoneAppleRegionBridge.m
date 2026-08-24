#import "PulsePhoneAppleRegionBridge.h"

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

struct PPAppleRegionBridge {
    void *auditHandle;
    void *understandingHandle;
    void *manager;
};

static const size_t PPMaximumImageBytes = 16 * 1024 * 1024;
static const size_t PPMaximumRegions = 2048;

static int32_t PPDetect(
    PPAppleRegionBridge *bridge,
    NSData *imageData,
    PPAppleDetectedRegion **regions,
    size_t *regionCount
) {
    if (bridge == NULL || bridge->manager == NULL || imageData == nil ||
        regions == NULL || regionCount == NULL) {
        return PPAppleRegionBridgeStatusInvalidImage;
    }
    id result = nil;
    @try {
        id manager = (__bridge id)bridge->manager;
        result = ((id (*)(id, SEL, id))objc_msgSend)(
            manager,
            sel_registerName("detectionResultsFromImageData:"),
            imageData
        );
    } @catch (__unused NSException *exception) {
        return PPAppleRegionBridgeStatusException;
    }
    if (![result isKindOfClass:[NSArray class]]) {
        return PPAppleRegionBridgeStatusInvalidResult;
    }
    NSArray *items = result;
    if (items.count > PPMaximumRegions) {
        return PPAppleRegionBridgeStatusInvalidResult;
    }
    PPAppleDetectedRegion *output = items.count == 0
        ? NULL : calloc(items.count, sizeof(PPAppleDetectedRegion));
    if (items.count > 0 && output == NULL) {
        return PPAppleRegionBridgeStatusAllocationFailed;
    }
    size_t index = 0;
    for (id item in items) {
        SEL regionSelector = sel_registerName("detectionRegion");
        SEL typeSelector = sel_registerName("detectionType");
        if (![item respondsToSelector:regionSelector] ||
            ![item respondsToSelector:typeSelector]) {
            free(output);
            return PPAppleRegionBridgeStatusInvalidResult;
        }
        CGRect region = ((CGRect (*)(id, SEL))objc_msgSend)(item, regionSelector);
        NSInteger detectionType = ((NSInteger (*)(id, SEL))objc_msgSend)(
            item, typeSelector
        );
        if (!isfinite(region.origin.x) || !isfinite(region.origin.y) ||
            !isfinite(region.size.width) || !isfinite(region.size.height) ||
            region.origin.x < 0 || region.origin.y < 0 ||
            region.size.width <= 0 || region.size.height <= 0) {
            free(output);
            return PPAppleRegionBridgeStatusInvalidResult;
        }
        output[index++] = (PPAppleDetectedRegion){
            .x = region.origin.x,
            .y = region.origin.y,
            .width = region.size.width,
            .height = region.size.height,
            .detectionType = detectionType,
        };
    }
    *regions = output;
    *regionCount = index;
    return PPAppleRegionBridgeStatusSucceeded;
}

PPAppleRegionBridge *PPAppleRegionBridgeCreate(int32_t *status) {
    @autoreleasepool {
        if (status == NULL) return NULL;
        *status = PPAppleRegionBridgeStatusFrameworkUnavailable;
        PPAppleRegionBridge *bridge = calloc(1, sizeof(PPAppleRegionBridge));
        if (bridge == NULL) {
            *status = PPAppleRegionBridgeStatusAllocationFailed;
            return NULL;
        }
        bridge->auditHandle = dlopen(
            "/System/Library/PrivateFrameworks/AccessibilityAudit.framework/AccessibilityAudit",
            RTLD_NOW | RTLD_GLOBAL
        );
        bridge->understandingHandle = dlopen(
            "/System/Library/PrivateFrameworks/UIUnderstanding.framework/UIUnderstanding",
            RTLD_NOW | RTLD_GLOBAL
        );
        if (bridge->auditHandle == NULL || bridge->understandingHandle == NULL) {
            PPAppleRegionBridgeDestroy(bridge);
            return NULL;
        }
        Class managerClass = NSClassFromString(@"AXAuditImageDetectionManager");
        Class deduplicatorClass = NSClassFromString(@"AXAuditDeduplicator");
        SEL availabilitySelector = sel_registerName("isFrameworkAvailable");
        SEL sharedSelector = sel_registerName("sharedManager");
        SEL detectionSelector = sel_registerName("detectionResultsFromImageData:");
        if (managerClass == Nil || deduplicatorClass == Nil ||
            ![deduplicatorClass respondsToSelector:availabilitySelector] ||
            !((BOOL (*)(id, SEL))objc_msgSend)(deduplicatorClass, availabilitySelector) ||
            ![managerClass respondsToSelector:sharedSelector]) {
            *status = PPAppleRegionBridgeStatusCapabilityUnavailable;
            PPAppleRegionBridgeDestroy(bridge);
            return NULL;
        }
        id manager = nil;
        @try {
            manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, sharedSelector);
        } @catch (__unused NSException *exception) {
            *status = PPAppleRegionBridgeStatusException;
            PPAppleRegionBridgeDestroy(bridge);
            return NULL;
        }
        if (manager == nil || ![manager respondsToSelector:detectionSelector]) {
            *status = PPAppleRegionBridgeStatusCapabilityUnavailable;
            PPAppleRegionBridgeDestroy(bridge);
            return NULL;
        }
        bridge->manager = (__bridge_retained void *)manager;

        // A real bounded selector call catches missing assets and return-shape drift.
        NSString *pixel = @"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
        NSData *selfTestImage = [[NSData alloc] initWithBase64EncodedString:pixel options:0];
        PPAppleDetectedRegion *testRegions = NULL;
        size_t testCount = 0;
        int32_t selfTest = PPDetect(
            bridge, selfTestImage, &testRegions, &testCount
        );
        free(testRegions);
        if (selfTest != PPAppleRegionBridgeStatusSucceeded) {
            *status = selfTest;
            PPAppleRegionBridgeDestroy(bridge);
            return NULL;
        }
        *status = PPAppleRegionBridgeStatusSucceeded;
        return bridge;
    }
}

void PPAppleRegionBridgeDestroy(PPAppleRegionBridge *bridge) {
    if (bridge == NULL) return;
    if (bridge->manager != NULL) {
        CFBridgingRelease(bridge->manager);
        bridge->manager = NULL;
    }
    if (bridge->understandingHandle != NULL) {
        dlclose(bridge->understandingHandle);
    }
    if (bridge->auditHandle != NULL) {
        dlclose(bridge->auditHandle);
    }
    free(bridge);
}

int32_t PPAppleRegionBridgeDetect(
    PPAppleRegionBridge *bridge,
    const uint8_t *imageBytes,
    size_t imageLength,
    uint64_t expectedWidth,
    uint64_t expectedHeight,
    PPAppleDetectedRegion **regions,
    size_t *regionCount
) {
    @autoreleasepool {
        if (imageBytes == NULL || imageLength == 0 ||
            imageLength > PPMaximumImageBytes || regions == NULL || regionCount == NULL) {
            return PPAppleRegionBridgeStatusInvalidImage;
        }
        *regions = NULL;
        *regionCount = 0;
        NSData *image = [NSData dataWithBytesNoCopy:(void *)imageBytes
                                             length:imageLength
                                       freeWhenDone:NO];
        CGImageSourceRef source = CGImageSourceCreateWithData(
            (__bridge CFDataRef)image, NULL
        );
        CGImageRef decoded = source == NULL
            ? NULL : CGImageSourceCreateImageAtIndex(source, 0, NULL);
        BOOL validDimensions = decoded != NULL
            && CGImageGetWidth(decoded) == expectedWidth
            && CGImageGetHeight(decoded) == expectedHeight;
        if (decoded != NULL) CGImageRelease(decoded);
        if (source != NULL) CFRelease(source);
        if (!validDimensions) {
            return PPAppleRegionBridgeStatusInvalidImage;
        }
        return PPDetect(bridge, image, regions, regionCount);
    }
}

void PPAppleRegionBridgeFreeRegions(PPAppleDetectedRegion *regions) {
    free(regions);
}
