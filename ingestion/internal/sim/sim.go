// Package sim is a synthetic vehicle for offline acceptance tests. It
// speaks the official receiver's wire protocol using the upstream encoder
// (messages/tesla.FlatbuffersStreamToBytes) and decoder
// (messages.StreamAckMessageFromBytes); nothing here invents a protocol.
//
// Test only: certificates are generated in memory and every VIN is fake.
package sim

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"time"

	"github.com/gorilla/websocket"
	"github.com/teslamotors/fleet-telemetry/messages"
	"github.com/teslamotors/fleet-telemetry/messages/tesla"
	"github.com/teslamotors/fleet-telemetry/protos"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// CA is an in-memory certificate authority.
type CA struct {
	Cert *x509.Certificate
	Key  *ecdsa.PrivateKey
	PEM  []byte
}

// NewCA creates a CA. Vehicle CAs must use an issuer common name the
// receiver maps to vehicle_device ("TeslaMotors" in tests); a rogue CA with
// the same name but a different key must still be refused.
func NewCA(commonName string) (*CA, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	tpl := &x509.Certificate{
		SerialNumber:          serial(),
		Subject:               pkix.Name{CommonName: commonName},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	return &CA{Cert: cert, Key: key, PEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})}, nil
}

// Leaf is a key pair signed by a CA, with PEM encodings for files.
type Leaf struct {
	TLS     tls.Certificate
	CertPEM []byte
	KeyPEM  []byte
}

// IssueClient issues a vehicle client certificate whose CN is the VIN.
func (ca *CA) IssueClient(vin string) (*Leaf, error) {
	return ca.issue(pkix.Name{CommonName: vin}, x509.ExtKeyUsageClientAuth, nil, nil)
}

// IssueServer issues a receiver certificate for the given names.
func (ca *CA) IssueServer(dns []string, ips []net.IP) (*Leaf, error) {
	return ca.issue(pkix.Name{CommonName: "volta-telemetry-test"}, x509.ExtKeyUsageServerAuth, dns, ips)
}

func (ca *CA) issue(subject pkix.Name, usage x509.ExtKeyUsage, dns []string, ips []net.IP) (*Leaf, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	tpl := &x509.Certificate{
		SerialNumber: serial(),
		Subject:      subject,
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{usage},
		DNSNames:     dns,
		IPAddresses:  ips,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, ca.Cert, &key.PublicKey, ca.Key)
	if err != nil {
		return nil, err
	}
	kb, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb})
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, err
	}
	return &Leaf{TLS: pair, CertPEM: certPEM, KeyPEM: keyPEM}, nil
}

func serial() *big.Int {
	n, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 62))
	return n
}

// Datum helpers.

// Num is a double datum.
func Num(f protos.Field, v float64) *protos.Datum {
	return &protos.Datum{Key: f, Value: &protos.Value{Value: &protos.Value_DoubleValue{DoubleValue: v}}}
}

// Loc is a location datum.
func Loc(lat, lon float64) *protos.Datum {
	return &protos.Datum{Key: protos.Field_Location, Value: &protos.Value{Value: &protos.Value_LocationValue{LocationValue: &protos.LocationValue{Latitude: lat, Longitude: lon}}}}
}

// Bool is a boolean datum. For a numeric field it models a wrong-typed
// datum.
func Bool(f protos.Field, v bool) *protos.Datum {
	return &protos.Datum{Key: f, Value: &protos.Value{Value: &protos.Value_BooleanValue{BooleanValue: v}}}
}

// Gear is a shift-state datum.
func Gear(s protos.ShiftState) *protos.Datum {
	return &protos.Datum{Key: protos.Field_Gear, Value: &protos.Value{Value: &protos.Value_ShiftStateValue{ShiftStateValue: s}}}
}

// ChargeState is a detailed charge state datum.
func ChargeState(s protos.DetailedChargeStateValue) *protos.Datum {
	return &protos.Datum{Key: protos.Field_DetailedChargeState, Value: &protos.Value{Value: &protos.Value_DetailedChargeStateValue{DetailedChargeStateValue: s}}}
}

// Invalid is an explicitly invalid datum.
func Invalid(f protos.Field) *protos.Datum {
	return &protos.Datum{Key: f, Value: &protos.Value{Value: &protos.Value_Invalid{Invalid: true}}}
}

// Payload encodes a V payload.
func Payload(vin string, created time.Time, resend bool, data ...*protos.Datum) []byte {
	b, err := proto.Marshal(&protos.Payload{Vin: vin, CreatedAt: timestamppb.New(created), IsResend: resend, Data: data})
	if err != nil {
		panic(err)
	}
	return b
}

// Frame wraps a payload in the upstream flatbuffers stream envelope.
// senderVIN is normally the certificate VIN; a different value models a
// sender-ID spoof.
func Frame(senderVIN, txid string, payload []byte, created time.Time) []byte {
	return FrameTopic("V", senderVIN, txid, payload, created)
}

// FrameTopic is Frame for another topic. The receiver checks the sender ID
// only for topics without a dispatch rule, so a mismatched sender on such
// a topic reaches its VIN-bearing error log lines.
func FrameTopic(topic, senderVIN, txid string, payload []byte, created time.Time) []byte {
	return tesla.FlatbuffersStreamToBytes(
		[]byte("vehicle_device."+senderVIN), []byte(topic), []byte(txid), payload,
		uint32(created.Unix()), []byte(txid), []byte("vehicle_device"), []byte(senderVIN),
		uint64(time.Now().UnixMilli()))
}

// Client is a connected synthetic vehicle. A background reader collects
// acks: gorilla/websocket connections are unusable after a read deadline
// expires, so waits must not use read deadlines.
type Client struct {
	Conn *websocket.Conn
	acks chan string
	done chan struct{}
	err  error
}

// Dial connects to the receiver. cert may be nil to model a vehicle that
// presents no client certificate.
func Dial(addr string, serverCA []byte, cert *tls.Certificate, clientVersion string) (*Client, *http.Response, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(serverCA) {
		return nil, nil, errors.New("server CA is not PEM")
	}
	cfg := &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12, ServerName: "localhost"}
	if cert != nil {
		cfg.Certificates = []tls.Certificate{*cert}
	}
	d := websocket.Dialer{HandshakeTimeout: 10 * time.Second, TLSClientConfig: cfg}
	h := http.Header{}
	h.Set("X-Network-Interface", "wifi")
	h.Set("Version", clientVersion)
	u := url.URL{Scheme: "wss", Host: addr, Path: "/"}
	c, resp, err := d.Dial(u.String(), h)
	if err != nil {
		return nil, resp, err
	}
	cl := &Client{Conn: c, acks: make(chan string, 8192), done: make(chan struct{})}
	go cl.read()
	return cl, resp, nil
}

func (c *Client) read() {
	defer close(c.done)
	for {
		_, b, err := c.Conn.ReadMessage()
		if err != nil {
			c.err = err
			return
		}
		ack, err := messages.StreamAckMessageFromBytes(b)
		if err != nil {
			continue // not an ack (e.g. an error response)
		}
		c.acks <- string(ack.TXID)
	}
}

// Send writes one binary frame.
func (c *Client) Send(frame []byte) error {
	return c.Conn.WriteMessage(websocket.BinaryMessage, frame)
}

// ErrNoAck is returned when no ack arrives before the deadline.
var ErrNoAck = errors.New("no ack before deadline")

// ReadAck waits for one stream ack and returns its txid.
func (c *Client) ReadAck(timeout time.Duration) (string, error) {
	t := time.NewTimer(timeout)
	defer t.Stop()
	select {
	case id := <-c.acks:
		return id, nil
	case <-c.done:
		select {
		case id := <-c.acks:
			return id, nil
		default:
			return "", c.err
		}
	case <-t.C:
		return "", ErrNoAck
	}
}

// Close closes the socket.
func (c *Client) Close() error { return c.Conn.Close() }
