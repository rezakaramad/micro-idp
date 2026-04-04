// Given an FQDN → ask PowerDNS → is it already taken?

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

type PDNSClient interface {
	CheckDNSAvailable(ctx context.Context, fqdn string) (DNSAvailabilityResult, error)
}

type DNSAvailabilityResult struct {
	Available bool
	Message   string
}

// ---------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------
type powerDNSClient struct {
	baseURL string
	apiKey  string
	client  *http.Client
}

// Constructor
func NewPowerDNSClient(baseURL, apiKey string) PDNSClient {
	return &powerDNSClient{
		baseURL: baseURL,
		apiKey:  apiKey,
		client: &http.Client{
			Timeout: 3 * time.Second,
		},
	}
}

// ---------------------------------------------------------------------
// API call
// ---------------------------------------------------------------------
func (p *powerDNSClient) CheckDNSAvailable(ctx context.Context, fqdn string) (DNSAvailabilityResult, error) {

	// Extract zone from fqdn
	// Example:
	// fqdn = foo.wl.rezakara.demo.
	// zone = wl.rezakara.demo.
	parts := strings.Split(strings.TrimSuffix(fqdn, "."), ".")
	if len(parts) < 2 {
		return DNSAvailabilityResult{}, fmt.Errorf("invalid fqdn: %s", fqdn)
	}

	// PowerDNS API expects zones to be in the format "example.com." with a trailing dot.
	zone := fmt.Sprintf("%s.%s.", parts[len(parts)-2], parts[len(parts)-1])

	// PowerDNS API endpoint to get zone details looks like: /api/v1/servers/{server_id}/zones/{zone_id}
	url := fmt.Sprintf("%s/servers/localhost/zones/%s", p.baseURL, zone)

	// Create an HTTP GET request to the PowerDNS API to fetch the zone information.
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return DNSAvailabilityResult{}, err
	}

	// Set API key for authentication
	req.Header.Set("X-API-Key", p.apiKey)

	// Send the request to PowerDNS and get the response.
	resp, err := p.client.Do(req)
	if err != nil {
		return DNSAvailabilityResult{}, fmt.Errorf("pdns request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return DNSAvailabilityResult{}, fmt.Errorf("pdns unexpected status: %d", resp.StatusCode)
	}

	// Parse zone response
	var zoneData struct {
		RRsets []struct {
			Name string `json:"name"`
			Type string `json:"type"`
		} `json:"rrsets"`
	}

	// Decode the JSON response body into the zoneData struct. If decoding fails, return the error.
	if err := json.NewDecoder(resp.Body).Decode(&zoneData); err != nil {
		return DNSAvailabilityResult{}, err
	}

	// Normalize fqdn (PowerDNS always returns trailing dot)
	expected := ensureTrailingDot(fqdn)

	// Check if any of the existing DNS records in the zone match the expected FQDN.
	// If we find a match, that means the DNS name is already taken, so we return Available: false with a message.
	for _, rr := range zoneData.RRsets {
		if rr.Name == expected {
			return DNSAvailabilityResult{
				Available: false,
				Message:   fmt.Sprintf("dns %q already exists in PowerDNS", fqdn),
			}, nil
		}
	}

	// If we loop through all records and don't find a match, that means the DNS name is available, so we return Available: true.
	return DNSAvailabilityResult{
		Available: true,
	}, nil
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------
// Ensures:
// foo.dev.example.com → foo.dev.example.com.
func ensureTrailingDot(s string) string {
	if strings.HasSuffix(s, ".") {
		return s
	}
	return s + "."
}
