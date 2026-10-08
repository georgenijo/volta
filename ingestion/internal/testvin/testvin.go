// Package testvin holds fake, syntactically valid VINs for tests.
package testvin

// Fake VINs. None belongs to a real vehicle.
const (
	A     = "5YJ3E1EA0XF000001"
	B     = "5YJ3E1EA0XF000002"
	C     = "5YJ3E1EA0XF000003"
	D     = "5YJ3E1EA0XF000004"
	Rogue = "5YJ3E1EA0XF999999"
)

// Mapping is a vehicles.Parse input binding A to id 1 and B to id 2.
const Mapping = `{"1":"` + A + `","2":"` + B + `"}`

// MappingFour also binds C to 3 and D to 4.
const MappingFour = `{"1":"` + A + `","2":"` + B + `","3":"` + C + `","4":"` + D + `"}`
