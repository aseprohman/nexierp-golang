// values.go — aturan serialisasi/parse nilai `core_module_configs` — FUNGSI
// MURNI (padanan domain/config-values.ts NestJS; unit-testable).
// Nilai terserialisasi TEXT di `param_value`; tafsir via `value_type`
// ('string' apa adanya, 'number' cast, 'boolean' 'true'/'false', 'json'
// JSON parse) — serialisasi dibalikkan di sini.
package moduleconfig

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
)

// formatNumberJS — meniru String() JS: bilangan bulat tanpa desimal,
// desimal shortest-repr.
func formatNumberJS(v float64) string {
	if v == math.Trunc(v) && math.Abs(v) < 1e21 {
		return strconv.FormatFloat(v, 'f', -1, 64)
	}
	return strconv.FormatFloat(v, 'g', -1, 64)
}

// labelNumberJS — meniru String() JS untuk nilai non-finite.
func labelNumberJS(v float64) string {
	switch {
	case math.IsNaN(v):
		return "NaN"
	case math.IsInf(v, 1):
		return "Infinity"
	case math.IsInf(v, -1):
		return "-Infinity"
	}
	return formatNumberJS(v)
}

// SerializeConfigValue — serialisasi nilai → pasangan (value_type,
// param_value). Murni (unit-testable): string apa adanya; number String();
// boolean "true"/"false"; null → json "null"; object → JSON.
func SerializeConfigValue(v Value) (string, string, error) {
	switch t := v.(type) {
	case nil:
		return "json", "null", nil
	case string:
		return "string", t, nil
	case float64:
		if math.IsNaN(t) || math.IsInf(t, 0) {
			return "", "", fmt.Errorf("[module-config] nilai number tidak valid: %s", labelNumberJS(t))
		}
		return "number", formatNumberJS(t), nil
	case bool:
		if t {
			return "boolean", "true", nil
		}
		return "boolean", "false", nil
	default:
		raw, err := json.Marshal(t)
		if err != nil {
			return "", "", fmt.Errorf("[module-config] gagal serialisasi JSON: %w", err)
		}
		return "json", string(raw), nil
	}
}

// ParseConfigValue — parse `param_value` sesuai value_type. Murni
// (unit-testable). Angka JSON → float64 persis semantik JSON.
func ParseConfigValue(valueType, raw string) (Value, error) {
	switch valueType {
	case "string":
		return raw, nil
	case "number":
		n, err := strconv.ParseFloat(raw, 64)
		if err != nil || math.IsNaN(n) {
			return nil, fmt.Errorf(
				"[module-config] param_value '%s' bukan number valid (value_type=number).", raw)
		}
		return n, nil
	case "boolean":
		switch raw {
		case "true":
			return true, nil
		case "false":
			return false, nil
		}
		return nil, fmt.Errorf(
			"[module-config] param_value '%s' bukan boolean valid ('true'/'false' diharapkan).", raw)
	case "json":
		var v Value
		if err := json.Unmarshal([]byte(raw), &v); err != nil {
			return nil, fmt.Errorf(
				"[module-config] param_value bukan JSON valid (value_type=json): %s", raw)
		}
		return v, nil
	default:
		return nil, fmt.Errorf("[module-config] value_type '%s' tidak dikenal.", valueType)
	}
}
