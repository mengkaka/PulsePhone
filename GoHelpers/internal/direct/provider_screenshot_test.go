package direct

import (
	"errors"
	"net"
	"testing"
	"time"
)

func TestScreenshotBytesAcceptsOnlyBoundedPNGJPEGAndTIFF(t *testing.T) {
	png := append([]byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}, []byte("png")...)
	image, format, err := screenshotBytes(png)
	if err != nil || format != "png" || string(image) != string(png) {
		t.Fatalf("png result format=%q image=%x err=%v", format, image, err)
	}
	jpeg := []byte{0xff, 0xd8, 0xff, 0xd9}
	if _, format, err := screenshotBytes(jpeg); err != nil || format != "jpeg" {
		t.Fatalf("jpeg result format=%q err=%v", format, err)
	}
	tiff := []byte{'I', 'I', 42, 0}
	if _, format, err := screenshotBytes(tiff); err != nil || format != "tiff" {
		t.Fatalf("tiff result format=%q err=%v", format, err)
	}
	if _, _, err := screenshotBytes([]byte("not-an-image")); err == nil {
		t.Fatal("invalid image accepted")
	}
}

func TestLargestScreenshotSelectsLargestNestedImage(t *testing.T) {
	small := append([]byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}, []byte("small")...)
	large := append([]byte{0xff, 0xd8, 0xff}, []byte("larger-image")...)
	value := map[string]any{
		"metadata": []any{"ignored", map[string]any{"image": small}},
		"result":   []any{map[string]any{"image": large}},
	}
	image, err := largestScreenshot(value)
	if err != nil || string(image) != string(large) {
		t.Fatalf("image=%x err=%v", image, err)
	}
}

func TestLargestScreenshotRejectsMissingOrTooDeepPayload(t *testing.T) {
	if _, err := largestScreenshot(map[string]any{"value": "no image"}); err == nil {
		t.Fatal("missing image accepted")
	}
	value := any(map[string]any{})
	for index := 0; index < maximumAXAuditDepth+2; index++ {
		value = map[string]any{"next": value}
	}
	if _, err := largestScreenshot(value); err == nil {
		t.Fatal("deep AXAudit response accepted")
	}
}

func TestScreenshotProviderErrorsSeparateServiceOpenFromCapture(t *testing.T) {
	deadline := time.Now().Add(time.Second)
	client, server := net.Pipe()
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	_, _, err := captureDVTScreenshotConnection(client, deadline)
	if stage := ScreenshotProviderFailureStage(err, "fallback"); stage != "dvtScreenshotServiceOpen" {
		t.Fatalf("DVT handshake stage = %q", stage)
	}

	for _, test := range []struct {
		name    string
		capture func(net.Conn, time.Time) ([]byte, string, error)
		stage   string
		method  string
		channel bool
	}{
		{
			name:    "dvt",
			capture: captureDVTScreenshotConnection,
			stage:   "dvtScreenshotCaptureOrValidate",
			method:  dvtScreenshotMethod,
			channel: true,
		},
		{
			name:    "axaudit",
			capture: captureAXAuditScreenshotConnection,
			stage:   "axAuditScreenshotCaptureOrValidate",
			method:  axAuditScreenshotMethod,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			client, server := net.Pipe()
			serverDone := make(chan error, 1)
			go func() {
				defer server.Close()
				serverDone <- serveScreenshotProviderUntilCapture(server, deadline, test.method, test.channel)
			}()
			_, _, err := test.capture(client, deadline)
			if stage := ScreenshotProviderFailureStage(err, "fallback"); stage != test.stage {
				t.Fatalf("capture stage = %q, want %q (err=%v)", stage, test.stage, err)
			}
			if serverErr := <-serverDone; serverErr != nil {
				t.Fatal(serverErr)
			}
		})
	}

	if stage := ScreenshotProviderFailureStage(errors.New("untyped"), "fallback"); stage != "fallback" {
		t.Fatalf("fallback stage = %q", stage)
	}
}

func TestScreenshotSessionsReuseEstablishedDTXChannel(t *testing.T) {
	png := append([]byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}, []byte("session")...)
	deadline := time.Now().Add(time.Second)
	for _, test := range []struct {
		name       string
		open       func(net.Conn, time.Time) (func(time.Time) ([]byte, string, error), func() error, error)
		method     string
		useChannel bool
		wantFormat string
	}{
		{
			name: "dvt",
			open: func(conn net.Conn, deadline time.Time) (func(time.Time) ([]byte, string, error), func() error, error) {
				session, err := openDVTScreenshotSession(conn, deadline)
				if err != nil {
					return nil, nil, err
				}
				return session.Capture, session.Close, nil
			},
			method:     dvtScreenshotMethod,
			useChannel: true,
			wantFormat: "png",
		},
		{
			name: "axaudit",
			open: func(conn net.Conn, deadline time.Time) (func(time.Time) ([]byte, string, error), func() error, error) {
				session, err := openAXAuditScreenshotSession(conn, deadline)
				if err != nil {
					return nil, nil, err
				}
				return session.Capture, session.Close, nil
			},
			method:     axAuditScreenshotMethod,
			useChannel: false,
			wantFormat: "png",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			client, server := net.Pipe()
			serverDone := make(chan error, 1)
			go func() {
				defer server.Close()
				serverDone <- serveScreenshotProviderCaptures(server, deadline, test.method, test.useChannel, png, 2)
			}()
			capture, closeSession, err := test.open(client, deadline)
			if err != nil {
				t.Fatal(err)
			}
			for captureIndex := 0; captureIndex < 2; captureIndex++ {
				image, format, err := capture(deadline)
				if err != nil || string(image) != string(png) || format != test.wantFormat {
					t.Fatalf("capture %d image=%x format=%q err=%v", captureIndex, image, format, err)
				}
			}
			if err := closeSession(); err != nil {
				t.Fatal(err)
			}
			if err := <-serverDone; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func serveScreenshotProviderUntilCapture(conn net.Conn, deadline time.Time, wantMethod string, useChannel bool) error {
	peer := newDTXConnection(conn, deadline)
	initial, err := peer.receive()
	if err != nil {
		return err
	}
	method, args, err := decodeDTXInvocation(initial)
	if err != nil || method != "_notifyOfPublishedCapabilities:" {
		return errors.New("missing client DTX capability announcement")
	}
	if wantMethod == dvtScreenshotMethod {
		capabilities, ok := args[0].(map[string]any)
		if !ok || capabilities[dvtTerminationCapability] != int64(1) {
			return errors.New("missing DVT termination capability")
		}
	}
	if _, err := peer.sendDispatch(0, "_notifyOfPublishedCapabilities:", []any{map[string]any{}}, false); err != nil {
		return err
	}
	if useChannel {
		channelRequest, err := peer.receive()
		if err != nil {
			return err
		}
		method, _, err = decodeDTXInvocation(channelRequest)
		if err != nil || method != "_requestChannelWithCode:identifier:" {
			return errors.New("missing DVT screenshot channel request")
		}
		if _, err := peer.send(dtxMessage{
			typ:          0,
			identifier:   channelRequest.identifier,
			conversation: 1,
			channel:      channelRequest.channel,
		}); err != nil {
			return err
		}
	}
	captureRequest, err := peer.receive()
	if err != nil {
		return err
	}
	method, _, err = decodeDTXInvocation(captureRequest)
	if err != nil || method != wantMethod {
		return errors.New("missing screenshot capture request")
	}
	return nil // Closing the pipe now makes the capture request fail after service setup.
}

func serveScreenshotProviderCaptures(conn net.Conn, deadline time.Time, wantMethod string, useChannel bool, image []byte, captures int) error {
	peer := newDTXConnection(conn, deadline)
	initial, err := peer.receive()
	if err != nil {
		return err
	}
	method, _, err := decodeDTXInvocation(initial)
	if err != nil || method != "_notifyOfPublishedCapabilities:" {
		return errors.New("missing client DTX capability announcement")
	}
	if _, err := peer.sendDispatch(0, "_notifyOfPublishedCapabilities:", []any{map[string]any{}}, false); err != nil {
		return err
	}
	if useChannel {
		channelRequest, err := peer.receive()
		if err != nil {
			return err
		}
		method, _, err = decodeDTXInvocation(channelRequest)
		if err != nil || method != "_requestChannelWithCode:identifier:" {
			return errors.New("missing DVT screenshot channel request")
		}
		if _, err := peer.send(dtxMessage{
			typ:          0,
			identifier:   channelRequest.identifier,
			conversation: 1,
			channel:      channelRequest.channel,
		}); err != nil {
			return err
		}
	}
	for index := 0; index < captures; index++ {
		captureRequest, err := peer.receive()
		if err != nil {
			return err
		}
		method, _, err = decodeDTXInvocation(captureRequest)
		if err != nil || method != wantMethod {
			return errors.New("missing screenshot capture request")
		}
		payload, err := encodeNSKeyedArchive(image)
		if err != nil {
			return err
		}
		if _, err := peer.send(dtxMessage{
			typ:          3,
			identifier:   captureRequest.identifier,
			conversation: 1,
			channel:      captureRequest.channel,
			payload:      payload,
		}); err != nil {
			return err
		}
	}
	return nil
}
