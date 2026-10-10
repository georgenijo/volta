package session

import (
	"testing"
	"time"
)

var t0 = time.Date(2026, 10, 8, 17, 0, 0, 0, time.UTC)

func at(s int) time.Time     { return t0.Add(time.Duration(s) * time.Second) }
func mph(v float64) *float64 { return &v }

func drivePoints(start, end, step int) []Point {
	var ps []Point
	for s := start; s <= end; s += step {
		ps = append(ps, Point{TS: at(s), SpeedMph: mph(30)})
	}
	return ps
}

func connected(id string, s int) ConnEvent {
	return ConnEvent{TS: at(s), ConnectionID: id, Status: "CONNECTED"}
}
func disconnected(id string, s int) ConnEvent {
	return ConnEvent{TS: at(s), ConnectionID: id, Status: "DISCONNECTED"}
}

func TestCompleteDrive(t *testing.T) {
	ps := []Point{{TS: at(0), Gear: "ShiftStateP"}, {TS: at(10), Gear: "ShiftStateD"}}
	ps = append(ps, drivePoints(20, 600, 10)...)
	ps = append(ps, Point{TS: at(610), Gear: "ShiftStateP", SpeedMph: mph(0)})
	r := Derive(ps, []ConnEvent{connected("c1", -5)}, Seed{}, DefaultOptions)
	if len(r.Sessions) != 1 {
		t.Fatalf("sessions %+v", r.Sessions)
	}
	s := r.Sessions[0]
	if s.Kind != KindDrive || !s.Start.Equal(at(10)) || !s.End.Equal(at(610)) || s.StartReason != ReasonGear || s.EndReason != ReasonGear || s.Membership != Complete {
		t.Fatalf("drive %+v", s)
	}
	if len(r.Gaps) != 0 {
		t.Fatalf("gaps %+v", r.Gaps)
	}
}

func TestStartNotObservedIsPartial(t *testing.T) {
	// Data begins mid-drive: speed > 0, no gear seen yet.
	ps := drivePoints(0, 300, 10)
	ps = append(ps, Point{TS: at(310), Gear: "ShiftStateP"})
	r := Derive(ps, []ConnEvent{connected("c1", -5)}, Seed{}, DefaultOptions)
	if len(r.Sessions) != 1 || r.Sessions[0].StartReason != ReasonSpeed || r.Sessions[0].Membership != Partial {
		t.Fatalf("%+v", r.Sessions)
	}
	// Gear D seen first without a previous gear.
	r = Derive([]Point{{TS: at(0), Gear: "ShiftStateD"}, {TS: at(60), Gear: "ShiftStateP"}}, []ConnEvent{connected("c1", -5)}, Seed{}, DefaultOptions)
	if r.Sessions[0].StartReason != ReasonFirstObserved || r.Sessions[0].Membership != Partial {
		t.Fatalf("%+v", r.Sessions)
	}
}

func TestSilenceWhileConnectedIsUnchanged(t *testing.T) {
	// Parked at a light for 10 minutes: no payloads, connection stayed up.
	ps := []Point{{TS: at(0), Gear: "ShiftStateP"}, {TS: at(10), Gear: "ShiftStateD"}}
	ps = append(ps, drivePoints(20, 100, 10)...)
	ps = append(ps, drivePoints(700, 800, 10)...)
	ps = append(ps, Point{TS: at(810), Gear: "ShiftStateP"})
	r := Derive(ps, []ConnEvent{connected("c1", -5)}, Seed{}, DefaultOptions)
	if len(r.Gaps) != 0 || len(r.Sessions) != 1 || r.Sessions[0].Membership != Complete {
		t.Fatalf("gaps %+v sessions %+v", r.Gaps, r.Sessions)
	}
}

func TestDisconnectInsideDriveIsGap(t *testing.T) {
	ps := []Point{{TS: at(0), Gear: "ShiftStateP"}, {TS: at(10), Gear: "ShiftStateD"}}
	ps = append(ps, drivePoints(20, 100, 10)...)
	ps = append(ps, drivePoints(700, 800, 10)...)
	ps = append(ps, Point{TS: at(810), Gear: "ShiftStateP"})
	conns := []ConnEvent{connected("c1", -5), disconnected("c1", 150), connected("c2", 690)}
	r := Derive(ps, conns, Seed{}, DefaultOptions)
	if len(r.Gaps) != 1 || r.Gaps[0].Reason != GapDisconnected || !r.Gaps[0].Start.Equal(at(100)) || !r.Gaps[0].End.Equal(at(700)) {
		t.Fatalf("gaps %+v", r.Gaps)
	}
	if len(r.Sessions) != 1 || r.Sessions[0].Membership != Partial || len(r.Sessions[0].Gaps) != 1 {
		t.Fatalf("sessions %+v", r.Sessions)
	}
}

func TestSilenceWithoutEvidenceIsGap(t *testing.T) {
	ps := append(drivePoints(0, 60, 10), drivePoints(700, 760, 10)...)
	r := Derive(ps, nil, Seed{LastGear: "ShiftStateD", LastPayload: at(-10)}, DefaultOptions)
	if len(r.Gaps) != 1 || r.Gaps[0].Reason != GapSilence {
		t.Fatalf("gaps %+v", r.Gaps)
	}
}

func TestLongGapSplitsAndForgetsGear(t *testing.T) {
	ps := []Point{{TS: at(0), Gear: "ShiftStateD"}}
	ps = append(ps, drivePoints(10, 100, 10)...)
	// 2 hours later, still moving, gear unknown after the gap.
	ps = append(ps, drivePoints(7300, 7400, 10)...)
	ps = append(ps, Point{TS: at(7410), Gear: "ShiftStateP"})
	r := Derive(ps, []ConnEvent{connected("c1", -5), disconnected("c1", 200), connected("c2", 7290)}, Seed{LastGear: "ShiftStateP"}, DefaultOptions)
	if len(r.Sessions) != 2 {
		t.Fatalf("sessions %+v", r.Sessions)
	}
	a, b := r.Sessions[0], r.Sessions[1]
	if a.EndReason != ReasonGap || a.Membership != Partial || !a.End.Equal(at(100)) {
		t.Fatalf("first %+v", a)
	}
	if b.StartReason != ReasonSpeed || b.Membership != Partial || !b.Start.Equal(at(7300)) {
		t.Fatalf("second %+v", b)
	}
}

func TestOutOfOrderAndDuplicatesAreDeterministic(t *testing.T) {
	ps := []Point{{TS: at(0), Gear: "ShiftStateP"}, {TS: at(10), Gear: "ShiftStateD"}}
	ps = append(ps, drivePoints(20, 300, 10)...)
	ps = append(ps, Point{TS: at(310), Gear: "ShiftStateP"})
	conns := []ConnEvent{connected("c1", -5)}
	want := Derive(ps, conns, Seed{}, DefaultOptions)

	shuffled := append([]Point(nil), ps...)
	for i, j := 0, len(shuffled)-1; i < j; i, j = i+1, j-1 {
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	}
	shuffled = append(shuffled, ps[5], ps[10]) // duplicates (resends)
	got := Derive(shuffled, conns, Seed{}, DefaultOptions)
	if len(got.Sessions) != 1 || got.Sessions[0].Start != want.Sessions[0].Start || got.Sessions[0].End != want.Sessions[0].End || got.Sessions[0].Payloads != want.Sessions[0].Payloads {
		t.Fatalf("got %+v want %+v", got.Sessions, want.Sessions)
	}
	// Gear and speed for one instant arriving in two records merge.
	m := Derive([]Point{{TS: at(0), Gear: "ShiftStateP"}, {TS: at(10), Gear: "ShiftStateD"}, {TS: at(10), SpeedMph: mph(5)}, {TS: at(20), Gear: "ShiftStateP"}}, conns, Seed{}, DefaultOptions)
	if len(m.Sessions) != 1 || m.Sessions[0].Payloads != 2 {
		t.Fatalf("merge %+v", m.Sessions)
	}
}

func TestChargeSession(t *testing.T) {
	ps := []Point{
		{TS: at(0), ChargeState: "DetailedChargeStateDisconnected"},
		{TS: at(60), ChargeState: "DetailedChargeStateStarting"},
		{TS: at(120), ChargeState: "DetailedChargeStateCharging"},
		{TS: at(240)}, {TS: at(360)},
		{TS: at(480), ChargeState: "DetailedChargeStateComplete"},
	}
	r := Derive(ps, []ConnEvent{connected("c1", -5)}, Seed{}, DefaultOptions)
	if len(r.Sessions) != 1 {
		t.Fatalf("%+v", r.Sessions)
	}
	s := r.Sessions[0]
	if s.Kind != KindCharge || !s.Start.Equal(at(60)) || !s.End.Equal(at(480)) || s.Membership != Complete {
		t.Fatalf("%+v", s)
	}
}

func TestOpenSession(t *testing.T) {
	ps := []Point{{TS: at(0), Gear: "ShiftStateP"}, {TS: at(10), Gear: "ShiftStateD"}, {TS: at(20), SpeedMph: mph(20)}}
	r := Derive(ps, []ConnEvent{connected("c1", -5)}, Seed{}, DefaultOptions)
	if len(r.Sessions) != 1 || r.Sessions[0].EndReason != ReasonOpen {
		t.Fatalf("%+v", r.Sessions)
	}
}

func TestInvalidGearIsUncertainty(t *testing.T) {
	// P -> D -> invalid -> sparse -> P: never complete.
	ps := []Point{{TS: at(0), Gear: "ShiftStateP"}, {TS: at(10), Gear: "ShiftStateD"}}
	ps = append(ps, drivePoints(20, 100, 10)...)
	ps = append(ps, Point{TS: at(110), GearInvalid: true})
	ps = append(ps, Point{TS: at(200), SpeedMph: mph(10)}, Point{TS: at(290), SpeedMph: mph(5)})
	ps = append(ps, Point{TS: at(300), Gear: "ShiftStateP"})
	r := Derive(ps, []ConnEvent{connected("c1", -5)}, Seed{}, DefaultOptions)
	if len(r.Sessions) != 1 {
		t.Fatalf("sessions %+v", r.Sessions)
	}
	s := r.Sessions[0]
	if s.Membership != Partial || len(s.Gaps) != 1 || s.Gaps[0].Reason != GapGearInvalid ||
		!s.Gaps[0].Start.Equal(at(110)) || !s.Gaps[0].End.Equal(at(300)) {
		t.Fatalf("drive %+v", s)
	}
	if len(r.Gaps) != 1 || r.Gaps[0].Reason != GapGearInvalid {
		t.Fatalf("gaps %+v", r.Gaps)
	}
	// The SNA name is invalid too, as is a same-instant disagreement.
	for _, bad := range [][]Point{
		{{TS: at(110), Gear: "ShiftStateSNA"}},
		{{TS: at(110), Gear: "ShiftStateD"}, {TS: at(110), Gear: "ShiftStateR"}},
	} {
		ps2 := []Point{{TS: at(0), Gear: "ShiftStateP"}, {TS: at(10), Gear: "ShiftStateD"}}
		ps2 = append(ps2, drivePoints(20, 100, 10)...)
		ps2 = append(ps2, bad...)
		ps2 = append(ps2, Point{TS: at(300), Gear: "ShiftStateP"})
		r := Derive(ps2, []ConnEvent{connected("c1", -5)}, Seed{}, DefaultOptions)
		if len(r.Sessions) != 1 || r.Sessions[0].Membership != Partial {
			t.Fatalf("bad gear %+v -> %+v", bad, r.Sessions)
		}
	}
	// An invalid charge state inside a charge session.
	cps := []Point{
		{TS: at(0), ChargeState: "DetailedChargeStateDisconnected"},
		{TS: at(60), ChargeState: "DetailedChargeStateCharging"},
		{TS: at(120), ChargeInvalid: true},
		{TS: at(480), ChargeState: "DetailedChargeStateComplete"},
	}
	r = Derive(cps, []ConnEvent{connected("c1", -5)}, Seed{}, DefaultOptions)
	if len(r.Sessions) != 1 || r.Sessions[0].Membership != Partial || r.Sessions[0].Gaps[0].Reason != GapChargeInvalid {
		t.Fatalf("charge %+v", r.Sessions)
	}
}

func TestAbsentInvalidAndUnchangedAreDistinct(t *testing.T) {
	base := []Point{{TS: at(0), Gear: "ShiftStateP"}, {TS: at(10), Gear: "ShiftStateD"}, {TS: at(20), SpeedMph: mph(20)}}
	end := Point{TS: at(40), Gear: "ShiftStateP"}
	conns := []ConnEvent{connected("c1", -5)}
	// Absent (field not sent, connection up): unchanged.
	r := Derive(append(append([]Point(nil), base...), Point{TS: at(30), SpeedMph: mph(20)}, end), conns, Seed{}, DefaultOptions)
	if r.Sessions[0].Membership != Complete {
		t.Fatalf("absent %+v", r.Sessions)
	}
	// Invalid: unknown.
	r = Derive(append(append([]Point(nil), base...), Point{TS: at(30), GearInvalid: true}, end), conns, Seed{}, DefaultOptions)
	if r.Sessions[0].Membership != Partial {
		t.Fatalf("invalid %+v", r.Sessions)
	}
	// Seed: an invalid latest gear before the window is unknown, not D.
	r = Derive([]Point{{TS: at(0), Gear: "ShiftStateD"}, {TS: at(60), Gear: "ShiftStateP"}}, conns, Seed{LastGear: "ShiftStateInvalid"}, DefaultOptions)
	if r.Sessions[0].StartReason != ReasonFirstObserved || r.Sessions[0].Membership != Partial {
		t.Fatalf("seed %+v", r.Sessions)
	}
}

func TestShortKnownDisconnectIsGap(t *testing.T) {
	// 40 s disconnect/reconnect with a tight 10 s cadence around it.
	ps := []Point{{TS: at(0), Gear: "ShiftStateP"}, {TS: at(10), Gear: "ShiftStateD"}}
	ps = append(ps, drivePoints(20, 100, 10)...)
	ps = append(ps, drivePoints(140, 300, 10)...)
	ps = append(ps, Point{TS: at(310), Gear: "ShiftStateP"})
	conns := []ConnEvent{connected("c1", -5), disconnected("c1", 105), connected("c2", 135)}
	r := Derive(ps, conns, Seed{}, DefaultOptions)
	if len(r.Gaps) != 1 || r.Gaps[0].Reason != GapDisconnected || !r.Gaps[0].Start.Equal(at(100)) || !r.Gaps[0].End.Equal(at(140)) {
		t.Fatalf("gaps %+v", r.Gaps)
	}
	if len(r.Sessions) != 1 || r.Sessions[0].Membership != Partial || len(r.Sessions[0].Gaps) != 1 {
		t.Fatalf("sessions %+v", r.Sessions)
	}
	// A new connection id without a DISCONNECTED event is a break too.
	r = Derive(ps, []ConnEvent{connected("c1", -5), connected("c2", 120)}, Seed{}, DefaultOptions)
	if len(r.Gaps) != 1 || r.Sessions[0].Membership != Partial {
		t.Fatalf("reconnect %+v %+v", r.Gaps, r.Sessions)
	}
	// Reconnect resets carried gear: D before the break is not assumed after
	// it, so a drive cannot start from the carried value.
	r = Derive([]Point{{TS: at(0), Gear: "ShiftStateD"}, {TS: at(100), SpeedMph: mph(0)}},
		[]ConnEvent{connected("c1", -5), disconnected("c1", 50), connected("c2", 60)}, Seed{}, DefaultOptions)
	for _, s := range r.Sessions {
		if s.Membership == Complete {
			t.Fatalf("carried across reconnect %+v", s)
		}
	}
}

func TestBufferedPayloadsInsideKnownDisconnectRemainPartial(t *testing.T) {
	// These payloads arrive after reconnect but retain source timestamps
	// inside the known disconnected interval. Every adjacent span is well
	// below MaxSilence; connectivity still makes the drive uncertain.
	ps := []Point{
		{TS: at(0), Gear: "ShiftStateP"},
		{TS: at(20), SpeedMph: mph(0)},
		{TS: at(30), Gear: "ShiftStateD", SpeedMph: mph(20)},
		{TS: at(50), Gear: "ShiftStateP", SpeedMph: mph(0)},
		{TS: at(70), SpeedMph: mph(0)},
	}
	conns := []ConnEvent{connected("c1", -5), disconnected("c1", 10), connected("c2", 60)}
	r := Derive(ps, conns, Seed{}, DefaultOptions)
	if len(r.Sessions) != 1 || r.Sessions[0].Membership != Partial {
		t.Fatalf("buffered drive treated as complete: %+v", r.Sessions)
	}
	if len(r.Sessions[0].Gaps) == 0 || r.Sessions[0].Gaps[0].Reason != GapDisconnected {
		t.Fatalf("buffered drive has no disconnect gap: %+v", r.Sessions[0])
	}
	for _, span := range [][2]time.Time{{at(20), at(30)}, {at(30), at(50)}} {
		found := false
		for _, gap := range r.Gaps {
			if gap.Reason == GapDisconnected && gap.Start.Equal(span[0]) && gap.End.Equal(span[1]) {
				found = true
			}
		}
		if !found {
			t.Fatalf("missing disconnect gap %s..%s in %+v", span[0], span[1], r.Gaps)
		}
	}
}

func TestPersistedGapsDropsLossJitter(t *testing.T) {
	gs := []Gap{
		{Start: at(0), End: at(0).Add(500 * time.Millisecond), Reason: GapDisconnected},
		{Start: at(1), End: at(5), Reason: GapSilence},
		{Start: at(10), End: at(15), Reason: GapDisconnected},
		{Start: at(20), End: at(21), Reason: GapGearInvalid},
		{Start: at(30), End: at(30), Reason: GapChargeInvalid},
	}
	got := PersistedGaps(gs, MinPersistedLoss)
	if len(got) != 3 || !got[0].Start.Equal(at(10)) || got[1].Reason != GapGearInvalid || got[2].Reason != GapChargeInvalid {
		t.Fatalf("unexpected persisted gaps: %+v", got)
	}
}
