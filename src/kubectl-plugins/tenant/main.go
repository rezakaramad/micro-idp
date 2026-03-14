package main

import (
	"fmt"
	"os"
	"os/exec"
	"time"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Println("usage: kubectl tenant approve <tenantrequest>")
		os.Exit(1)
	}

	command := os.Args[1]
	name := os.Args[2]

	switch command {
	case "approve":
		approve(name)
	default:
		fmt.Println("unknown command:", command)
		os.Exit(1)
	}
}

func approve(name string) {

	timestamp := time.Now().UTC().Format(time.RFC3339)

	patch := fmt.Sprintf(`{
	"status": {
		"conditions": [
		{
			"type": "Approved",
			"status": "True",
			"reason": "PlatformApproved",
			"message": "Tenant approved by platform team",
			"lastTransitionTime": "%s"
		}]
	}
}`, timestamp)

	cmd := exec.Command(
		"kubectl",
		"patch",
		"tenantrequests.idp.fluxdojo.local",
		name,
		"--subresource=status",
		"--type=merge",
		"-p",
		patch,
	)

	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
		fmt.Println("approval failed:", err)
		os.Exit(1)
	}

	fmt.Println("Tenant approved:", name)
}
