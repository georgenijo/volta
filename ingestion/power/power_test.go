package power

import (
	"math"
	"testing"
)

func TestKw(t *testing.T) {
	if Kw(400, 50, Unverified) != nil {
		t.Fatal("unverified sign produced power")
	}
	if p := Kw(400, 50, DischargePositive); p == nil || *p != 20 {
		t.Fatalf("got %v", p)
	}
	if p := Kw(400, 50, DischargeNegative); p == nil || *p != -20 {
		t.Fatalf("got %v", p)
	}
	if Kw(0, 50, DischargePositive) != nil || Kw(400, math.Inf(1), DischargePositive) != nil {
		t.Fatal("implausible inputs produced power")
	}
	for _, s := range []Sign{Unverified, DischargePositive, DischargeNegative} {
		if ParseSign(s.String()) != s {
			t.Fatalf("round trip %v", s)
		}
	}
	if ParseSign("guessed") != Unverified {
		t.Fatal("unknown sign text verified")
	}
}
