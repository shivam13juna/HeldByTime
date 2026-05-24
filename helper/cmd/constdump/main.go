// constdump — emits the compiled Go constants as JSON on stdout.
// Used only by the consistency test (tests/consistency_check.swift).
package main

import (
	"encoding/json"
	"os"

	"vaultseal/internal/constants"
)

func main() {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(constants.All); err != nil {
		os.Stderr.WriteString("constdump: " + err.Error() + "\n")
		os.Exit(1)
	}
}
