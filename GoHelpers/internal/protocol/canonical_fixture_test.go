package protocol

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

type canonicalFixture struct {
	Expectation  string `json:"expectation"`
	ExpectedHash string `json:"expectedSHA256"`
	InputHex     string `json:"inputHex"`
	Name         string `json:"name"`
}

func TestCanonicalJSONSharedFixture(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	fixturePath := filepath.Join(filepath.Dir(sourceFile), "..", "..", "..", "Fixtures", "contracts", "canonical-json", "cases.v1.jsonl")
	file, err := os.Open(fixturePath)
	if err != nil {
		t.Fatalf("open canonical fixture: %v", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 1024), 2*1024*1024)
	count := 0
	for scanner.Scan() {
		var fixture canonicalFixture
		if err := json.Unmarshal(scanner.Bytes(), &fixture); err != nil {
			t.Fatalf("decode fixture line %d: %v", count+1, err)
		}
		input, err := hex.DecodeString(fixture.InputHex)
		if err != nil {
			t.Fatalf("decode %s input: %v", fixture.Name, err)
		}
		document, validationErr := ValidateDocument(input, len(input))
		if fixture.Expectation == "canonical" {
			if validationErr != nil {
				t.Fatalf("fixture %s rejected: %v", fixture.Name, validationErr)
			}
			digest := sha256.Sum256(input)
			if got := hex.EncodeToString(digest[:]); got != fixture.ExpectedHash {
				t.Fatalf("fixture %s hash=%s, want %s", fixture.Name, got, fixture.ExpectedHash)
			}
		} else if fixture.Expectation == "rejectUInt64" || fixture.Expectation == "rejectInt64" {
			if validationErr != nil {
				t.Fatalf("fixture %s rejected before domain check: %v", fixture.Name, validationErr)
			}
			value, exists := document.Root["value"]
			if !exists {
				t.Fatalf("fixture %s has no value field", fixture.Name)
			}
			var domainErr error
			if fixture.Expectation == "rejectUInt64" {
				_, domainErr = RequireUInt64(value)
			} else {
				_, domainErr = RequireInt64(value)
			}
			if canonicalErrorKind(domainErr) != map[string]string{"rejectUInt64": "integerNotUInt64", "rejectInt64": "integerNotInt64"}[fixture.Expectation] {
				t.Fatalf("fixture %s domain error=%v", fixture.Name, domainErr)
			}
		} else {
			if validationErr == nil {
				t.Fatalf("fixture %s unexpectedly accepted", fixture.Name)
			}
			if kind := canonicalErrorKind(validationErr); kind != fixture.Expectation {
				t.Fatalf("fixture %s error=%s, want %s (%v)", fixture.Name, kind, fixture.Expectation, validationErr)
			}
		}
		count++
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if count == 0 {
		t.Fatal("canonical fixture is empty")
	}
}

func canonicalErrorKind(err error) string {
	if value, ok := err.(*CanonicalError); ok {
		return value.Kind
	}
	return ""
}
