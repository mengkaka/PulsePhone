package direct

import (
	"errors"
	"os"
	"testing"
	"time"
)

func TestRealDeviceDirectBrowseAndMountedSmoke(t *testing.T) {
	udid := os.Getenv("PULSEPHONE_REAL_DEVICE_UDID")
	if udid == "" {
		t.Skip("set PULSEPHONE_REAL_DEVICE_UDID to run the physical-device smoke")
	}
	deadline := time.Now().Add(45 * time.Second)

	apps, failure := browseApps(udid, deadline)
	if failure != nil {
		t.Fatalf("browse apps: %s", failure.Code)
	}
	list, ok := apps["apps"].([]any)
	if !ok || len(list) == 0 {
		t.Fatalf("browse result = %#v", apps)
	}
	t.Logf("direct InstallationProxy browse returned %d applications", len(list))

	mounted, failure := queryMounted(udid, deadline)
	if failure != nil {
		t.Fatalf("query mounted: %s", failure.Code)
	}
	if mounted["imageType"] != "Developer" {
		t.Fatalf("mounted result = %#v", mounted)
	}
	t.Logf("classic Developer image mounted=%v", mounted["mounted"])
}

func TestRealDeviceScreenshotProviderSmoke(t *testing.T) {
	udid := os.Getenv("PULSEPHONE_REAL_DEVICE_UDID")
	dvtExpectation := os.Getenv("PULSEPHONE_REAL_DEVICE_DVT_EXPECTATION")
	if udid == "" || os.Getenv("PULSEPHONE_REAL_DEVICE_PROVIDER_SMOKE") != "1" || dvtExpectation == "" {
		t.Skip("set PULSEPHONE_REAL_DEVICE_UDID, PULSEPHONE_REAL_DEVICE_PROVIDER_SMOKE=1, and PULSEPHONE_REAL_DEVICE_DVT_EXPECTATION=succeeded|developerServicesUnavailable to run provider smoke")
	}
	if dvtExpectation != "succeeded" && dvtExpectation != "developerServicesUnavailable" {
		t.Fatalf("unsupported DVT expectation %q", dvtExpectation)
	}

	t.Run("dvt", func(t *testing.T) {
		image, format, err := CaptureDVTScreenshot(udid, time.Now().Add(60*time.Second))
		if dvtExpectation == "developerServicesUnavailable" {
			var failure *Failure
			if !errors.As(err, &failure) || failure.Code != dvtExpectation {
				t.Fatalf("DVT expected %s, image bytes=%d format=%q error=%v", dvtExpectation, len(image), format, err)
			}
			t.Logf("DVT expected unavailable code=%s", failure.Code)
			return
		}
		if err != nil {
			t.Fatalf("DVT screenshot: %v", err)
		}
		if len(image) == 0 || (format != "png" && format != "jpeg") {
			t.Fatalf("DVT screenshot format=%q bytes=%d", format, len(image))
		}
		t.Logf("DVT screenshot bytes=%d format=%s", len(image), format)
	})

	t.Run("axAudit", func(t *testing.T) {
		image, format, err := CaptureAXAuditScreenshot(udid, time.Now().Add(60*time.Second))
		if err != nil {
			t.Fatalf("AXAudit screenshot: %v", err)
		}
		if len(image) == 0 || (format != "png" && format != "jpeg") {
			t.Fatalf("AXAudit screenshot format=%q bytes=%d", format, len(image))
		}
		t.Logf("AXAudit screenshot bytes=%d format=%s", len(image), format)
	})
}
