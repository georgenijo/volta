package vehicles

import (
	"errors"
	"strings"
	"testing"

	"github.com/georgenijo/volta/ingestion/internal/testvin"
)

func TestParseAndLookup(t *testing.T) {
	a, err := Parse(testvin.Mapping)
	if err != nil {
		t.Fatal(err)
	}
	if a.Len() != 2 {
		t.Fatalf("len %d", a.Len())
	}
	if id, err := a.Lookup(testvin.A); err != nil || id != 1 {
		t.Fatalf("A -> %d %v", id, err)
	}
	if _, err := a.Lookup(testvin.Rogue); !errors.Is(err, ErrUnregistered) {
		t.Fatalf("rogue VIN accepted: %v", err)
	}
	// Exact match only: case or whitespace variants are not the same VIN.
	for _, v := range []string{strings.ToLower(testvin.A), " " + testvin.A, testvin.A[:16]} {
		if _, err := a.Lookup(v); err == nil {
			t.Fatalf("variant %q accepted", v)
		}
	}
	bindings := a.Bindings()
	if len(bindings) != 2 || len(bindings[1]) != 64 || bindings[1] == bindings[2] {
		t.Fatalf("bindings are not unique SHA-256 digests: %#v", bindings)
	}
	if got, want := bindings[1], "1805a6f5184419493be9727a11fc7b3576f2647ef7dcf2c8d591d00a84adfd7f"; got != want {
		t.Fatalf("binding digest = %q, want cross-language fixture %q", got, want)
	}
	for _, digest := range bindings {
		if strings.Contains(digest, testvin.A) || strings.Contains(digest, testvin.B) {
			t.Fatal("binding exposed a VIN")
		}
	}
}

func TestParseRejectsBadMappingsWithoutLeakingVIN(t *testing.T) {
	cases := map[string]string{
		"empty":     ``,
		"array":     `["` + testvin.A + `"]`,
		"zero id":   `{"0":"` + testvin.A + `"}`,
		"text id":   `{"x":"` + testvin.A + `"}`,
		"short vin": `{"1":"5YJ3E1EA0XF00000"}`,
		"bad char":  `{"1":"5YJ3E1EA0XF00000O"}`,
		"dup vin":   `{"1":"` + testvin.A + `","2":"` + testvin.A + `"}`,
		// Two VINs aliasing one vehicle id.
		"leading zero":   `{"1":"` + testvin.A + `","01":"` + testvin.B + `"}`,
		"plus sign":      `{"+2":"` + testvin.B + `"}`,
		"space":          `{" 2":"` + testvin.B + `"}`,
		"duplicate key":  `{"1":"` + testvin.A + `","1":"` + testvin.B + `"}`,
		"vin as id":      `{"` + testvin.A + `":"` + testvin.B + `"}`,
		"non string vin": `{"1":17}`,
		"trailing data":  `{"1":"` + testvin.A + `"} {}`,
		"empty object":   `{}`,
		"huge id":        `{"9999999999":"` + testvin.A + `"}`,
	}
	for name, raw := range cases {
		_, err := Parse(raw)
		if err == nil {
			t.Errorf("%s: accepted", name)
			continue
		}
		if strings.Contains(err.Error(), "5YJ3E1EA0XF") {
			t.Errorf("%s: error leaks VIN: %v", name, err)
		}
	}
}
