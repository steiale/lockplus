package ovpn

// One-off vector exporter for the native LPParsing port (DESIGN §15.1 "The Go test vectors are exported as JSON
// fixtures by a one-off Go test helper ... so both implementations run the same vectors").
//
// This file is NOT part of the Go tree: native/Tools/fuzz/govectors/export.sh injects it into package ovpn with
// `go test -overlay`, so it can call the unexported tokenizer (parseLine, parseConfig) and ValidateOVPN without
// touching internal/. It writes:
//   - $LP_VECTORS_SWIFT: GoVectors.generated.swift for Tests/LPParsingTests (base64 JSON, decoded by the tests)
//   - $LP_VECTORS_CORPUS: one seed file per vector for the fuzz targets
//
// Inputs are copied verbatim from validate_test.go (TestValidateOVPNRejects/Accepts, TestParseLine,
// TestDifferentialAgainstOpenVPN), ovpn27_test.go and the S13 corpus (native/spike/s13-s8/host/corpus.py
// crafted()), plus boundary cases for the 256-byte line, 256-byte parameter and 16-parameter limits.
// No real profile is ever read.

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"unicode/utf8"
)

type lpDirective struct {
	N string        `json:"n"`
	A []string      `json:"a"`
	L int           `json:"l"`
	I bool          `json:"i"`
	B string        `json:"b"`
	C []lpDirective `json:"c"`
}

type lpConfigVector struct {
	Name     string        `json:"name"`
	Input    string        `json:"input"` // base64
	ParseErr *string       `json:"parseErr"`
	Ds       []lpDirective `json:"ds"`
	Validate *string       `json:"validate"` // nil = accepted
}

type lpLineVector struct {
	Input  string   `json:"input"` // base64
	Tokens []string `json:"tokens"`
	Err    *string  `json:"err"`
}

type lpVectors struct {
	Lines   []lpLineVector   `json:"lines"`
	Configs []lpConfigVector `json:"configs"`
}

func lpConv(ds []directive) []lpDirective {
	out := []lpDirective{}
	for _, d := range ds {
		a := d.Args
		if a == nil {
			a = []string{}
		}
		out = append(out, lpDirective{N: d.Name, A: a, L: d.Line, I: d.Inline, B: d.Body, C: lpConv(d.Children)})
	}
	return out
}

func lpStr(err error) *string {
	if err == nil {
		return nil
	}
	s := err.Error()
	return &s
}

func lpLineInputs() []string {
	in := []string{
		"remote a 1\n", "  \"up\" /x\n", "'a b' c\n", "'a\\b'\n", "\"a\\\"b\"\n", "a\\ b\n", "\\ up\n", "\\up\n",
		"# x\n", "; x\n", "\\# x\n", "a #b\n", "a#b\n", "\"a\"b\n", "\"\"\n", "\"abc\n", "'abc\n",
		strings.Repeat("a ", 20),
		// extras: escapes, whitespace classes, quote adjacency, parameter length
		"a\\\\b\n", "\"a\\\\b\"\n", "\"a\\ b\"\n", "\"a\\tb\"\n", "a\tb\vc\fd\re\n", "'a\"b'\n", "\"a'b\"\n",
		"a\"b\"c\n", "a'b'c\n", "'a'b\n", "''\n", "x ''\n", "\\\"x\n", "\\'x\n", "a\\\n", "\"a\\\n",
		"tail-backslash\\", "", " ", "\t;x\n", "x ;y\n", "x #y\n", "x;y\n",
		strings.Repeat("p", 256) + "\n", strings.Repeat("p", 257) + "\n",
		"a " + strings.Repeat("q", 255) + "\n", "a \"" + strings.Repeat("q", 256) + "\"\n",
		"a \"" + strings.Repeat("q", 257) + "\"\n", strings.Repeat("a ", 16) + "\n", strings.Repeat("a ", 17) + "\"unterminated\n",
		strings.Repeat("a ", 16) + "\"unterminated\n", strings.Repeat("a ", 15) + "\"x\n",
		"r\xc3\xa9mote h\n", "\xef\xbb\xbfclient\n",
	}
	return in
}

func lpConfigInputs() map[string]string {
	long := strings.Repeat("A", 255)
	pem := "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
	m := map[string]string{}
	// TestValidateOVPNRejects (bodies; prefixed with vbase)
	rejects := map[string]string{
		"log": "log /Library/x\n", "log-append": "log-append /Library/x\n", "status": "status /Library/x 1\n",
		"status-version": "status-version 2\n", "writepid": "writepid /Library/x\n",
		"tls-export-cert": "tls-export-cert /Library/x\n", "genkey": "genkey secret /Library/x\n",
		"config": "config /Library/x.ovpn\n", "cd": "cd /\n", "chroot": "chroot /var/empty\n", "tmp-dir": "tmp-dir /Library\n",
		"setenv opt user": "setenv opt user nobody\n", "user in connection": "<connection>\nremote h 1\ngroup nobody\n</connection>\n",
		"lport privileged": "lport 53\n", "lport service": "lport domain\n", "local privileged": "local 0.0.0.0 80\n",
		"setenv opt lport": "setenv opt lport 22\n", "port with bind": "port 53\nbind\n", "port with local": "port 53\nlocal 10.0.0.1\n",
		"daemon": "daemon\n", "inetd": "inetd\n", "management": "management 127.0.0.1 7505\n", "management-hold": "management-hold\n",
		"management-client": "management-client\n", "auth-user-pass file": "auth-user-pass /etc/master.passwd\n",
		"auth-user-pass uonly": "auth-user-pass username-only\n", "askpass": "askpass /etc/x\n", "ca path": "ca /etc/x\n",
		"cert path": "cert /etc/x\n", "key path": "key /etc/x\n", "pkcs12 path": "pkcs12 /etc/x\n", "tls-auth path": "tls-auth /etc/x 1\n",
		"tls-crypt path": "tls-crypt /etc/x\n", "tls-crypt-v2 path": "tls-crypt-v2 /etc/x\n", "crl-verify path": "crl-verify /etc/x\n",
		"crl-verify dir": "crl-verify /etc dir\n", "dh path": "dh /etc/x\n", "extra-certs path": "extra-certs /etc/x\n",
		"secret path": "secret /etc/x\n", "secret inline": "<secret>\nx\n</secret>\n", "proxy-user-pass path": "http-proxy-user-pass /etc/x\n",
		"http-proxy authfile": "http-proxy p.example 8080 /etc/x basic\n", "socks-proxy authfile": "socks-proxy p.example 1080 /etc/x\n",
		"up": "up /x\n", "down": "down /x\n", "route-up": "route-up /x\n", "route-pre-down": "route-pre-down /x\n",
		"tls-verify": "tls-verify /x\n", "ipchange": "ipchange /x\n", "plugin": "plugin /x.so\n", "iproute": "iproute /x\n",
		"engine": "engine dynamic\n", "providers module": "providers /x.so\n", "providers fips": "providers legacy fips\n",
		"pkcs11-providers": "pkcs11-providers /x.so\n", "dns-updown force": "dns-updown force\n", "dns-updown path": "dns-updown /x\n",
		"dev tap": "dev tap\n", "dev path": "dev ../../x\n", "dev-type tap": "dev-type tap\n", "dev-node": "dev-node /dev/x\n",
		"inline up": "<up>\n/x\n</up>\n", "inline log": "<log>\nx\n</log>\n", "inline config": "<config>\nx\n</config>\n",
		"unknown": "foo-bar 1\n", "case variant": "UP /x\n", "setenv PATH": "setenv PATH /x\n",
		"setenv DYLD": "setenv DYLD_INSERT_LIBRARIES /x.dylib\n", "setenv GENERIC": "setenv GENERIC_CONFIG 1\n",
		"setenv opt up": "setenv opt up /x\n", "setenv opt log": "setenv opt log /x\n", "setenv opt quoted": "setenv opt \"up\" /x\n",
		"setenv opt nested": "setenv opt setenv opt up /x\n", "setenv opt empty": "setenv opt\n", "setenv opt --up": "setenv opt --up /x\n",
		"setenv opt ca path": "setenv opt ca /etc/x\n", "setenv-safe badname": "setenv-safe A=B x\n",
		"double quoted": "\"up\" /x\n", "single quoted": "'up' /x\n", "escaped space": "\\ up /x\n", "leading dashes": "--up /x\n",
		"quoted dashes": "\"--up\" /x\n", "dashes log": "--log /x\n", "bad backslash": "\\up /x\n", "tab separated": "up\t/x\n",
		"vtab prefix": "\vup /x\n", "crlf": "up /x\r\n", "bom": "\xEF\xBB\xBFup /x\n", "unclosed quote": "remote \"x\n",
		"unclosed squote": "remote 'x\n", "NUL byte": "verb 3\x00\nup /x\n", "line too long": "# " + strings.Repeat("x", 300) + "\n",
		"param too long": "remote " + strings.Repeat("x", 240) + "\"" + strings.Repeat("y", 20) + "\"\n",
		"close tag suffix": "<ca>\nx\n</ca>junk\nup /x\n", "close tag space": "<ca>\nx\n</ca> trailing\nlog /x\n",
		"close tag indented": "<ca>\nx\n   </ca>\nstatus /x\n", "close tag chunked": "<ca>\n" + long + "</ca>\nup /x\n",
		"chunk remainder line": "<ca>\n" + long + "</ca>" + strings.Repeat("B", 250) + "up /x\n",
		"opener with comment": "<ca> # x\nx\n</ca>\nup /x\n", "quoted opener": "\"<ca>\"\nx\n</ca>\nup /x\n",
		"dashed opener": "--<ca>\nx\n</ca>\nup /x\n", "missing end tag": "<ca>\nx\n",
		"inline in conn hide": "<connection>\nremote h 1\n<tls-auth>\nx\n</tls-auth>junk\nup /x\n</connection>\n",
		"conn up": "<connection>\nremote h 1194\nup /x\n</connection>\n", "conn close suffix": "<connection>\nremote h 1194\n</connection>x\nup /x\n",
		"conn nested": "<connection>\nremote h 1\n<connection>\nremote h 2\n</connection>\n</connection>\n",
		"conn ca path": "<connection>\nremote h 1\nca /etc/x\n</connection>\n",
		"conn long line": "<connection>\nremote h 1\n# " + strings.Repeat("x", 300) + "\n</connection>\n",
	}
	for k, v := range rejects {
		m["reject/"+k] = vbase + v
	}
	m["reject/no client"] = "remote h 1\n"
	m["reject/no remote"] = "client\n"
	m["reject/server"] = "server 10.8.0.0 255.255.255.0\nclient\nremote h 1\n"
	m["reject/log names line"] = vbase + "verb 3\n\"log\" /secret/path\n"
	// TestValidateOVPNAccepts
	m["accept/minimal"] = vbase
	m["accept/provider"] = `client
dev tun
proto udp
remote vpn.example.com 1194
remote vpn2.example.com 443 tcp
remote-random
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name server.example.com name
auth SHA512
cipher AES-256-CBC
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
data-ciphers-fallback AES-256-CBC
tls-version-min 1.2
tls-cipher TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384
key-direction 1
comp-lzo no
allow-compression no
verb 3
mute 20
mute-replay-warnings
auth-user-pass
auth-nocache
auth-retry nointeract
static-challenge "Enter OTP" 1
push-peer-info
pull-filter ignore "route-ipv6"
route 10.0.0.0 255.0.0.0 vpn_gateway
route-ipv6 fd00::/8
redirect-gateway def1 bypass-dhcp
block-ipv6
dhcp-option DNS 10.8.0.1
dns server 0 address 10.8.0.1
dns-updown disable
tun-mtu 1500
mssfix 1450
keepalive 10 60
ping-timer-rem
connect-retry 2 30
connect-retry-max 5
connect-timeout 10
server-poll-timeout 4
hand-window 60
reneg-sec 0
float
explicit-exit-notify 2
sndbuf 393216
rcvbuf 393216
http-proxy proxy.example 8080 auto
socks-proxy 127.0.0.1 1080
script-security 2
setenv opt block-outside-dns
ignore-unknown-option block-outside-dns
setenv FORWARD_COMPATIBLE 1
setenv UV_ID abc
setenv-safe FOO bar
# comment
; comment
<ca>
` + pem + `</ca>
<cert>
` + pem + `</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIIB
-----END PRIVATE KEY-----
</key>
<tls-auth>
-----BEGIN OpenVPN Static key V1-----
abcd
-----END OpenVPN Static key V1-----
</tls-auth>
`
	m["accept/connection blocks + inline creds"] = `client
dev tun
<connection>
remote a.example 1194 udp
connect-timeout 5
</connection>
<connection>
remote b.example 443
proto tcp-client
http-proxy p.example 3128
</connection>
<auth-user-pass>
user
pass
</auth-user-pass>
<tls-crypt>
x
</tls-crypt>
<http-proxy-user-pass>
u
p
</http-proxy-user-pass>
peer-fingerprint AB:CD
`
	m["accept/double dash + quotes + crlf"] = "--client\r\n\"remote\" 'vpn.example.com' 1194\r\ndev utun\r\n"
	m["accept/bom"] = "\xEF\xBB\xBF" + vbase
	m["accept/long inline line"] = vbase + "<ca>\n" + strings.Repeat("A", 600) + "\n</ca>\n"
	m["accept/dev-type tun"] = vbase + "dev tun0\ndev-type tun\n"
	m["accept/linux user/group"] = vbase + "user nobody\ngroup nogroup\n"
	m["accept/providers"] = vbase + "providers legacy default\n"
	m["accept/remote port below 1024"] = vbase + "port 443\n"
	m["accept/unprivileged local ports"] = vbase + "lport 0\nlport 50000\nlocal 10.0.0.1 50000\nbind\nport 1194\n"
	// TestDifferentialAgainstOpenVPN probe layouts (vbase + body)
	const probe = "lockplus-probe"
	probes := map[string]string{
		"plain": probe + " x\n", "double quoted": "\"" + probe + "\" x\n", "single quoted": "'" + probe + "'\n",
		"escaped space": "\\ " + probe + "\n", "double dash": "--" + probe + "\n", "crlf": probe + "\r\n", "vtab": "\v" + probe + "\n",
		"comment hash": "# " + probe + "\n", "comment semicolon": "; " + probe + "\n", "escaped hash": "\\# " + probe + "\n",
		"bad backslash": "\\" + probe + "\n", "unclosed quote": "\"" + probe + "\n", "close tag suffix": "<ca>\nx\n</ca>junk\n" + probe + "\n",
		"close tag indented": "<ca>\nx\n \t</ca>\n" + probe + "\n", "inside inline": "<ca>\n" + probe + "\n</ca>\n",
		"opener with comment": "<ca> # c\n" + probe + "\n</ca>\n", "quoted opener": "\"<ca>\"\n" + probe + "\n</ca>\n",
		"dashed opener": "--<ca>\n" + probe + "\n</ca>\n", "close tag chunked": "<ca>\n" + long + "</ca>\n" + probe + "\n",
		"chunk remainder": "<ca>\n" + long + "</ca>" + strings.Repeat("B", 250) + probe + "\n",
		"long inline no close": "<ca>\n" + strings.Repeat("A", 600) + "\n</ca>\n" + probe + "\n", "setenv opt": "setenv opt " + probe + "\n",
		"conn inside": "<connection>\nremote 127.0.0.1 1\n" + probe + "\n</connection>\n",
		"conn close suffix": "<connection>\nremote 127.0.0.1 1\n</connection>x\n" + probe + "\n",
		"conn inline prefix": "<connection>\nremote 127.0.0.1 1\n<tls-auth>\nx\n</tls-auth>junk\n" + probe + "\n</connection>\n",
		"conn inline hides": "<connection>\nremote 127.0.0.1 1\n<tls-auth>\n" + probe + "\n</tls-auth>\n</connection>\n",
		"conn closes in inline": "<connection>\nremote 127.0.0.1 1\n<tls-auth>\n</connection>\n" + probe + "\n</tls-auth>\n</connection>\n",
		"too long top line": "# " + strings.Repeat("x", 300) + probe + "\n", "none": "verb 3\n",
	}
	for k, v := range probes {
		m["probe/"+k] = vbase + v
	}
	m["probe/bom first line"] = "\xEF\xBB\xBF" + probe + "\n" + vbase
	// ovpn27_test.go profile bodies
	for i, b := range []string{"", "dhcp-option DNS 9.9.9.9\n", "dns server 1 address 9.9.9.9\n",
		"dns server 0 address 9.9.9.9\ndns server 5 address 8.8.8.8\n", "pull-filter ignore \"dhcp-option\"\ndhcp-option DNS 9.9.9.9\n",
		"pull-filter ignore \"dhcp-option DNS\"\n", "pull-filter accept \"dhcp-option DNS 10.\"\npull-filter ignore \"dhcp-option\"\n",
		"pull-filter ignore dns\n", "pull-filter reject \"dhcp-option DNS 6.6.6.6\"\n", "dns-updown disable\n", "dns-updown force\n",
		"dns-updown /Users/x/evil.sh\n", "--dns-updown /bin/sh\n", "dns-updown\n", "cipher AES-256-CBC\n",
		"cipher AES-256-CBC\ndata-ciphers AES-256-GCM\n", "cipher AES-256-GCM\n", "cipher BF-CBC\n", "cipher none\n", "cipher AES;rm\n",
		"<key>\ncipher AES-128-CBC\n</key>\n", "--cipher AES-128-CBC\n", "verb 1\n", "verb 9\n", "setenv opt verb 11\n",
		"user nobody\r\n\"group\" nogroup\nverb 3\n<ca>\nuser x\n</ca>\n", "cipher AES-256-CBC\nverb 7\n",
		"user nobody\ngroup nobody\nproviders legacy default\ncipher AES-256-CBC\n"} {
		m["ovpn27/"+strings.Repeat("0", 2-len(itoa(i)))+itoa(i)] = vbase + b
	}
	m["ovpn27/persist-remote multi"] = "client\nremote a.example 1194\nremote b.example 1194\npersist-remote-ip\nsetenv opt persist-remote-ip\nverb 3\n"
	m["ovpn27/persist-remote single"] = "client\nremote a.example 1194\npersist-remote-ip\n"
	m["helpers/keepalive after prefix close"] = vbase + "<ca>\nx\n</ca>junk\nkeepalive 10 60\n"
	m["helpers/quoted mssfix"] = vbase + "\"mssfix\" 1400\n"
	m["helpers/inside inline"] = vbase + "<ca>\nmssfix 1400\n</ca>\n"
	m["helpers/setenv opt keepalive"] = vbase + "setenv opt keepalive 10 60\n"
	m["helpers/connection quoted remote"] = "<connection>\n'remote' h.example 443\n</connection>\nauth-user-pass\n"
	m["helpers/inline creds"] = "<auth-user-pass>\nu\np\n</auth-user-pass>\n"
	// S13 corpus crafted() layouts (placeholder PKI; RAW, not normalized)
	base := func(extra string) string {
		return "client\ndev tun\nproto udp\nremote vpn.example.invalid 1194\n" + extra + "<ca>\n" + pem + "</ca>\n<cert>\n" + pem + "</cert>\n<key>\n-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n</key>\n"
	}
	crafted := map[string]string{
		"removed: no-iv": "no-iv\n", "server-only: push": "push \"route 10.0.0.0 255.0.0.0\"\n", "server-only: auth-gen-token": "auth-gen-token 3600\n",
		"standalone: genkey": "genkey\n", "push-only: ifconfig": "ifconfig 10.8.0.2 255.255.255.0\n", "push-only: auth-token": "auth-token abc\n",
		"management-foo": "management-foo\n", "incompatible: secret": "secret /x\n", "incompatible: fragment": "fragment 1300\n",
		"incompatible: mode server": "mode server\n", "incompatible: key-method 1": "key-method 1\n",
		"meta: <pkcs12>": "<pkcs12>\nMIIBAAAA\n</pkcs12>\n", "meta: <foo>": "<foo>\nbar\n</foo>\n", "meta: <dh>": "<dh>\nx\n</dh>\n",
		"dup: cipher x2": "cipher AES-256-GCM\ncipher AES-128-GCM\n", "dup: auth x2": "auth SHA256\nauth SHA512\n",
		"dup: tls-version-min x2": "tls-version-min 1.2\ntls-version-min 1.3\n", "dup: remote-cert-tls x2": "remote-cert-tls server\nremote-cert-tls server\n",
		"dup: verb x2": "verb 3\nverb 4\n", "dup: tun-mtu x2": "tun-mtu 1500\ntun-mtu 1400\n", "dup: reneg-sec x2": "reneg-sec 0\nreneg-sec 3600\n",
		"dup: route-metric x2": "route-metric 1\nroute-metric 2\n", "dup: inactive x2": "inactive 10\ninactive 20\n", "dup: persist-tun x2": "persist-tun\npersist-tun\n",
		"setenv opt socks-proxy": "setenv opt socks-proxy 127.0.0.1 1080\n", "setenv opt management": "setenv opt management 127.0.0.1 7505\n",
		"setenv opt route-gateway": "setenv opt route-gateway 10.0.0.1\n", "setenv opt push": "setenv opt push \"route 1.2.3.4\"\n",
		"setenv opt fragment": "setenv opt fragment 1300\n", "setenv opt foo-bar": "setenv opt foo-bar\n",
		"ignore-unknown-option foo-bar + foo-bar": "ignore-unknown-option foo-bar\nfoo-bar\n",
		"ignore-unknown-option ping-timer-rem + it": "ignore-unknown-option ping-timer-rem\nping-timer-rem\n",
		"static-challenge concat": "auth-user-pass\nstatic-challenge \"Enter OTP\" 1 concat\n",
		"connection block with extra option": "<connection>\nremote a.example 1194 udp\nconnect-timeout 5\nfoo-bar\n</connection>\n",
		"route with explicit gateway": "route 10.0.0.0 255.0.0.0 10.8.0.5\n", "http-proxy + udp remote": "http-proxy p.example 8080\n",
		"cipher none": "cipher none\n", "compress lz4 + comp-lzo": "compress lz4\ncomp-lzo yes\n",
		"setenv IV_SSO": "setenv IV_SSO openurl\n", "ping + keepalive": "keepalive 10 60\nping 10\nping-restart 60\n",
		"tls-client alone": "tls-client\n",
	}
	for k, v := range crafted {
		m["crafted/"+k] = base(v)
	}
	m["crafted/no client"] = strings.Replace(base(""), "client\n", "", 1)
	m["crafted/dev tap"] = strings.Replace(base(""), "dev tun\n", "dev tap\n", 1)
	m["crafted/dev utun3"] = strings.Replace(base(""), "dev tun\n", "dev utun3\n", 1)
	m["crafted/tls-client+pull"] = strings.Replace(base("tls-client\npull\n"), "client\n", "", 1)
	// Boundaries: OPTION_LINE_SIZE (fgets 257), OPTION_PARM_SIZE, MAX_PARMS, BOM placement, EOF without newline,
	// buf_parse inside <connection>, NUL position.
	for _, n := range []int{253, 254, 255, 256, 257} {
		m["bound/comment line "+itoa(n)] = vbase + "#" + strings.Repeat("c", n-1) + "\n"
		m["bound/comment line no-nl "+itoa(n)] = vbase + "#" + strings.Repeat("c", n-1)
		m["bound/conn line "+itoa(n)] = vbase + "<connection>\nremote h 1\n#" + strings.Repeat("c", n-1) + "\n</connection>\n"
		m["bound/inline line "+itoa(n)] = vbase + "<ca>\n" + strings.Repeat("A", n) + "\n</ca>\nverb 3\n"
	}
	for _, n := range []int{255, 256, 257} {
		m["bound/param "+itoa(n)] = vbase + "verify-x509-name " + strings.Repeat("p", n) + "\n"
	}
	m["bound/16 params"] = vbase + "remote" + strings.Repeat(" a", 15) + "\n"
	m["bound/17 params"] = vbase + "remote" + strings.Repeat(" a", 16) + "\n"
	m["bound/20 params + bad tail"] = vbase + "remote" + strings.Repeat(" a", 19) + " \"unterminated\n"
	m["bound/bom second line"] = vbase + "\xEF\xBB\xBFverb 3\n"
	m["bound/bom only"] = "\xEF\xBB\xBF"
	m["bound/double bom"] = "\xEF\xBB\xBF\xEF\xBB\xBF" + vbase
	m["bound/empty"] = ""
	m["bound/no trailing newline"] = "client\nremote h 1"
	m["bound/inline eof no newline"] = vbase + "<ca>\nx\n</ca>"
	m["bound/inline empty"] = vbase + "<ca>\n</ca>\n"
	m["bound/inline tag only <>"] = vbase + "<>\nx\n</>\n"
	m["bound/inline crlf"] = vbase + "<ca>\r\nx\r\n</ca>\r\n"
	m["bound/inline indented open"] = vbase + "   <ca>\nx\n</ca>\n"
	m["bound/close tag tabbed"] = vbase + "<ca>\nx\n\t\v</ca>\n"
	m["bound/close other tag"] = vbase + "<ca>\nx\n</cert>\n</ca>\n"
	m["bound/conn crlf"] = vbase + "<connection>\r\nremote h 1\r\n</connection>\r\n"
	m["bound/conn no trailing nl before close"] = vbase + "<connection>\nremote h 1</connection>\n"
	m["bound/conn inline block"] = vbase + "<connection>\nremote h 1\n<tls-auth>\nk\n</tls-auth>\n</connection>\n"
	m["bound/conn inline missing end"] = vbase + "<connection>\nremote h 1\n<tls-auth>\nk\n</connection>\n"
	m["bound/conn empty"] = vbase + "<connection>\n</connection>\n"
	m["bound/conn dashes"] = vbase + "<connection>\n--remote h 1\n'proto' tcp\n</connection>\n"
	m["bound/NUL at start"] = "\x00client\n"
	m["bound/NUL in inline"] = vbase + "<ca>\n\x00\n</ca>\n"
	m["bound/only comments"] = "# a\n; b\n\n   \n"
	m["bound/double dash short"] = vbase + "--\n"
	m["bound/double dash x"] = vbase + "--x\n"
	m["bound/triple dash"] = vbase + "---verb 3\n"
	m["bound/utf8 arg"] = vbase + "verify-x509-name \"s\xc3\xa9rver\" name\n"
	return m
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	s := ""
	for i > 0 {
		s = string(rune('0'+i%10)) + s
		i /= 10
	}
	return s
}

func TestExportLPParsingVectors(t *testing.T) {
	swiftOut, corpusOut := os.Getenv("LP_VECTORS_SWIFT"), os.Getenv("LP_VECTORS_CORPUS")
	if swiftOut == "" {
		t.Skip("LP_VECTORS_SWIFT not set")
	}
	var v lpVectors
	for _, in := range lpLineInputs() {
		toks, err := parseLine(in)
		if toks == nil && err == nil {
			toks = []string{}
		}
		v.Lines = append(v.Lines, lpLineVector{Input: base64.StdEncoding.EncodeToString([]byte(in)), Tokens: toks, Err: lpStr(err)})
	}
	inputs := lpConfigInputs()
	names := make([]string, 0, len(inputs))
	for k := range inputs {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, name := range names {
		in := inputs[name]
		if !utf8.ValidString(in) {
			t.Fatalf("%s: vectors must be valid UTF-8 (JSON round trip)", name)
		}
		ds, err := parseConfig([]byte(in))
		cv := lpConfigVector{Name: name, Input: base64.StdEncoding.EncodeToString([]byte(in)), ParseErr: lpStr(err), Validate: lpStr(ValidateOVPN([]byte(in)))}
		if err == nil {
			cv.Ds = lpConv(ds)
		}
		v.Configs = append(v.Configs, cv)
	}
	js, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	b64 := base64.StdEncoding.EncodeToString(js)
	var sb strings.Builder
	sb.WriteString("// GENERATED by native/Tools/fuzz/govectors/export.sh from the Go tokenizer (internal/ovpn/parse.go,\n")
	sb.WriteString("// allowlist.go, config.go). DO NOT EDIT. Regenerate after any change to the Go tokenizer or its tests.\n")
	sb.WriteString("// sha256(json) = " + func() string { h := sha256.Sum256(js); return hex.EncodeToString(h[:]) }() + "\n\n")
	sb.WriteString("enum GoVectors {\n    static let base64JSON: String = [\n")
	for i := 0; i < len(b64); i += 120 {
		j := i + 120
		if j > len(b64) {
			j = len(b64)
		}
		sb.WriteString("        \"" + b64[i:j] + "\",\n")
	}
	sb.WriteString("    ].joined()\n}\n")
	if err := os.WriteFile(swiftOut, []byte(sb.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	if corpusOut != "" {
		if err := os.MkdirAll(corpusOut, 0o755); err != nil {
			t.Fatal(err)
		}
		for _, name := range names {
			h := sha256.Sum256([]byte(inputs[name]))
			fn := filepath.Join(corpusOut, "go-"+hex.EncodeToString(h[:8]))
			if err := os.WriteFile(fn, []byte(inputs[name]), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	t.Logf("exported %d line vectors, %d config vectors", len(v.Lines), len(v.Configs))
}
