package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

func main() {
	rootCmd := &cobra.Command{
		Use:   "kubectl-tenant",
		Short: "kubectl plugin for managing tenant requests",
	}

	rootCmd.AddCommand(newApproveCmd())
	rootCmd.AddCommand(newCompletionCmd(rootCmd))

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func newApproveCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "approve <tenantrequest>",
		Short: "Approve a tenant request",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			approve(args[0])
		},
	}

	// 🔥 Dynamic autocomplete for tenant names
	cmd.ValidArgsFunction = func(
		cmd *cobra.Command,
		args []string,
		toComplete string,
	) ([]string, cobra.ShellCompDirective) {

		out, err := exec.Command(
			"kubectl",
			"get",
			"tenantrequests.idp.rezakara.demo",
			"-o",
			"jsonpath={.items[*].metadata.name}",
		).Output()

		if err != nil {
			return nil, cobra.ShellCompDirectiveNoFileComp
		}

		names := strings.Fields(string(out))
		if len(names) == 0 {
			return nil, cobra.ShellCompDirectiveNoFileComp
		}

		// 🔍 Filter based on current input (important for UX)
		var filtered []string
		for _, n := range names {
			if strings.HasPrefix(n, toComplete) {
				filtered = append(filtered, n)
			}
		}

		return filtered, cobra.ShellCompDirectiveNoFileComp
	}

	return cmd
}

func newCompletionCmd(root *cobra.Command) *cobra.Command {
	return &cobra.Command{
		Use:   "completion [bash|zsh|fish]",
		Short: "Generate shell completion script",
		Args:  cobra.ExactArgs(1),
		Run: func(cmd *cobra.Command, args []string) {
			switch args[0] {
			case "bash":
				root.GenBashCompletion(os.Stdout)
			case "zsh":
				root.GenZshCompletion(os.Stdout)
			case "fish":
				root.GenFishCompletion(os.Stdout, true)
			default:
				fmt.Println("unsupported shell")
			}
		},
	}
}

func approve(name string) {
	timestamp := time.Now().UTC().Format(time.RFC3339)

	// 1. Get full resource JSON
	out, err := exec.Command(
		"kubectl",
		"get",
		"tenantrequests.idp.rezakara.demo",
		name,
		"-o",
		"json",
	).Output()

	if err != nil {
		fmt.Println("failed to fetch resource:", err)
		os.Exit(1)
	}

	// 2. Parse JSON
	var obj map[string]interface{}
	if err := json.Unmarshal(out, &obj); err != nil {
		fmt.Println("failed to parse JSON:", err)
		os.Exit(1)
	}

	// 3. Extract conditions
	status, _ := obj["status"].(map[string]interface{})
	conditions, _ := status["conditions"].([]interface{})

	found := false

	// 4. Update or insert Approved condition
	for i, c := range conditions {
		cond := c.(map[string]interface{})
		if cond["type"] == "Approved" {
			found = true

			// Already approved → idempotent exit
			if cond["status"] == "True" {
				fmt.Println("Tenant already approved")
				return
			}

			// Update existing condition
			conditions[i] = map[string]interface{}{
				"type":               "Approved",
				"status":             "True",
				"reason":             "PlatformApproved",
				"message":            "Tenant approved by platform team",
				"lastTransitionTime": timestamp,
			}
		}
	}

	// 5. If not found → append
	if !found {
		conditions = append(conditions, map[string]interface{}{
			"type":               "Approved",
			"status":             "True",
			"reason":             "PlatformApproved",
			"message":            "Tenant approved by platform team",
			"lastTransitionTime": timestamp,
		})
	}

	// 6. Build patch
	patchObj := map[string]interface{}{
		"status": map[string]interface{}{
			"conditions": conditions,
		},
	}

	patchBytes, _ := json.Marshal(patchObj)

	// 7. Apply patch
	cmd := exec.Command(
		"kubectl",
		"patch",
		"tenantrequests.idp.rezakara.demo",
		name,
		"--subresource=status",
		"--type=merge",
		"-p",
		string(patchBytes),
	)

	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		fmt.Println("approval failed:", err)
		os.Exit(1)
	}

	fmt.Println("Tenant approved:", name)
}
