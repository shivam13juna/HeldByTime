// Package wire defines the closed error domain spoken across the Swift<->helper
// boundary and the JSON-on-stderr encoding for it.
//
// There are exactly seven codes (FORMAT.md section 9, SECURITY_INVARIANTS I9). The
// Swift side switches only on this closed set; any unknown code, malformed
// stderr, or stdout-alongside-error is treated as fail-closed. The helper
// therefore never emits anything outside this vocabulary, and never writes a
// partial result to stdout before failing.
package wire

import (
	"encoding/json"
	"fmt"
	"io"

	"vaultseal/internal/constants"
)

// Code is one of the seven closed helper-domain error codes.
type Code string

const (
	RoundNotReady Code = "round_not_ready" // target round has not been published yet
	RoundTooNear  Code = "round_too_near"  // seal target is not far enough in the future
	StaleRound    Code = "stale_round"     // network "latest" is suspiciously old vs the clock
	AuthFailed    Code = "auth_failed"     // beacon/ciphertext failed cryptographic verification
	ParseError    Code = "parse_error"     // bad CLI args, unreadable stdin, or malformed response
	ChainMismatch Code = "chain_mismatch"  // a drand endpoint served a different chain
	Timeout       Code = "timeout"         // network unreachable / no endpoint answered in time
)

// closedSet is the authoritative vocabulary; tests assert nothing escapes it.
var closedSet = map[Code]struct{}{
	RoundNotReady: {}, RoundTooNear: {}, StaleRound: {}, AuthFailed: {},
	ParseError: {}, ChainMismatch: {}, Timeout: {},
}

// IsKnown reports whether c is part of the closed helper domain.
func IsKnown(c Code) bool { _, ok := closedSet[c]; return ok }

// AllCodes returns the closed set (for tests).
func AllCodes() []Code {
	out := make([]Code, 0, len(closedSet))
	for c := range closedSet {
		out = append(out, c)
	}
	return out
}

// Error is a helper-domain error carrying one closed code plus a human detail.
type Error struct {
	Code   Code
	Detail string
}

func (e *Error) Error() string {
	if e.Detail == "" {
		return string(e.Code)
	}
	return string(e.Code) + ": " + e.Detail
}

// New builds an Error with a literal detail.
func New(code Code, detail string) *Error { return &Error{Code: code, Detail: detail} }

// Newf builds an Error with a formatted detail.
func Newf(code Code, format string, a ...any) *Error {
	return &Error{Code: code, Detail: fmt.Sprintf(format, a...)}
}

// Emit writes the closed-domain JSON error to w (stderr), bounded well under
// MAX_STDERR_BYTES so the Swift side never has to truncate. It writes exactly
// one line and nothing else.
func (e *Error) Emit(w io.Writer) {
	code := e.Code
	if !IsKnown(code) {
		// Defense in depth: an Error must never carry a code outside the
		// closed set. If one ever does, collapse to parse_error rather than
		// leaking an unknown token the Swift side would (correctly) reject.
		code = ParseError
	}
	detail := e.Detail
	const envelope = 64 // room for the JSON keys/braces around the detail
	if max := constants.MAX_STDERR_BYTES - envelope; max > 0 && len(detail) > max {
		detail = detail[:max]
	}
	payload := struct {
		Error  string `json:"error"`
		Detail string `json:"detail,omitempty"`
	}{Error: string(code), Detail: detail}
	b, err := json.Marshal(payload)
	if err != nil {
		fmt.Fprintf(w, "{\"error\":%q}\n", string(code))
		return
	}
	w.Write(b)
	io.WriteString(w, "\n")
}
