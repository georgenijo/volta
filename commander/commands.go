package commander

import (
	"encoding/json"
	"errors"
	"math"
)

type Command struct {
	Name, Upstream string
	Params         map[string]any
}

// Volta's contract is camelCase and metric. Only this translation layer speaks
// Tesla's snake_case command parameters. Unknown fields always fail validation.
func ParseCommand(name string, p map[string]any) (Command, error) {
	c := Command{Name: name, Params: map[string]any{}}
	simple := map[string]string{"lock": "door_lock", "unlock": "door_unlock", "climate_on": "auto_conditioning_start", "climate_off": "auto_conditioning_stop", "charge_start": "charge_start", "charge_stop": "charge_stop", "open_charge_port": "charge_port_door_open", "close_charge_port": "charge_port_door_close", "honk": "honk_horn", "flash": "flash_lights", "wake_up": "wake_up", "sentry_on": "set_sentry_mode", "sentry_off": "set_sentry_mode"}
	if upstream, ok := simple[name]; ok {
		if len(p) != 0 {
			return c, errors.New("this command accepts no parameters")
		}
		c.Upstream = upstream
		if name == "sentry_on" || name == "sentry_off" {
			c.Params["on"] = name == "sentry_on"
		}
		return c, nil
	}
	c.Upstream = name
	number := func(key string, min, max float64) (float64, error) {
		n, ok := p[key].(json.Number)
		if !ok {
			return 0, errors.New("missing numeric parameter: " + key)
		}
		v, err := n.Float64()
		if err != nil || math.IsNaN(v) || math.IsInf(v, 0) || v < min || v > max {
			return 0, errors.New("numeric parameter out of range: " + key)
		}
		return v, nil
	}
	enum := func(key string, values ...string) (string, error) {
		v, ok := p[key].(string)
		if ok {
			for _, allowed := range values {
				if v == allowed {
					return v, nil
				}
			}
		}
		return "", errors.New("invalid parameter: " + key)
	}
	switch name {
	case "set_temps":
		if len(p) != 2 {
			return c, errors.New("expected driverTempC and passengerTempC")
		}
		a, err := number("driverTempC", 15, 28)
		if err != nil {
			return c, err
		}
		b, err := number("passengerTempC", 15, 28)
		if err != nil {
			return c, err
		}
		c.Params = map[string]any{"driver_temp": a, "passenger_temp": b}
	case "set_charge_limit":
		if len(p) != 1 {
			return c, errors.New("expected percent")
		}
		n, err := number("percent", 50, 100)
		if err != nil {
			return c, err
		}
		if math.Trunc(n) != n {
			return c, errors.New("percent must be an integer")
		}
		c.Params["percent"] = int(n)
	case "actuate_trunk":
		if len(p) != 1 {
			return c, errors.New("expected whichTrunk")
		}
		v, err := enum("whichTrunk", "front", "rear")
		if err != nil {
			return c, err
		}
		c.Params["which_trunk"] = v
	case "window_control":
		if len(p) != 1 {
			return c, errors.New("expected command")
		}
		v, err := enum("command", "vent", "close")
		if err != nil {
			return c, err
		}
		c.Params["command"] = v
	case "trigger_homelink":
		if len(p) != 2 {
			return c, errors.New("expected latitude and longitude")
		}
		a, err := number("latitude", -90, 90)
		if err != nil {
			return c, err
		}
		b, err := number("longitude", -180, 180)
		if err != nil {
			return c, err
		}
		c.Params = map[string]any{"lat": a, "lon": b}
	default:
		return c, errors.New("command is not allowed")
	}
	return c, nil
}
