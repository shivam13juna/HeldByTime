// Package drandnet implements the tlock.Network interface against the drand
// quicknet HTTP API using only the Go standard library for I/O.
//
// Design (SECURITY_INVARIANTS I9, app.md section 9):
//   - The chain hash, group public key, scheme, genesis, and period are
//     COMPILED IN from internal/constants. They are never read from a file, an
//     environment variable, or a CLI flag, so there is no forged-chain escape
//     hatch.
//   - Every consulted endpoint's /info is verified against those compiled-in
//     values; a 200 response advertising a different chain is fatal
//     (chain_mismatch), never silently used.
//   - Fetched beacon signatures are BLS-verified against the compiled-in public
//     key before being handed to decryption (defense in depth: TimeUnlock also
//     verifies).
//   - The endpoint list is compiled in; there is no override.
package drandnet

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	chain "github.com/drand/drand/v2/common"
	"github.com/drand/drand/v2/crypto"
	"github.com/drand/kyber"

	"vaultseal/internal/constants"
	"vaultseal/internal/wire"
)

// DefaultEndpoints are the compiled-in drand HTTP roots. api.drand.sh is the
// primary; the others are independent mirrors used to cross-check the latest
// round. These hosts must be reachable (allow-listed through any content filter) or the vault
// deadlocks; the Task 8 self-test verifies reachability.
var DefaultEndpoints = []string{
	"https://api.drand.sh",
	"https://api2.drand.sh",
	"https://api3.drand.sh",
}

// maxHTTPBody caps a single drand response. Real responses are well under 1 KiB.
const maxHTTPBody int64 = 64 * 1024

// Network implements tlock.Network over the drand HTTP API.
type Network struct {
	scheme    *crypto.Scheme
	pub       kyber.Point
	chainHash string
	endpoints []string
	client    *http.Client
	timeout   time.Duration

	// lastSigErr preserves the real cause of the most recent Signature()
	// failure. tlock's Decrypt flattens any Signature() error into ErrTooEarly,
	// which would otherwise erase the distinction between "round not published"
	// and "network timed out" / "endpoint served a forged signature".
	lastSigErr *wire.Error
}

// New constructs the production Network from compiled-in constants.
func New() (*Network, *wire.Error) {
	scheme, err := crypto.SchemeFromName(constants.DRAND_SCHEME)
	if err != nil {
		return nil, wire.Newf(wire.ParseError, "scheme %q: %v", constants.DRAND_SCHEME, err)
	}
	pkBytes, err := hex.DecodeString(constants.DRAND_GROUP_PUBLIC_KEY)
	if err != nil {
		return nil, wire.Newf(wire.ParseError, "decode public key: %v", err)
	}
	pub := scheme.KeyGroup.Point()
	if err := pub.UnmarshalBinary(pkBytes); err != nil {
		return nil, wire.Newf(wire.ParseError, "unmarshal public key: %v", err)
	}
	timeout := time.Duration(constants.HELPER_TIMEOUT_MS) * time.Millisecond
	return &Network{
		scheme:    scheme,
		pub:       pub,
		chainHash: constants.DRAND_CHAIN_HASH,
		endpoints: DefaultEndpoints,
		client:    &http.Client{Timeout: timeout},
		timeout:   timeout,
	}, nil
}

// --- tlock.Network interface ------------------------------------------------

func (n *Network) ChainHash() string         { return n.chainHash }
func (n *Network) PublicKey() kyber.Point     { return n.pub }
func (n *Network) Scheme() crypto.Scheme      { return *n.scheme }
func (n *Network) Current(t time.Time) uint64 { return ExpectedRound(t) }

// SwitchChainHash is deliberately disabled: the helper is bound to exactly one
// chain. tlock would otherwise offer to follow a chain hash embedded in a
// ciphertext; .Strict() already prevents that, and this makes it impossible.
func (n *Network) SwitchChainHash(string) error {
	return wire.New(wire.ChainMismatch, "chain switching is disabled")
}

// Signature fetches the beacon signature for round, trying each endpoint until
// one returns a signature that BLS-verifies against the compiled-in public key.
// On failure it records the real cause in lastSigErr and returns it.
func (n *Network) Signature(round uint64) ([]byte, error) {
	n.lastSigErr = nil
	var sawNotReady bool
	var hardErr *wire.Error
	for _, ep := range n.endpoints {
		sig, werr := n.fetchSignature(ep, round)
		if werr == nil {
			beacon := chain.Beacon{Round: round, Signature: sig}
			if verr := n.scheme.VerifyBeacon(&beacon, n.pub); verr != nil {
				if hardErr == nil {
					hardErr = wire.Newf(wire.AuthFailed, "beacon %d failed verification: %v", round, verr)
				}
				continue
			}
			return sig, nil
		}
		if werr.Code == wire.RoundNotReady {
			sawNotReady = true
		} else if hardErr == nil {
			hardErr = werr
		}
	}
	switch {
	case hardErr != nil:
		n.lastSigErr = hardErr
	case sawNotReady:
		n.lastSigErr = wire.Newf(wire.RoundNotReady, "round %d not yet published", round)
	default:
		n.lastSigErr = wire.Newf(wire.Timeout, "round %d unavailable from all endpoints", round)
	}
	return nil, n.lastSigErr
}

// LastSigError returns the preserved cause of the most recent Signature()
// failure, or nil. Used to recover the true error after tlock flattens it.
func (n *Network) LastSigError() *wire.Error { return n.lastSigErr }

// --- round/time math --------------------------------------------------------

// ExpectedRound is the documented round-at-time convention (FORMAT.md section 8):
// round 1 is published at genesis, advancing every period thereafter. The
// stale-round tolerance absorbs any off-by-one against the network's own clock.
func ExpectedRound(now time.Time) uint64 {
	elapsed := now.Unix() - int64(constants.DRAND_GENESIS_UNIX)
	if elapsed < int64(constants.DRAND_PERIOD_SECONDS) {
		return 1
	}
	return uint64(elapsed/int64(constants.DRAND_PERIOD_SECONDS)) + 1
}

// VerifiedLatest returns the maximum "latest" round across all endpoints whose
// /info verifies against the compiled-in chain. A 200 /info advertising a
// different chain is fatal. It errors only if no endpoint yields a latest round.
func (n *Network) VerifiedLatest() (uint64, *wire.Error) {
	var max uint64
	var any bool
	var lastErr *wire.Error
	for _, ep := range n.endpoints {
		if cerr := n.verifyChainInfo(ep); cerr != nil {
			if cerr.Code == wire.ChainMismatch {
				return 0, cerr // a wrong chain is never tolerated, even from one mirror
			}
			lastErr = cerr
			continue
		}
		r, werr := n.fetchLatest(ep)
		if werr != nil {
			lastErr = werr
			continue
		}
		any = true
		if r > max {
			max = r
		}
	}
	if !any {
		if lastErr != nil {
			return 0, lastErr
		}
		return 0, wire.New(wire.Timeout, "no endpoint returned a latest round")
	}
	return max, nil
}

// --- per-endpoint diagnostic probe (Task 8 self-test) -----------------------

// EndpointStatus is one endpoint's independent reachability result. Unlike
// VerifiedLatest (the hot path, which is fatal on any chain mismatch and returns
// the max round), the probe is NON-FATAL per endpoint: it reports every
// endpoint's state so the first-run self-test can show per-endpoint
// reachability and apply its own policy (>=1 reachable = hard pass, warn unless
// >=2). A forged chain is reported here as code "chain_mismatch" rather than
// aborting the whole probe; the Swift policy treats any such code as a hard
// failure. Codes are exactly the closed wire domain.
type EndpointStatus struct {
	Endpoint string `json:"endpoint"`     // the HTTP root probed
	OK       bool   `json:"ok"`           // chain /info verified AND /public/latest fetched
	Round    uint64 `json:"round"`        // verified latest from this endpoint (0 unless OK)
	Code     string `json:"code"`         // "" when OK, else the closed wire code for the failure
}

// ProbeEndpoints reaches each compiled-in endpoint independently and reports its
// reachability. An endpoint is OK only if its /info verifies against the
// compiled-in chain AND its /public/latest is fetched. The probe never aborts on
// one endpoint's failure; it always returns one status per endpoint, in
// compiled-in order. It does not error: an all-down result is a successful probe
// whose report says so.
func (n *Network) ProbeEndpoints() []EndpointStatus {
	out := make([]EndpointStatus, 0, len(n.endpoints))
	for _, ep := range n.endpoints {
		st := EndpointStatus{Endpoint: ep}
		if cerr := n.verifyChainInfo(ep); cerr != nil {
			st.Code = string(cerr.Code)
			out = append(out, st)
			continue
		}
		r, werr := n.fetchLatest(ep)
		if werr != nil {
			st.Code = string(werr.Code)
			out = append(out, st)
			continue
		}
		st.OK = true
		st.Round = r
		out = append(out, st)
	}
	return out
}

// --- HTTP plumbing ----------------------------------------------------------

type roundResponse struct {
	Round     uint64 `json:"round"`
	Signature string `json:"signature"`
}

type infoResponse struct {
	PublicKey   string `json:"public_key"`
	Period      int    `json:"period"`
	GenesisTime int64  `json:"genesis_time"`
	Hash        string `json:"hash"`
	SchemeID    string `json:"schemeID"`
}

func (n *Network) fetchSignature(endpoint string, round uint64) ([]byte, *wire.Error) {
	url := fmt.Sprintf("%s/%s/public/%d", strings.TrimRight(endpoint, "/"), n.chainHash, round)
	body, status, werr := n.get(url)
	if werr != nil {
		return nil, werr
	}
	// drand serves 425 "Too Early" (and some deployments 404) for a round that
	// has not been published yet: that is round_not_ready, not a network fault.
	if status == http.StatusTooEarly || status == http.StatusNotFound {
		return nil, wire.Newf(wire.RoundNotReady, "http %d", status)
	}
	if status != http.StatusOK {
		return nil, wire.Newf(wire.Timeout, "public/%d: http %d", round, status)
	}
	var rr roundResponse
	if err := json.Unmarshal(body, &rr); err != nil {
		return nil, wire.Newf(wire.ParseError, "round json: %v", err)
	}
	if rr.Round != round {
		return nil, wire.Newf(wire.AuthFailed, "round mismatch: got %d want %d", rr.Round, round)
	}
	sig, err := hex.DecodeString(rr.Signature)
	if err != nil {
		return nil, wire.Newf(wire.ParseError, "signature hex: %v", err)
	}
	return sig, nil
}

func (n *Network) fetchLatest(endpoint string) (uint64, *wire.Error) {
	url := fmt.Sprintf("%s/%s/public/latest", strings.TrimRight(endpoint, "/"), n.chainHash)
	body, status, werr := n.get(url)
	if werr != nil {
		return 0, werr
	}
	if status != http.StatusOK {
		return 0, wire.Newf(wire.Timeout, "public/latest: http %d", status)
	}
	var rr roundResponse
	if err := json.Unmarshal(body, &rr); err != nil {
		return 0, wire.Newf(wire.ParseError, "latest json: %v", err)
	}
	return rr.Round, nil
}

func (n *Network) verifyChainInfo(endpoint string) *wire.Error {
	url := fmt.Sprintf("%s/%s/info", strings.TrimRight(endpoint, "/"), n.chainHash)
	body, status, werr := n.get(url)
	if werr != nil {
		return werr
	}
	if status != http.StatusOK {
		return wire.Newf(wire.Timeout, "info: http %d", status)
	}
	var info infoResponse
	if err := json.Unmarshal(body, &info); err != nil {
		return wire.Newf(wire.ParseError, "info json: %v", err)
	}
	if !strings.EqualFold(info.Hash, n.chainHash) {
		return wire.Newf(wire.ChainMismatch, "hash %s", info.Hash)
	}
	if !strings.EqualFold(info.PublicKey, constants.DRAND_GROUP_PUBLIC_KEY) {
		return wire.New(wire.ChainMismatch, "public key mismatch")
	}
	if info.SchemeID != constants.DRAND_SCHEME {
		return wire.Newf(wire.ChainMismatch, "scheme %s", info.SchemeID)
	}
	if info.Period != constants.DRAND_PERIOD_SECONDS {
		return wire.Newf(wire.ChainMismatch, "period %d", info.Period)
	}
	if info.GenesisTime != int64(constants.DRAND_GENESIS_UNIX) {
		return wire.Newf(wire.ChainMismatch, "genesis %d", info.GenesisTime)
	}
	return nil
}

func (n *Network) get(url string) ([]byte, int, *wire.Error) {
	ctx, cancel := context.WithTimeout(context.Background(), n.timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, 0, wire.Newf(wire.ParseError, "build request: %v", err)
	}
	resp, err := n.client.Do(req)
	if err != nil {
		return nil, 0, wire.Newf(wire.Timeout, "http get: %v", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxHTTPBody+1))
	if err != nil {
		return nil, resp.StatusCode, wire.Newf(wire.Timeout, "read body: %v", err)
	}
	if int64(len(body)) > maxHTTPBody {
		return nil, resp.StatusCode, wire.New(wire.ParseError, "response exceeds size cap")
	}
	return body, resp.StatusCode, nil
}
