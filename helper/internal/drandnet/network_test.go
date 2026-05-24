// Tests for the real HTTP layer of drandnet.Network, driven by in-process
// httptest servers (no external network). These cover the code the fake-network
// hermetic suite cannot reach: chain-info verification (the chain_mismatch
// defense), HTTP status mapping, max-round-across-endpoints, HTTP-layer beacon
// verification, and the response size cap.
//
// Being in package drandnet, the tests construct *Network directly with custom
// endpoints, so production code keeps no endpoint-injection seam.
package drandnet

import (
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"vaultseal/internal/constants"
	"vaultseal/internal/wire"
)

// Real quicknet beacons (verify against the compiled-in public key).
const (
	katRound      = 1000000
	katSig1000000 = "83ad29e4c409f9470fc2ef02f90214df49e02b441a1a241a82d622d9f608ef98fd8b11a029f1bee9d9e83b45088abe72"
	katSig1000001 = "a5bd91e5e2d8c0bf51bffdfad87eef34348fd9c0b2df2bee39db90bdef7e1399b1a77bb2fe98b24d84c0936a306c4218"
)

func testNetwork(t *testing.T, endpoints ...string) *Network {
	t.Helper()
	n, werr := New()
	if werr != nil {
		t.Fatalf("New: %v", werr)
	}
	n.endpoints = endpoints
	n.client = &http.Client{Timeout: 3 * time.Second}
	n.timeout = 3 * time.Second
	return n
}

func validInfo() string {
	return fmt.Sprintf(
		`{"public_key":"%s","period":%d,"genesis_time":%d,"hash":"%s","schemeID":"%s","metadata":{"beaconID":"%s"}}`,
		constants.DRAND_GROUP_PUBLIC_KEY, constants.DRAND_PERIOD_SECONDS,
		constants.DRAND_GENESIS_UNIX, constants.DRAND_CHAIN_HASH,
		constants.DRAND_SCHEME, constants.DRAND_BEACON_ID)
}

// mockServer serves the drand HTTP routes. info/latest are fixed; round
// responses are taken from the provided maps (body and status).
type mockServer struct {
	info        string
	infoStatus  int
	latest      uint64
	roundBody   map[uint64]string
	roundStatus map[uint64]int
}

func (m *mockServer) start(t *testing.T) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.HasSuffix(path, "/info"):
			if m.infoStatus != 0 {
				w.WriteHeader(m.infoStatus)
			}
			fmt.Fprint(w, m.info)
		case strings.HasSuffix(path, "/public/latest"):
			fmt.Fprintf(w, `{"round":%d,"signature":""}`, m.latest)
		case strings.Contains(path, "/public/"):
			var round uint64
			fmt.Sscanf(path[strings.LastIndex(path, "/")+1:], "%d", &round)
			if st, ok := m.roundStatus[round]; ok && st != 0 {
				w.WriteHeader(st)
			}
			if body, ok := m.roundBody[round]; ok {
				fmt.Fprint(w, body)
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func roundJSON(round uint64, sigHex string) string {
	return fmt.Sprintf(`{"round":%d,"randomness":"","signature":"%s"}`, round, sigHex)
}

func TestVerifiedLatestHappy(t *testing.T) {
	m := &mockServer{info: validInfo(), latest: 500}
	n := testNetwork(t, m.start(t))
	got, werr := n.VerifiedLatest()
	if werr != nil {
		t.Fatalf("unexpected error: %v", werr)
	}
	if got != 500 {
		t.Fatalf("latest = %d, want 500", got)
	}
}

func TestVerifiedLatestMaxAcrossEndpoints(t *testing.T) {
	a := &mockServer{info: validInfo(), latest: 100}
	b := &mockServer{info: validInfo(), latest: 200}
	n := testNetwork(t, a.start(t), b.start(t))
	got, werr := n.VerifiedLatest()
	if werr != nil {
		t.Fatalf("unexpected error: %v", werr)
	}
	if got != 200 {
		t.Fatalf("latest = %d, want 200 (max across endpoints)", got)
	}
}

func TestChainMismatchIsFatal(t *testing.T) {
	cases := []struct {
		name string
		info string
	}{
		{"wrong-hash", `{"public_key":"` + constants.DRAND_GROUP_PUBLIC_KEY + `","period":3,"genesis_time":1692803367,"hash":"00ff","schemeID":"bls-unchained-g1-rfc9380"}`},
		{"wrong-pubkey", `{"public_key":"aabb","period":3,"genesis_time":1692803367,"hash":"` + constants.DRAND_CHAIN_HASH + `","schemeID":"bls-unchained-g1-rfc9380"}`},
		{"wrong-scheme", `{"public_key":"` + constants.DRAND_GROUP_PUBLIC_KEY + `","period":3,"genesis_time":1692803367,"hash":"` + constants.DRAND_CHAIN_HASH + `","schemeID":"pedersen-bls-chained"}`},
		{"wrong-period", `{"public_key":"` + constants.DRAND_GROUP_PUBLIC_KEY + `","period":30,"genesis_time":1692803367,"hash":"` + constants.DRAND_CHAIN_HASH + `","schemeID":"bls-unchained-g1-rfc9380"}`},
		{"wrong-genesis", `{"public_key":"` + constants.DRAND_GROUP_PUBLIC_KEY + `","period":3,"genesis_time":1,"hash":"` + constants.DRAND_CHAIN_HASH + `","schemeID":"bls-unchained-g1-rfc9380"}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			// Even though a second endpoint is healthy, a single mismatching
			// endpoint must be fatal: never proceed on a forged chain.
			bad := &mockServer{info: c.info, latest: 999}
			good := &mockServer{info: validInfo(), latest: 500}
			n := testNetwork(t, bad.start(t), good.start(t))
			_, werr := n.VerifiedLatest()
			if werr == nil || werr.Code != wire.ChainMismatch {
				t.Fatalf("got %v, want chain_mismatch", werr)
			}
		})
	}
}

func TestSignatureHappyVerifies(t *testing.T) {
	m := &mockServer{
		info:      validInfo(),
		roundBody: map[uint64]string{katRound: roundJSON(katRound, katSig1000000)},
	}
	n := testNetwork(t, m.start(t))
	sig, err := n.Signature(katRound)
	if err != nil {
		t.Fatalf("Signature error: %v", err)
	}
	want, _ := hex.DecodeString(katSig1000000)
	if string(sig) != string(want) {
		t.Fatalf("signature bytes mismatch")
	}
}

func TestSignatureForgedRejected(t *testing.T) {
	// Correct round number but a signature for a different round: the HTTP-layer
	// BLS verification must reject it (auth_failed), not return it.
	m := &mockServer{
		info:      validInfo(),
		roundBody: map[uint64]string{katRound: roundJSON(katRound, katSig1000001)},
	}
	n := testNetwork(t, m.start(t))
	_, err := n.Signature(katRound)
	we, ok := err.(*wire.Error)
	if !ok || we.Code != wire.AuthFailed {
		t.Fatalf("got %v, want auth_failed", err)
	}
}

func TestSignatureNotReadyStatuses(t *testing.T) {
	for _, status := range []int{http.StatusTooEarly, http.StatusNotFound} {
		t.Run(fmt.Sprintf("http-%d", status), func(t *testing.T) {
			m := &mockServer{
				info:        validInfo(),
				roundStatus: map[uint64]int{katRound: status},
			}
			n := testNetwork(t, m.start(t))
			_, err := n.Signature(katRound)
			we, ok := err.(*wire.Error)
			if !ok || we.Code != wire.RoundNotReady {
				t.Fatalf("got %v, want round_not_ready", err)
			}
		})
	}
}

func TestInfoSizeCapRejected(t *testing.T) {
	huge := strings.Repeat("x", int(maxHTTPBody)+10)
	m := &mockServer{info: huge, latest: 1}
	n := testNetwork(t, m.start(t))
	_, werr := n.VerifiedLatest()
	if werr == nil || werr.Code != wire.ParseError {
		t.Fatalf("got %v, want parse_error (size cap)", werr)
	}
}

func TestExpectedRoundMath(t *testing.T) {
	// Round 1 is published at genesis; round N at genesis+(N-1)*period.
	genesis := time.Unix(int64(constants.DRAND_GENESIS_UNIX), 0)
	if got := ExpectedRound(genesis); got != 1 {
		t.Fatalf("at genesis: got %d, want 1", got)
	}
	at := genesis.Add(time.Duration(constants.DRAND_PERIOD_SECONDS*1000) * time.Second)
	if got := ExpectedRound(at); got != 1001 {
		t.Fatalf("at genesis+1000 periods: got %d, want 1001", got)
	}
}
