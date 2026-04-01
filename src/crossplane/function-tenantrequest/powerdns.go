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
// Concrete implementation
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
	// fqdn = foo.wl.rezakara.demo.
	// zone = wl.rezakara.demo.
	parts := strings.Split(strings.TrimSuffix(fqdn, "."), ".")
	if len(parts) < 2 {
		return DNSAvailabilityResult{}, fmt.Errorf("invalid fqdn: %s", fqdn)
	}

	zone := fmt.Sprintf("%s.%s.", parts[len(parts)-2], parts[len(parts)-1])

	url := fmt.Sprintf("%s/servers/localhost/zones/%s", p.baseURL, zone)

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return DNSAvailabilityResult{}, err
	}

	req.Header.Set("X-API-Key", p.apiKey)

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

	if err := json.NewDecoder(resp.Body).Decode(&zoneData); err != nil {
		return DNSAvailabilityResult{}, err
	}

	// Normalize fqdn (PowerDNS always returns trailing dot)
	expected := ensureTrailingDot(fqdn)

	for _, rr := range zoneData.RRsets {
		if rr.Name == expected {
			return DNSAvailabilityResult{
				Available: false,
				Message:   fmt.Sprintf("dns %q already exists in PowerDNS", fqdn),
			}, nil
		}
	}

	return DNSAvailabilityResult{
		Available: true,
	}, nil
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

func ensureTrailingDot(s string) string {
	if strings.HasSuffix(s, ".") {
		return s
	}
	return s + "."
}
