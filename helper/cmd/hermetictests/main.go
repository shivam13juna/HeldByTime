// Command hermetictests exercises the vaultseal helper without touching the
// network. It prints "RESULT: PASS|FAIL <name> [-- detail]" lines, matching the
// project's test-harness convention, and exits non-zero if any check fails.
//
// Two seams keep it hermetic:
//
//   - The seal operations take a seal.Network interface. A fake implementation
//     is seeded with REAL drand quicknet beacons (KATs fetched from
//     api.drand.sh and pinned below), so the genuine tlock IBE crypto and BLS
//     verification run against genuine signatures — only the HTTP fetch is
//     replaced. A successful round-trip here therefore proves the same crypto
//     path the live network test exercised.
//   - Negative-CLI cases exec the built binary with malformed arguments. Those
//     fail during argument parsing, before any network or crypto work, so they
//     are fully offline.
//
// Usage: hermetictests <path-to-vaultseal-binary>
package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"time"

	"github.com/drand/drand/v2/crypto"
	"github.com/drand/kyber"

	"vaultseal/internal/constants"
	"vaultseal/internal/seal"
	"vaultseal/internal/wire"
)

// Real quicknet beacons (round -> G1 signature hex), fetched from
// https://api.drand.sh/<chainhash>/public/<round>. These verify against the
// compiled-in DRAND_GROUP_PUBLIC_KEY; that is exactly what makes the round-trip
// and forged-beacon tests meaningful rather than circular.
const (
	katRound       = 1000000
	katSig1000000  = "83ad29e4c409f9470fc2ef02f90214df49e02b441a1a241a82d622d9f608ef98fd8b11a029f1bee9d9e83b45088abe72"
	katSig1000001  = "a5bd91e5e2d8c0bf51bffdfad87eef34348fd9c0b2df2bee39db90bdef7e1399b1a77bb2fe98b24d84c0936a306c4218"
)

var failures int

func pass(name string)              { fmt.Printf("RESULT: PASS %s\n", name) }
func info(name, detail string)      { fmt.Printf("RESULT: INFO %s -- %s\n", name, detail) }
func fail(name, detail string)      { failures++; fmt.Printf("RESULT: FAIL %s -- %s\n", name, detail) }
func check(name string, ok bool, detail string) {
	if ok {
		pass(name)
	} else {
		fail(name, detail)
	}
}

// expectErr asserts werr carries exactly the wanted closed-domain code.
func expectErr(name string, want wire.Code, werr *wire.Error) {
	switch {
	case werr == nil:
		fail(name, "expected "+string(want)+", got nil")
	case werr.Code != want:
		fail(name, "expected "+string(want)+", got "+string(werr.Code))
	default:
		pass(name)
	}
}

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// fakeNet implements seal.Network (and thus tlock.Network) with no I/O.
type fakeNet struct {
	scheme     *crypto.Scheme
	pub        kyber.Point
	current    uint64
	latest     uint64
	latestErr  *wire.Error
	sigs       map[uint64][]byte
	lastSigErr *wire.Error
}

func newFake() *fakeNet {
	scheme, err := crypto.SchemeFromName(constants.DRAND_SCHEME)
	if err != nil {
		panic(err)
	}
	pub := scheme.KeyGroup.Point()
	if err := pub.UnmarshalBinary(mustHex(constants.DRAND_GROUP_PUBLIC_KEY)); err != nil {
		panic(err)
	}
	return &fakeNet{scheme: scheme, pub: pub, sigs: map[uint64][]byte{}}
}

func (f *fakeNet) ChainHash() string            { return constants.DRAND_CHAIN_HASH }
func (f *fakeNet) Current(time.Time) uint64      { return f.current }
func (f *fakeNet) PublicKey() kyber.Point        { return f.pub }
func (f *fakeNet) Scheme() crypto.Scheme         { return *f.scheme }
func (f *fakeNet) SwitchChainHash(string) error  { return wire.New(wire.ChainMismatch, "disabled") }
func (f *fakeNet) LastSigError() *wire.Error      { return f.lastSigErr }
func (f *fakeNet) VerifiedLatest() (uint64, *wire.Error) {
	if f.latestErr != nil {
		return 0, f.latestErr
	}
	return f.latest, nil
}
func (f *fakeNet) Signature(round uint64) ([]byte, error) {
	f.lastSigErr = nil
	if sig, ok := f.sigs[round]; ok {
		return sig, nil
	}
	f.lastSigErr = wire.Newf(wire.RoundNotReady, "round %d not available", round)
	return nil, f.lastSigErr
}

func main() {
	if len(os.Args) < 2 {
		fail("hermetic/args", "usage: hermetictests <vaultseal-binary>")
		os.Exit(1)
	}
	bin := os.Args[1]

	cryptoTests()
	logicTests()
	cliTests(bin)

	fmt.Printf("hermetic-done failures=%d\n", failures)
	if failures != 0 {
		os.Exit(1)
	}
}

// cryptoTests exercise the real tlock crypto path with real beacons.
func cryptoTests() {
	plain := []byte("MFST...manifest||PW01...opaque payload bytes \x00\x01\x02\xff")

	// Round-trip: seal to katRound (freshness satisfied), unseal with the real
	// beacon, recover the exact plaintext.
	f := newFake()
	f.latest = katRound - 100
	f.sigs[katRound] = mustHex(katSig1000000)
	var sealed bytes.Buffer
	if werr := seal.Seal(f, katRound, bytes.NewReader(plain), &sealed); werr != nil {
		fail("crypto/roundtrip-seal", werr.Error())
		return
	}
	pass("crypto/roundtrip-seal")
	info("crypto/sealed-size", fmt.Sprintf("%d bytes", sealed.Len()))

	var got bytes.Buffer
	if werr := seal.Unseal(f, bytes.NewReader(sealed.Bytes()), &got); werr != nil {
		fail("crypto/roundtrip-unseal", werr.Error())
	} else {
		check("crypto/roundtrip-plaintext", bytes.Equal(got.Bytes(), plain),
			fmt.Sprintf("got %d bytes, want %d", got.Len(), len(plain)))
	}

	// Future round: the beacon is not available, so it stays locked.
	notReady := newFake() // empty sigs map
	expectErr("crypto/future-round-locked", wire.RoundNotReady,
		seal.Unseal(notReady, bytes.NewReader(sealed.Bytes()), io.Discard))

	// Forged beacon: a valid-but-wrong signature must fail verification, not
	// silently decrypt to garbage.
	forged := newFake()
	forged.sigs[katRound] = mustHex(katSig1000001) // real, but for a different round
	expectErr("crypto/forged-beacon-rejected", wire.AuthFailed,
		seal.Unseal(forged, bytes.NewReader(sealed.Bytes()), io.Discard))

	// Corrupted ciphertext: flip a byte in the body; decryption must fail
	// closed with a known code.
	corrupt := append([]byte(nil), sealed.Bytes()...)
	corrupt[len(corrupt)/2] ^= 0x80
	good := newFake()
	good.sigs[katRound] = mustHex(katSig1000000)
	werr := seal.Unseal(good, bytes.NewReader(corrupt), io.Discard)
	check("crypto/corrupt-ciphertext-failclosed", werr != nil && wire.IsKnown(werr.Code),
		fmt.Sprintf("werr=%v", werr))
}

// logicTests exercise freshness, staleness, and error propagation.
func logicTests() {
	margin := uint64(constants.FRESHNESS_MARGIN_ROUNDS)

	// Freshness boundary: latest+margin is too near (<=); latest+margin+1 is OK.
	f := newFake()
	f.latest = 1000
	expectErr("logic/seal-too-near-boundary", wire.RoundTooNear,
		seal.Seal(f, 1000+margin, bytes.NewReader([]byte("x")), io.Discard))
	expectErr("logic/seal-past-rejected", wire.RoundTooNear,
		seal.Seal(f, 500, bytes.NewReader([]byte("x")), io.Discard))
	check("logic/seal-just-far-enough",
		seal.Seal(f, 1000+margin+1, bytes.NewReader([]byte("x")), io.Discard) == nil,
		"latest+margin+1 should be accepted")

	// Stale round: a verified latest far behind the clock-implied round.
	stale := newFake()
	stale.current = 1_000_000
	stale.latest = 100
	expectErr("logic/current-round-stale", wire.StaleRound,
		seal.CurrentRound(stale, time.Now(), io.Discard))

	// Fresh current-round: latest at/ahead of expected emits JSON.
	fresh := newFake()
	fresh.current = 1000
	fresh.latest = 1005
	var out bytes.Buffer
	if werr := seal.CurrentRound(fresh, time.Now(), &out); werr != nil {
		fail("logic/current-round-ok", werr.Error())
	} else {
		var res seal.CurrentRoundResult
		if err := json.Unmarshal(out.Bytes(), &res); err != nil {
			fail("logic/current-round-ok", "bad json: "+err.Error())
		} else {
			check("logic/current-round-ok", res.Round == 1005,
				fmt.Sprintf("round=%d", res.Round))
		}
	}

	// Network failure (VerifiedLatest) propagates as timeout, fail-closed.
	down := newFake()
	down.latestErr = wire.New(wire.Timeout, "unreachable")
	expectErr("logic/seal-network-down", wire.Timeout,
		seal.Seal(down, katRound, bytes.NewReader([]byte("x")), io.Discard))
	expectErr("logic/current-round-network-down", wire.Timeout,
		seal.CurrentRound(down, time.Now(), io.Discard))
}

// cliTests exec the real binary with malformed arguments. Each must exit
// non-zero, write nothing to stdout, and emit one closed-domain JSON error on
// stderr. All cases fail during argument parsing, so they never touch the
// network.
func cliTests(bin string) {
	cases := []struct {
		name string
		args []string
	}{
		{"cli/no-args", nil},
		{"cli/unknown-command", []string{"bogus"}},
		{"cli/seal-missing-round-flag", []string{"seal"}},
		{"cli/seal-missing-round-value", []string{"seal", "--round"}},
		{"cli/seal-nonnumeric-round", []string{"seal", "--round", "abc"}},
		{"cli/seal-negative-round", []string{"seal", "--round", "-5"}},
		{"cli/seal-zero-round", []string{"seal", "--round", "0"}},
		{"cli/seal-equals-form-rejected", []string{"seal", "--round=5"}},
		{"cli/seal-extra-arg", []string{"seal", "--round", "5", "extra"}},
		{"cli/unseal-extra-arg", []string{"unseal", "x"}},
		{"cli/unseal-forbidden-file-flag", []string{"unseal", "--file", "/etc/passwd"}},
		{"cli/current-round-extra-arg", []string{"current-round", "x"}},
		{"cli/forbidden-chain-flag", []string{"--chain", "evil"}},
	}
	for _, c := range cases {
		cmd := exec.Command(bin, c.args...)
		cmd.Stdin = bytes.NewReader(nil)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		err := cmd.Run()

		exitNonZero := false
		if ee, ok := err.(*exec.ExitError); ok {
			exitNonZero = ee.ExitCode() != 0
		} else if err == nil {
			exitNonZero = false
		} else {
			fail(c.name, "could not run binary: "+err.Error())
			continue
		}

		if !exitNonZero {
			fail(c.name, "expected non-zero exit")
			continue
		}
		if stdout.Len() != 0 {
			fail(c.name, fmt.Sprintf("stdout not empty (%d bytes)", stdout.Len()))
			continue
		}
		var payload struct {
			Error string `json:"error"`
		}
		if err := json.Unmarshal(bytes.TrimSpace(stderr.Bytes()), &payload); err != nil {
			fail(c.name, "stderr not JSON: "+stderr.String())
			continue
		}
		if !wire.IsKnown(wire.Code(payload.Error)) {
			fail(c.name, "error code outside closed set: "+payload.Error)
			continue
		}
		pass(c.name)
	}
}
