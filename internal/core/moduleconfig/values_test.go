// values_test.go — unit test fungsi murni moduleconfig
// (SerializeConfigValue, ParseConfigValue, KunciOverrideOutlet).
package moduleconfig

import (
	"math"
	"reflect"
	"testing"
)

func TestSerializeConfigValue(t *testing.T) {
	kasus := []struct {
		nama     string
		v        Value
		mauTipe  string
		mauRaw   string
		mauGagal bool
	}{
		{nama: "string apa adanya", v: "abc", mauTipe: "string", mauRaw: "abc"},
		{nama: "string kosong", v: "", mauTipe: "string", mauRaw: ""},
		{nama: "number bulat", v: float64(100), mauTipe: "number", mauRaw: "100"},
		{nama: "number desimal", v: 1.5, mauTipe: "number", mauRaw: "1.5"},
		{nama: "number nol", v: float64(0), mauTipe: "number", mauRaw: "0"},
		{nama: "boolean true", v: true, mauTipe: "boolean", mauRaw: "true"},
		{nama: "boolean false", v: false, mauTipe: "boolean", mauRaw: "false"},
		{nama: "null → json null", v: nil, mauTipe: "json", mauRaw: "null"},
		{nama: "object → json", v: map[string]any{"a": float64(1)}, mauTipe: "json", mauRaw: `{"a":1}`},
		{nama: "array → json", v: []any{float64(1), "x"}, mauTipe: "json", mauRaw: `[1,"x"]`},
		{nama: "NaN gagal", v: math.NaN(), mauGagal: true},
		{nama: "Inf gagal", v: math.Inf(1), mauGagal: true},
	}
	for _, k := range kasus {
		valueType, raw, err := SerializeConfigValue(k.v)
		if k.mauGagal {
			if err == nil {
				t.Errorf("%s: harus gagal, dapat (%s,%q)", k.nama, valueType, raw)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: err tak terduga: %v", k.nama, err)
			continue
		}
		if valueType != k.mauTipe || raw != k.mauRaw {
			t.Errorf("%s: dapat (%s,%q), mau (%s,%q)", k.nama, valueType, raw, k.mauTipe, k.mauRaw)
		}
	}
}

func TestParseConfigValue(t *testing.T) {
	kasus := []struct {
		nama      string
		valueType string
		raw       string
		mau       Value
		mauGagal  bool
	}{
		{nama: "string", valueType: "string", raw: "teks bebas", mau: "teks bebas"},
		{nama: "number", valueType: "number", raw: "3.25", mau: 3.25},
		{nama: "number negatif", valueType: "number", raw: "-7", mau: float64(-7)},
		{nama: "number invalid", valueType: "number", raw: "abc", mauGagal: true},
		{nama: "boolean true", valueType: "boolean", raw: "true", mau: true},
		{nama: "boolean false", valueType: "boolean", raw: "false", mau: false},
		{nama: "boolean invalid", valueType: "boolean", raw: "TRUE", mauGagal: true},
		{nama: "json object", valueType: "json", raw: `{"a":1}`, mau: map[string]any{"a": float64(1)}},
		{nama: "json null", valueType: "json", raw: "null", mau: nil},
		{nama: "json invalid", valueType: "json", raw: "{", mauGagal: true},
		{nama: "tipe tak dikenal", valueType: "teks", raw: "x", mauGagal: true},
	}
	for _, k := range kasus {
		got, err := ParseConfigValue(k.valueType, k.raw)
		if k.mauGagal {
			if err == nil {
				t.Errorf("%s: harus gagal, dapat %v", k.nama, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: err tak terduga: %v", k.nama, err)
			continue
		}
		if !reflect.DeepEqual(got, k.mau) {
			t.Errorf("%s: dapat %#v, mau %#v", k.nama, got, k.mau)
		}
	}
}

func TestRoundTripConfigValue(t *testing.T) {
	nilai := []Value{"teks", float64(42), 0.75, true, false, nil,
		map[string]any{"x": float64(1), "y": "z"}, []any{true, float64(2)}}
	for _, v := range nilai {
		vt, raw, err := SerializeConfigValue(v)
		if err != nil {
			t.Fatalf("serialize %#v: %v", v, err)
		}
		back, err := ParseConfigValue(vt, raw)
		if err != nil {
			t.Fatalf("parse %q: %v", raw, err)
		}
		if !reflect.DeepEqual(back, v) {
			t.Errorf("round-trip %#v → %q → %#v", v, raw, back)
		}
	}
}

func TestKunciOverrideOutlet(t *testing.T) {
	if got := KunciOverrideOutlet("CFG-POS-02", int64(17)); got != "CFG-POS-02@outlet:17" {
		t.Errorf("KunciOverrideOutlet = %q, mau %q", got, "CFG-POS-02@outlet:17")
	}
	if got := KunciOverrideOutlet("opname.reconcile_auto_approve_max_value", int64(1)); got != "opname.reconcile_auto_approve_max_value@outlet:1" {
		t.Errorf("KunciOverrideOutlet = %q", got)
	}
}
