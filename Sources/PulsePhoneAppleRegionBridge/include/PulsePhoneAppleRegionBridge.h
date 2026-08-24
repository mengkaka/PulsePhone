#ifndef PULSEPHONE_APPLE_REGION_BRIDGE_H
#define PULSEPHONE_APPLE_REGION_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PPAppleRegionBridge PPAppleRegionBridge;

typedef struct {
    double x;
    double y;
    double width;
    double height;
    int64_t detectionType;
} PPAppleDetectedRegion;

enum {
    PPAppleRegionBridgeStatusSucceeded = 0,
    PPAppleRegionBridgeStatusFrameworkUnavailable = 1,
    PPAppleRegionBridgeStatusCapabilityUnavailable = 2,
    PPAppleRegionBridgeStatusInvalidImage = 3,
    PPAppleRegionBridgeStatusInvalidResult = 4,
    PPAppleRegionBridgeStatusException = 5,
    PPAppleRegionBridgeStatusAllocationFailed = 6,
};

PPAppleRegionBridge *PPAppleRegionBridgeCreate(int32_t *status);
void PPAppleRegionBridgeDestroy(PPAppleRegionBridge *bridge);
int32_t PPAppleRegionBridgeDetect(
    PPAppleRegionBridge *bridge,
    const uint8_t *imageBytes,
    size_t imageLength,
    uint64_t expectedWidth,
    uint64_t expectedHeight,
    PPAppleDetectedRegion **regions,
    size_t *regionCount
);
void PPAppleRegionBridgeFreeRegions(PPAppleDetectedRegion *regions);

#ifdef __cplusplus
}
#endif

#endif
