package protocol

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

type helperWireFixture struct {
	Cases []helperWireFixtureCase `json:"cases"`
}

type helperWireFixtureCase struct {
	Direction   string `json:"direction"`
	Expectation string `json:"expectation"`
	ExpandCount int    `json:"expandCount"`
	ExpandToken string `json:"expandToken"`
	Line        string `json:"line"`
	Name        string `json:"name"`
}

func TestHelperWireCodecSharedFixture(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	path := filepath.Join(filepath.Dir(sourceFile), "..", "..", "..", "Fixtures", "helper-wire", "codec-parity.v1.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture: %v", err)
	}
	var fixture helperWireFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatalf("decode shared fixture: %v", err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("shared fixture is empty")
	}
	for _, item := range fixture.Cases {
		item := item
		t.Run(item.Name, func(t *testing.T) {
			direction, ok := map[string]Direction{
				"helperToRuntime": HelperToRuntime,
				"runtimeToHelper": RuntimeToHelper,
			}[item.Direction]
			if !ok {
				t.Fatalf("unknown direction %q", item.Direction)
			}
			line := expandHelperWireFixtureLine(t, item)
			_, err := DecodeLine([]byte(line), direction)
			switch item.Expectation {
			case "accept":
				if err != nil {
					t.Fatalf("rejected: %v", err)
				}
			case "reject":
				if err == nil {
					t.Fatal("accepted")
				}
			default:
				t.Fatalf("unknown expectation %q", item.Expectation)
			}
		})
	}
}

func expandHelperWireFixtureLine(t *testing.T, item helperWireFixtureCase) string {
	t.Helper()
	if item.ExpandToken == "" {
		if item.ExpandCount != 0 {
			t.Fatalf("expandCount without expandToken")
		}
		return item.Line
	}
	if item.ExpandCount <= 0 || strings.Count(item.Line, item.ExpandToken) != 1 {
		t.Fatalf("invalid expansion fixture")
	}
	return strings.ReplaceAll(item.Line, item.ExpandToken, strings.Repeat("x", item.ExpandCount))
}
