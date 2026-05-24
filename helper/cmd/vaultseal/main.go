// Command vaultseal is the only component that talks to the drand network.
//
// Surface (deliberately tiny; SECURITY_INVARIANTS I9):
//
//	vaultseal seal --round N    # stdin: manifest||PW01 -> stdout: sealed payload
//	vaultseal unseal            # stdin: sealed payload -> stdout: manifest||PW01
//	vaultseal current-round     # stdout: JSON {round, expected_now, unix_time}
//
// There are no file-path, network, or chain-override flags. Input is read only
// from stdin; the result is written only to stdout, and only on success. Any
// error is emitted as a single closed-domain JSON line on stderr with a
// non-zero exit and nothing on stdout.
package main

import (
	"os"
	"strconv"
	"time"

	"vaultseal/internal/drandnet"
	"vaultseal/internal/seal"
	"vaultseal/internal/wire"
)

func main() {
	if werr := run(os.Args[1:]); werr != nil {
		werr.Emit(os.Stderr)
		os.Exit(1)
	}
}

func run(args []string) *wire.Error {
	cmd, round, werr := parseArgs(args)
	if werr != nil {
		return werr
	}

	net, nerr := drandnet.New()
	if nerr != nil {
		return nerr
	}

	switch cmd {
	case "seal":
		return seal.Seal(net, round, os.Stdin, os.Stdout)
	case "unseal":
		return seal.Unseal(net, os.Stdin, os.Stdout)
	case "current-round":
		return seal.CurrentRound(net, time.Now(), os.Stdout)
	default:
		// parseArgs only ever returns the three commands above.
		return wire.New(wire.ParseError, "unreachable command")
	}
}

// parseArgs enforces the exact argument shapes. Any extra token, unknown flag,
// or malformed round is parse_error. This is what makes the "no override flags"
// guarantee total: anything that is not one of the three exact forms is
// rejected before any network or crypto work happens.
func parseArgs(args []string) (cmd string, round uint64, werr *wire.Error) {
	if len(args) == 0 {
		return "", 0, wire.New(wire.ParseError, "no command (want seal|unseal|current-round)")
	}
	switch args[0] {
	case "seal":
		if len(args) != 3 || args[1] != "--round" {
			return "", 0, wire.New(wire.ParseError, "usage: seal --round N")
		}
		r, rerr := parseRound(args[2])
		if rerr != nil {
			return "", 0, rerr
		}
		return "seal", r, nil
	case "unseal":
		if len(args) != 1 {
			return "", 0, wire.New(wire.ParseError, "usage: unseal (no arguments)")
		}
		return "unseal", 0, nil
	case "current-round":
		if len(args) != 1 {
			return "", 0, wire.New(wire.ParseError, "usage: current-round (no arguments)")
		}
		return "current-round", 0, nil
	default:
		return "", 0, wire.Newf(wire.ParseError, "unknown command %q", args[0])
	}
}

// parseRound accepts only a bare base-10 uint64 >= 1: no sign, no 0x prefix, no
// whitespace, no "--round=N" form (that is rejected upstream by the exact-token
// check).
func parseRound(s string) (uint64, *wire.Error) {
	if s == "" {
		return 0, wire.New(wire.ParseError, "empty round")
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, wire.New(wire.ParseError, "round must be base-10 digits only")
		}
	}
	r, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return 0, wire.Newf(wire.ParseError, "round: %v", err)
	}
	if r == 0 {
		return 0, wire.New(wire.ParseError, "round must be >= 1")
	}
	return r, nil
}
