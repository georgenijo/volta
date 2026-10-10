// Package session derives drive and charge sessions from streamed samples.
//
// Fleet Telemetry sends a field only when it changed and its interval has
// elapsed, so silence is ambiguous: the value may be unchanged, or the car
// may be offline. The receiver's connectivity events resolve that: silence
// while the same connection stayed up means "unchanged"; silence across a
// disconnect or a new connection id means "unknown". The vehicle buffers
// data while offline and delivers it with its original created_at, so a
// disconnect only becomes a gap when no buffered payload covers it.
//
// A known disconnect is always a break, however short: values carried from
// before it (gear, charge state) are forgotten, the span between the last
// payload before it and the first payload after it is a gap, and a session
// spanning it is partial. A vehicle-reported invalid Gear or
// DetailedChargeState is also an unknown span: it lasts until the next valid
// value, and a session that contains it is partial.
//
// Sessions never invent membership. A session whose start was not observed
// (data begins mid-drive, or resumes after a long gap) is marked partial with
// start reason first_observed, and every unknown span inside a session is
// listed as a gap.
package session

import (
	"sort"
	"time"
)

// Kinds.
const (
	KindDrive  = "drive"
	KindCharge = "charge"
)

// Reasons.
const (
	ReasonGear          = "gear"           // shift into R/N/D or into P
	ReasonSpeed         = "speed"          // moving without a known gear
	ReasonChargeState   = "charge_state"   // DetailedChargeState transition
	ReasonFirstObserved = "first_observed" // start not observed
	ReasonGap           = "gap"            // split by an unknown span
	ReasonOpen          = "open"           // still running at end of data

	GapDisconnected  = "disconnected"
	GapSilence       = "silence"
	GapGearInvalid   = "gear_invalid"
	GapChargeInvalid = "charge_invalid"
)

// Membership.
const (
	Complete = "complete"
	Partial  = "partial"
)

// Point is the subset of one payload the sessionizer needs. Absent, invalid
// and valid are distinct: an empty string or nil pointer means the field was
// not in that payload (unchanged or unknown, decided by connectivity), while
// GearInvalid/ChargeInvalid mean the vehicle reported the value as invalid
// (or two payloads at the same instant disagreed), which is unknown.
type Point struct {
	TS            time.Time
	Gear          string // proto ShiftState name, e.g. ShiftStateD
	GearInvalid   bool
	SpeedMph      *float64
	ChargeState   string // proto DetailedChargeStateValue name
	ChargeInvalid bool
}

// ConnEvent is a receiver connectivity event.
type ConnEvent struct {
	TS           time.Time
	ConnectionID string
	Status       string // CONNECTED | DISCONNECTED
}

// Gap is a span where the vehicle state is unknown.
type Gap struct {
	Start  time.Time `json:"start"`
	End    time.Time `json:"end"`
	Reason string    `json:"reason"`
}

// MinPersistedLoss is the shortest disconnected/silence gap worth storing.
// Each such gap spans exactly two consecutive payloads, so a shorter one is
// stream cadence while connectivity reads disconnected, not lost data. Those
// rows flooded the table (thousands per day) and read as interruptions.
const MinPersistedLoss = 5 * time.Second

// PersistedGaps drops loss gaps shorter than min. Invalid-state gaps are kept:
// their length says nothing about connectivity.
func PersistedGaps(gs []Gap, min time.Duration) []Gap {
	out := make([]Gap, 0, len(gs))
	for _, g := range gs {
		if (g.Reason == GapDisconnected || g.Reason == GapSilence) && g.End.Sub(g.Start) < min {
			continue
		}
		out = append(out, g)
	}
	return out
}

// Session is a derived drive or charge.
type Session struct {
	Kind        string    `json:"kind"`
	Start       time.Time `json:"start"`
	End         time.Time `json:"end"`
	StartReason string    `json:"startReason"`
	EndReason   string    `json:"endReason"`
	Membership  string    `json:"membership"`
	Gaps        []Gap     `json:"gaps"`
	Payloads    int       `json:"payloads"`
}

// Seed is the state just before the first point, so derivation can start in
// the middle of the history without guessing.
// An empty LastGear/LastChargeState means unknown (never observed, or the
// latest observation was invalid).
type Seed struct {
	LastGear        string
	LastChargeState string
	LastPayload     time.Time // zero if unknown
}

// Options tune gap detection.
type Options struct {
	// MaxSilence is the longest payload silence treated as "unchanged" when
	// connectivity is unknown or broken across it.
	MaxSilence time.Duration
	// SplitAfter ends a session at an unknown span at least this long.
	SplitAfter time.Duration
}

// DefaultOptions are the production values.
var DefaultOptions = Options{MaxSilence: 5 * time.Minute, SplitAfter: 30 * time.Minute}

// Result is the derivation output.
type Result struct {
	Sessions []Session
	Gaps     []Gap
}

// Derive computes sessions. Input order does not matter; duplicate
// timestamps are merged. The function is pure and deterministic.
func Derive(points []Point, conns []ConnEvent, seed Seed, opt Options) Result {
	pts := mergePoints(points)
	cs := append([]ConnEvent(nil), conns...)
	sort.SliceStable(cs, func(i, j int) bool { return cs[i].TS.Before(cs[j].TS) })

	var res Result
	gear := seed.LastGear
	charge := seed.LastChargeState
	last := seed.LastPayload
	gearKnown := validGear(gear)
	chargeKnown := validCharge(charge)
	var drive, chg *Session
	// Open uncertainty spans started by an invalid value; zero when none.
	var gearUnknownFrom, chargeUnknownFrom time.Time

	closeS := func(s **Session, at time.Time, reason string) {
		if *s == nil {
			return
		}
		(*s).End = at
		(*s).EndReason = reason
		if reason == ReasonGap || (*s).StartReason == ReasonFirstObserved || (*s).StartReason == ReasonSpeed || len((*s).Gaps) > 0 {
			(*s).Membership = Partial
		}
		res.Sessions = append(res.Sessions, **s)
		*s = nil
	}
	addGap := func(g Gap, to ...*Session) {
		res.Gaps = append(res.Gaps, g)
		for _, s := range to {
			if s != nil {
				s.Gaps = append(s.Gaps, g)
			}
		}
	}
	endUncertainty := func(from *time.Time, at time.Time, reason string, s *Session) {
		if from.IsZero() {
			return
		}
		addGap(Gap{Start: *from, End: at, Reason: reason}, s)
		*from = time.Time{}
	}

	for _, p := range pts {
		if !last.IsZero() {
			if reason, unknown := breakBetween(cs, last, p.TS, opt.MaxSilence); unknown {
				g := Gap{Start: last, End: p.TS, Reason: reason}
				split := p.TS.Sub(last) >= opt.SplitAfter
				if split {
					endUncertainty(&gearUnknownFrom, last, GapGearInvalid, drive)
					endUncertainty(&chargeUnknownFrom, last, GapChargeInvalid, chg)
					res.Gaps = append(res.Gaps, g)
					closeS(&drive, last, ReasonGap)
					closeS(&chg, last, ReasonGap)
				} else {
					addGap(g, drive, chg)
				}
				// Nothing observed before the break carries across it.
				gearKnown, chargeKnown = false, false
				gear, charge = "", ""
			}
		}
		last = p.TS

		// An invalid value opens an unknown span; the next valid value
		// closes it.
		if p.GearInvalid {
			if gearUnknownFrom.IsZero() {
				gearUnknownFrom = p.TS
			}
			gear, gearKnown = "", false
		} else if p.Gear != "" {
			endUncertainty(&gearUnknownFrom, p.TS, GapGearInvalid, drive)
		}
		if p.ChargeInvalid {
			if chargeUnknownFrom.IsZero() {
				chargeUnknownFrom = p.TS
			}
			charge, chargeKnown = "", false
		} else if p.ChargeState != "" {
			endUncertainty(&chargeUnknownFrom, p.TS, GapChargeInvalid, chg)
		}

		// Drive state.
		switch {
		case isMovingGear(p.Gear):
			if drive == nil {
				reason := ReasonGear
				if !gearKnown || gear == p.Gear {
					reason = ReasonFirstObserved
				}
				drive = &Session{Kind: KindDrive, Start: p.TS, StartReason: reason, Membership: Complete}
			}
		case p.Gear == "ShiftStateP":
			if drive != nil {
				drive.Payloads++
				closeS(&drive, p.TS, ReasonGear)
			}
		case p.Gear == "" && drive == nil && p.SpeedMph != nil && *p.SpeedMph > 0 && !(gearKnown && isMovingGear(gear)):
			// Moving with no gear in this payload and no known moving gear:
			// only possible when the gear transition was not observed.
			drive = &Session{Kind: KindDrive, Start: p.TS, StartReason: ReasonSpeed, Membership: Partial}
		case p.Gear == "" && drive == nil && gearKnown && isMovingGear(gear):
			// Known to still be in a moving gear (derivation started
			// mid-drive).
			drive = &Session{Kind: KindDrive, Start: p.TS, StartReason: ReasonFirstObserved, Membership: Partial}
		}
		if validGear(p.Gear) {
			gear, gearKnown = p.Gear, true
		}
		if drive != nil {
			drive.Payloads++
			drive.End = p.TS
		}

		// Charge state.
		switch {
		case isCharging(p.ChargeState):
			if chg == nil {
				reason := ReasonChargeState
				if !chargeKnown || isCharging(charge) {
					reason = ReasonFirstObserved
				}
				chg = &Session{Kind: KindCharge, Start: p.TS, StartReason: reason, Membership: Complete}
			}
		case isChargeEnd(p.ChargeState):
			if chg != nil {
				chg.Payloads++
				closeS(&chg, p.TS, ReasonChargeState)
			}
		case p.ChargeState == "" && chg == nil && chargeKnown && isCharging(charge):
			chg = &Session{Kind: KindCharge, Start: p.TS, StartReason: ReasonFirstObserved, Membership: Partial}
		}
		if validCharge(p.ChargeState) {
			charge, chargeKnown = p.ChargeState, true
		}
		if chg != nil {
			chg.Payloads++
			chg.End = p.TS
		}
	}
	// Unknown spans still open at the end of data close at the last payload.
	endUncertainty(&gearUnknownFrom, last, GapGearInvalid, drive)
	endUncertainty(&chargeUnknownFrom, last, GapChargeInvalid, chg)
	for _, s := range []**Session{&drive, &chg} {
		if *s != nil {
			closeS(s, (*s).End, ReasonOpen)
		}
	}
	sort.SliceStable(res.Sessions, func(i, j int) bool { return res.Sessions[i].Start.Before(res.Sessions[j].Start) })
	sort.SliceStable(res.Gaps, func(i, j int) bool { return res.Gaps[i].Start.Before(res.Gaps[j].Start) })
	return res
}

func validGear(g string) bool {
	return g != "" && g != "ShiftStateInvalid" && g != "ShiftStateSNA" && g != "ShiftStateUnknown"
}

func validCharge(c string) bool {
	return c != "" && c != "DetailedChargeStateUnknown"
}

func isMovingGear(g string) bool {
	return g == "ShiftStateD" || g == "ShiftStateR" || g == "ShiftStateN"
}

func isCharging(s string) bool {
	return s == "DetailedChargeStateCharging" || s == "DetailedChargeStateStarting"
}

func isChargeEnd(s string) bool {
	switch s {
	case "DetailedChargeStateComplete", "DetailedChargeStateStopped", "DetailedChargeStateDisconnected", "DetailedChargeStateNoPower":
		return true
	}
	return false
}

// breakBetween decides whether the span between two consecutive payloads
// is unknown. Any connectivity evidence of a break inside the span (a
// DISCONNECTED or UNKNOWN event, or a new connection id) makes it a
// disconnected gap regardless of its length. Without such evidence, silence
// up to maxSilence is "unchanged"; longer silence is unchanged only if the
// stream is known to have been connected at the start of the span.
func breakBetween(cs []ConnEvent, from, to time.Time, maxSilence time.Duration) (string, bool) {
	// Connection state at `from`: last event at or before it.
	var cur *ConnEvent
	for i := range cs {
		if cs[i].TS.After(from) {
			break
		}
		cur = &cs[i]
	}
	for i := range cs {
		e := cs[i]
		if !e.TS.After(from) || e.TS.After(to) {
			continue
		}
		if e.Status != "CONNECTED" || cur == nil || e.ConnectionID != cur.ConnectionID {
			return GapDisconnected, true
		}
	}
	// A span that begins while the receiver already knows the vehicle is
	// disconnected is unknown even when it is shorter than MaxSilence. This
	// is what preserves the gap when the car later uploads buffered payloads
	// whose source times fall inside the disconnect interval.
	if cur != nil && cur.Status != "CONNECTED" {
		return GapDisconnected, true
	}
	if to.Sub(from) <= maxSilence {
		return "", false
	}
	if cur == nil {
		// No evidence the stream was up: silence cannot be read as unchanged.
		return GapSilence, true
	}
	return "", false
}

// mergePoints merges points with the same timestamp. Two payloads at one
// instant that disagree on gear or charge state make that value invalid
// rather than picking one.
func mergePoints(points []Point) []Point {
	ps := append([]Point(nil), points...)
	sort.SliceStable(ps, func(i, j int) bool { return ps[i].TS.Before(ps[j].TS) })
	out := ps[:0]
	for _, p := range ps {
		if n := len(out); n > 0 && out[n-1].TS.Equal(p.TS) {
			q := &out[n-1]
			p = normalizePoint(p)
			q.Gear, q.GearInvalid = mergeState(q.Gear, q.GearInvalid, p.Gear, p.GearInvalid)
			q.ChargeState, q.ChargeInvalid = mergeState(q.ChargeState, q.ChargeInvalid, p.ChargeState, p.ChargeInvalid)
			if p.SpeedMph != nil {
				if q.SpeedMph != nil && *q.SpeedMph != *p.SpeedMph {
					// Conflicting speeds: keep the larger, which only matters
					// for "moving or not" and is the conservative reading.
					v := max(*q.SpeedMph, *p.SpeedMph)
					q.SpeedMph = &v
				} else {
					q.SpeedMph = p.SpeedMph
				}
			}
			continue
		}
		out = append(out, normalizePoint(p))
	}
	return out
}

func normalizePoint(p Point) Point {
	if p.GearInvalid || (p.Gear != "" && !validGear(p.Gear)) {
		p.Gear, p.GearInvalid = "", true
	}
	if p.ChargeInvalid || (p.ChargeState != "" && !validCharge(p.ChargeState)) {
		p.ChargeState, p.ChargeInvalid = "", true
	}
	return p
}

// mergeState combines one state field from two normalized points.
func mergeState(a string, aInvalid bool, b string, bInvalid bool) (string, bool) {
	if b == "" && !bInvalid {
		return a, aInvalid
	}
	if aInvalid || bInvalid || (a != "" && a != b) {
		return "", true
	}
	return b, false
}
