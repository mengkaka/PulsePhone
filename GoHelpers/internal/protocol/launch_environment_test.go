package protocol

import (
	"reflect"
	"strings"
	"testing"
)

func TestLaunchEnvironmentValidation(t *testing.T) {
	valid := map[string]any{"APP_ENV": "testing", "EMPTY": "", "MESSAGE": "你好 hello=a=b"}
	for _, payload := range []map[string]any{{}, {"environment": valid}, {"environment": map[string]any{}}} {
		result, err := LaunchEnvironment(payload)
		if err != nil {
			t.Fatal(err)
		}
		if payload["environment"] != nil && !reflect.DeepEqual(result, payload["environment"]) {
			t.Fatal("environment changed")
		}
	}
	tooMany := map[string]any{}
	for i := 0; i < 65; i++ {
		tooMany["K"+strings.Repeat("x", i)] = ""
	}
	for _, raw := range []any{nil, "secret", []any{}, map[string]any{"A": 1}, map[string]any{"": "secret"}, map[string]any{"1A": "secret"}, map[string]any{"BAD-NAME": "secret"}, map[string]any{"名": "secret"}, map[string]any{strings.Repeat("A", 129): "secret"}, map[string]any{"A": "secret\x00"}, map[string]any{"A": string([]byte{0xff})}, map[string]any{"A": strings.Repeat("x", 8192)}, tooMany} {
		if _, err := LaunchEnvironment(map[string]any{"environment": raw}); err == nil || strings.Contains(err.Error(), "secret") {
			t.Fatal("invalid environment accepted or echoed")
		}
	}
	if _, err := LaunchEnvironment(map[string]any{"environment": map[string]any{"A": strings.Repeat("x", 8191)}}); err != nil {
		t.Fatal(err)
	}
}
