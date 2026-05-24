// Package seal implements the three helper operations: seal, unseal, and
// current-round. The payload (manifest||PW01) is opaque to this package; it is
// time-locked/unlocked as bytes (FORMAT.md section 3).
//
// All three buffer their entire result in memory and write to the output
// stream only on success, so the helper never emits a partial result to stdout
// alongside an error (the Swift side fails closed if it ever sees that).
package seal

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"time"

	"github.com/drand/tlock"

	"vaultseal/internal/constants"
	"vaultseal/internal/wire"
)

const maxPayload int64 = constants.MAX_SEALED_PAYLOAD_BYTES

// Network is everything the seal operations need: the tlock.Network methods
// (used by tlock's Encrypt/Decrypt) plus the helper's own freshness and
// error-recovery accessors. *drandnet.Network satisfies it in production; tests
// inject a fake seeded with a real beacon so the crypto path is exercised
// hermetically.
type Network interface {
	tlock.Network
	VerifiedLatest() (uint64, *wire.Error)
	LastSigError() *wire.Error
}

// Seal time-locks the stdin payload to round, after verifying against the live
// network that round is far enough in the future (freshness margin). Requires
// the network so a too-near or unverifiable target fails closed.
func Seal(net Network, round uint64, in io.Reader, out io.Writer) *wire.Error {
	plain, werr := readCapped(in)
	if werr != nil {
		return werr
	}

	latest, werr := net.VerifiedLatest()
	if werr != nil {
		return werr
	}
	if round <= latest+uint64(constants.FRESHNESS_MARGIN_ROUNDS) {
		return wire.Newf(wire.RoundTooNear,
			"target round %d <= latest %d + margin %d", round, latest, constants.FRESHNESS_MARGIN_ROUNDS)
	}

	var buf bytes.Buffer
	// .Strict() pins decryption to our chain hash; it is harmless for Encrypt
	// but kept for symmetry with Unseal.
	if err := tlock.New(net).Strict().Encrypt(&buf, bytes.NewReader(plain), round); err != nil {
		return wire.Newf(wire.ParseError, "encrypt: %v", err)
	}
	if int64(buf.Len()) > maxPayload {
		return wire.New(wire.ParseError, "sealed payload exceeds size cap")
	}
	if _, err := out.Write(buf.Bytes()); err != nil {
		return wire.Newf(wire.ParseError, "write stdout: %v", err)
	}
	return nil
}

// Unseal time-unlocks the stdin sealed payload and writes the recovered
// plaintext to stdout. It fetches the target round's beacon from the network;
// if the round has not been published, the payload stays cryptographically
// locked and round_not_ready is returned.
func Unseal(net Network, in io.Reader, out io.Writer) *wire.Error {
	sealed, werr := readCapped(in)
	if werr != nil {
		return werr
	}

	var buf bytes.Buffer
	if err := tlock.New(net).Strict().Decrypt(&buf, bytes.NewReader(sealed)); err != nil {
		return mapDecryptError(net, err)
	}
	if int64(buf.Len()) > maxPayload {
		return wire.New(wire.ParseError, "plaintext exceeds size cap")
	}
	if _, err := out.Write(buf.Bytes()); err != nil {
		return wire.Newf(wire.ParseError, "write stdout: %v", err)
	}
	return nil
}

// CurrentRoundResult is the JSON emitted by current-round on success.
type CurrentRoundResult struct {
	Round       uint64 `json:"round"`        // max verified latest across endpoints
	ExpectedNow uint64 `json:"expected_now"` // round implied by the local clock
	UnixTime    int64  `json:"unix_time"`    // the clock value used
}

// CurrentRound reports the verified latest round, rejecting a network "latest"
// that is suspiciously older than the local clock implies (stale_round). The
// clock is used only to REJECT a too-old latest, never to grant access
// (FORMAT.md section 8).
func CurrentRound(net Network, now time.Time, out io.Writer) *wire.Error {
	latest, werr := net.VerifiedLatest()
	if werr != nil {
		return werr
	}
	expected := net.Current(now)
	tol := uint64(constants.STALE_ROUND_TOLERANCE_ROUNDS)
	if expected > tol && latest < expected-tol {
		return wire.Newf(wire.StaleRound,
			"verified latest %d < expected %d - tolerance %d", latest, expected, tol)
	}
	res := CurrentRoundResult{Round: latest, ExpectedNow: expected, UnixTime: now.Unix()}
	b, err := json.Marshal(res)
	if err != nil {
		return wire.Newf(wire.ParseError, "marshal result: %v", err)
	}
	if _, err := out.Write(b); err != nil {
		return wire.Newf(wire.ParseError, "write stdout: %v", err)
	}
	io.WriteString(out, "\n")
	return nil
}

// mapDecryptError translates a tlock Decrypt failure into the closed helper
// domain. The Network preserved the true cause of any Signature() failure,
// which tlock would otherwise have flattened into ErrTooEarly.
func mapDecryptError(net Network, err error) *wire.Error {
	if se := net.LastSigError(); se != nil {
		return se
	}
	if errors.Is(err, tlock.ErrWrongChainhash) {
		return wire.New(wire.ChainMismatch, "ciphertext is bound to a different chain")
	}
	if errors.Is(err, tlock.ErrTooEarly) {
		return wire.New(wire.RoundNotReady, "target round has not been reached")
	}
	// Anything else (forged/corrupt ciphertext, failed beacon verification,
	// age header that does not parse) is a cryptographic failure: fail closed.
	return wire.New(wire.AuthFailed, "could not decrypt sealed payload")
}

func readCapped(in io.Reader) ([]byte, *wire.Error) {
	b, err := io.ReadAll(io.LimitReader(in, maxPayload+1))
	if err != nil {
		return nil, wire.Newf(wire.ParseError, "read stdin: %v", err)
	}
	if int64(len(b)) > maxPayload {
		return nil, wire.New(wire.ParseError, "input exceeds size cap")
	}
	return b, nil
}
