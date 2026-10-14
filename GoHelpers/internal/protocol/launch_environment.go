package protocol

import (
	"errors"
	"strings"
	"unicode/utf8"
)

// LaunchEnvironment validates a decoded Helper payload before opening device services.
// Omitted environment preserves the original empty-map behavior. No error echoes input.
func LaunchEnvironment(payload map[string]any) (map[string]any, error) {
	raw, present := payload["environment"]
	if !present {
		return map[string]any{}, nil
	}
	environment, ok := raw.(map[string]any)
	if !ok || len(environment) > 64 {
		return nil, errors.New("invalid launch environment")
	}
	result := make(map[string]any, len(environment))
	total := 0
	for name, rawValue := range environment {
		value, ok := rawValue.(string)
		if !ok || !validEnvironmentName(name) || !utf8.ValidString(value) || strings.ContainsRune(value, 0) {
			return nil, errors.New("invalid launch environment")
		}
		total += len(name) + len(value)
		if total > 8192 {
			return nil, errors.New("invalid launch environment")
		}
		result[name] = value
	}
	return result, nil
}

func validEnvironmentName(name string) bool {
	if len(name) == 0 || len(name) > 128 {
		return false
	}
	for index, b := range []byte(name) {
		if b == '_' || b >= 'A' && b <= 'Z' || b >= 'a' && b <= 'z' || index > 0 && b >= '0' && b <= '9' {
			continue
		}
		return false
	}
	return true
}
