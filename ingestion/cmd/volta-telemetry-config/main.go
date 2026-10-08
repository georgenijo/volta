// Command volta-telemetry-config prints the bounded Fleet Telemetry config
// body and its monthly budget. It never contacts Tesla and never reads
// credentials: commander signs and sends the body (through the vehicle
// command proxy) after substituting the registered VIN.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"time"

	"github.com/georgenijo/volta/ingestion/fleetconfig"
)

// PlaceholderVIN is a syntactically valid fake VIN for review output.
const PlaceholderVIN = "5YJ3E1EA0XF000000"

func main() {
	hostname := flag.String("hostname", "volta-node.example.ts.net", "public receiver hostname")
	port := flag.Int("port", 10000, "public receiver port")
	caFile := flag.String("ca-file", "", "PEM chain that signs the receiver's server certificate (required for -mode=config)")
	mode := flag.String("mode", "budget", "budget | config | profiles")
	capUSD := flag.Float64("cap-usd", 25, "monthly telemetry ceiling")
	warnUSD := flag.Float64("warn-usd", 20, "switch to economy profile at this usage")
	stopUSD := flag.Float64("stop-usd", 23, "delete telemetry config at this usage")
	expiryDays := flag.Int("expiry-days", 30, "config expiry in days (max 31)")
	flag.Parse()

	p := fleetconfig.Profile()
	if err := fleetconfig.Validate(p); err != nil {
		fail(err)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	switch *mode {
	case "profiles":
		out := map[string]map[string]fleetconfig.FieldConfig{}
		for name, planned := range map[string][]fleetconfig.Planned{"normal": fleetconfig.Profile(), "economy": fleetconfig.EconomyProfile()} {
			fields := map[string]fleetconfig.FieldConfig{}
			for _, field := range planned {
				fields[field.Name] = field.FieldConfig
			}
			out[name] = fields
		}
		if err := enc.Encode(out); err != nil {
			fail(err)
		}
	case "budget":
		b := fleetconfig.Estimate(p, fleetconfig.DefaultHours)
		out := struct {
			CapUSD  float64            `json:"capUsd"`
			WarnUSD float64            `json:"warnUsd"`
			StopUSD float64            `json:"stopUsd"`
			Budget  fleetconfig.Budget `json:"budget"`
		}{math.Round(*capUSD*1e6) / 1e6, math.Round(*warnUSD*1e6) / 1e6, math.Round(*stopUSD*1e6) / 1e6, b}
		if err := enc.Encode(out); err != nil {
			fail(err)
		}
	case "config":
		if *caFile == "" {
			fail(fmt.Errorf("-ca-file is required"))
		}
		ca, err := os.ReadFile(*caFile)
		if err != nil {
			fail(fmt.Errorf("ca file is not readable"))
		}
		req, err := fleetconfig.Build(p, []string{PlaceholderVIN}, *hostname, *port, string(ca), time.Now(), time.Duration(*expiryDays)*24*time.Hour)
		if err != nil {
			fail(err)
		}
		if err := enc.Encode(req); err != nil {
			fail(err)
		}
	default:
		fail(fmt.Errorf("unknown -mode %q", *mode))
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "volta-telemetry-config:", err)
	os.Exit(2)
}
