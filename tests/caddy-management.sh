#!/usr/bin/env bash
set -euo pipefail
export PYTHONUTF8=1
cd "$(dirname "$0")/.."
source ./install.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ROOT=$tmp DOMAIN=panel.example.com
mkdir -p "$ROOT/config" "$ROOT/state/caddy-token-change"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
declare -F caddy_action >/dev/null || fail 'Caddy management actions are missing'
caddy_require_install() { [[ $1 == read || $1 == write ]] || fail 'Missing install check mode'; }

# Removing validation or allowing a failed validation to reload must fail here.
dc() {
  printf '%s\n' "$*" >> "$ROOT/calls"
  case "$*" in
    'exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile') return "${VALIDATE_RC:-0}";;
    'exec -T caddy caddy version') printf 'v2.11.4 fixture-build\n';;
    'exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile'|'restart caddy'|'ps caddy'|'logs --tail 80 caddy') return 0;;
    *) fail "Unexpected compose mutation: $*";;
  esac
}
caddy_action status > "$tmp/status"
grep -q 'v2.11.4' "$tmp/status" || fail 'Caddy status omits installed version'
printf '%s\n' 'ps caddy' 'exec -T caddy caddy version' > "$tmp/expected"
cmp "$ROOT/calls" "$tmp/expected"
: > "$ROOT/calls"
(
  VALIDATE_RC=1
  if caddy_action reload > "$tmp/reload-failed" 2>&1; then fail 'Invalid config accepted'; fi
  [[ $(cat "$ROOT/calls") == 'exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' ]] || fail 'Reload executed after failed validation'
)
: > "$ROOT/calls"
(
  caddy_ready() { printf 'ready\n' >> "$ROOT/calls"; }
  caddy_action reload >/dev/null
)
printf '%s\n' 'exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' 'exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile' ready > "$tmp/expected"
cmp "$ROOT/calls" "$tmp/expected"
: > "$ROOT/calls"
(
  confirm() { return 1; }
  caddy_action restart >/dev/null
)
[[ ! -s $ROOT/calls ]] || fail 'Declined restart touched a service'
(
  confirm() { return 0; }
  caddy_ready() { printf 'ready\n' >> "$ROOT/calls"; }
  caddy_action restart >/dev/null
)
printf '%s\n' 'restart caddy' 'exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile' ready > "$tmp/expected"
cmp "$ROOT/calls" "$tmp/expected"

# Output and durable run_step logs must never contain any current/old/new token.
printf 'current-token.[secret]' > "$ROOT/config/cloudflare.token"
printf 'CF_API_TOKEN=current-env-token\n' > "$ROOT/config/caddy.env"
printf 'old-token-value' > "$ROOT/state/caddy-token-change/old.token"
printf 'CF_API_TOKEN=old-env-token\n' > "$ROOT/state/caddy-token-change/old.env"
printf 'candidate-token-value' > "$ROOT/state/caddy-token-change/candidate.token"
printf 'CF_API_TOKEN=candidate-env-token\n' > "$ROOT/state/caddy-token-change/candidate.env"
(
  # This simulates verbose upstream Docker/Caddy errors at the external boundary.
  # shellcheck disable=SC2329
  dc() { cat "$ROOT/config/cloudflare.token" "$ROOT/config/caddy.env" "$ROOT/state/caddy-token-change/"*; return 7; }
  (set -x; caddy_action logs) > "$tmp/log-output" 2>&1 && fail 'Failed logs reported success'
  (set -x; caddy_validate_config) > "$tmp/validate-output" 2>&1 && fail 'Failed validate reported success'
  true
)
if grep -RF -f <(printf '%s\n' 'current-token.[secret]' current-env-token old-token-value old-env-token candidate-token-value candidate-env-token) "$tmp/log-output" "$tmp/validate-output" "$ROOT/state/logs"; then fail 'Token leaked'; fi
grep -q '\[REDACTED\]' "$tmp/log-output"
grep -Rq '\[REDACTED\]' "$ROOT/state/logs"

# The submenu must dispatch every selected action and preserve a token path with spaces.
(
  SELF=$tmp/menu-child TOKEN_FILE="$tmp/token file"
  cat > "$SELF" <<'CHILD'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$(dirname "$0")/menu-calls"
CHILD
  printf '1\n2\n3\n4\n5\n6\n0\n' > "$tmp/menu-answers"
  ask() { local answer; IFS= read -r answer < "$tmp/menu-answers"; tail -n +2 "$tmp/menu-answers" > "$tmp/menu-next"; mv "$tmp/menu-next" "$tmp/menu-answers"; printf '%s' "$answer"; }
  caddy_menu > "$tmp/menu-output"
  printf '%s|--cf-token-file|%s\n' caddy-status "$TOKEN_FILE" caddy-logs "$TOKEN_FILE" caddy-reload "$TOKEN_FILE" caddy-restart "$TOKEN_FILE" caddy-certificates "$TOKEN_FILE" caddy-token "$TOKEN_FILE" > "$tmp/expected-menu"
  cmp "$tmp/menu-calls" "$tmp/expected-menu"
)

# A failed origin check must still report the edge and independent public HTTP status.
(
  # shellcheck disable=SC2329
  caddy_certificate_probe() { printf 'fixture %s\n' "$1"; [[ $1 == edge ]]; }
  curl() { printf '%s\n' "$*" > "$tmp/curl-call"; printf 503; }
  if caddy_action certificates > "$tmp/certificates"; then fail 'Failed origin probe reported success'; fi
  grep -q 'fixture origin' "$tmp/certificates"; grep -q 'fixture edge' "$tmp/certificates"
  grep -q 'HTTP 503' "$tmp/certificates"
  grep -q 'https://panel.example.com/' "$tmp/curl-call"
  if grep -Eq 'Authorization|--header|--resolve|--insecure' "$tmp/curl-call"; then fail 'Public HTTPS status bypasses trust or carries credentials'; fi
)

# Exercise the shipped Python against deterministic socket, TLS and Docker boundaries.
# Cert metadata mirrors Python getpeercert(), including a full issuer RDN sequence.
cat > "$tmp/tls-fixture.py" <<'PY'
import io, os, socket, ssl, subprocess, sys, time
from pathlib import Path
mode = os.environ['CADDY_FIXTURE']
code = sys.argv[2] if sys.argv[1] == '-c' else sys.stdin.read()
sys.argv = ['fixture'] + sys.argv[3 if sys.argv[1] == '-c' else 2:]
events = Path(os.environ['CADDY_EVENTS'])
def event(line):
    with events.open('a') as handle: handle.write(line + '\n')
cert = {'subjectAltName': (('DNS', 'panel.example.com'), ('DNS', '*.example.com')),
        'issuer': ((('countryName', 'US'),), (('organizationName', 'Fixture CA'),), (('commonName', 'Fixture Issuer'),)),
        'notBefore': 'Jan  1 00:00:00 2020 GMT',
        'notAfter': 'Jan  1 00:00:00 2000 GMT' if mode == 'expired' else 'Jan  1 00:00:00 2099 GMT'}
class Connection:
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def settimeout(self, timeout): assert 0 < timeout <= 3
    def getpeercert(self, binary_form=False): return b'fixture-der' if binary_form else cert
class Context:
    def __init__(self, verified): self.verified = verified
    def wrap_socket(self, connection, server_hostname):
        assert server_hostname == 'panel.example.com', server_hostname
        event('tls ' + ('verified' if self.verified else 'unverified') + ' ' + server_hostname)
        if self.verified and mode in ('expired', 'untrusted'):
            raise ssl.SSLCertVerificationError(1, 'fixture certificate verification failed')
        return Connection()
def connect(address, timeout):
    assert address[1] == 443 and 0 < timeout <= 10
    event('connect ' + address[0])
    if mode == 'connect-error': raise ConnectionRefusedError('fixture connection refused')
    if mode == 'dns-error': raise socket.gaierror('fixture DNS lookup failed')
    if mode == 'timeout': raise TimeoutError('fixture timed out')
    if mode == 'tls-error': raise ssl.SSLError('fixture TLS error')
    return Connection()
socket.create_connection = connect
ssl.create_default_context = lambda: Context(True)
ssl._create_unverified_context = lambda: Context(False)
ssl.DER_cert_to_PEM_cert = lambda value: 'fixture pem'
ssl._ssl._test_decode_cert = lambda path: cert
def run(command, **kwargs):
    assert command[-5:] == ['ps', '--status', 'running', '-q', 'caddy'], command
    assert command[:2] == ['docker', 'compose'], command
    assert 0 < kwargs['timeout'] <= 5
    event('running caddy')
    return subprocess.CompletedProcess(command, 0, stdout='' if mode == 'stopped' else 'fixture-caddy-id\n', stderr='')
subprocess.run = run
clock = [0.0]
time.monotonic = lambda: clock[0]
time.sleep = lambda seconds: clock.__setitem__(0, clock[0] + max(seconds, 1))
exec(compile(code, '<production-caddy-probe>', 'exec'))
PY
(
  python3() { command python3 "$tmp/tls-fixture.py" "$@"; }
  export CADDY_EVENTS=$tmp/tls-events CADDY_FIXTURE=valid
  : > "$CADDY_EVENTS"
  caddy_certificate_probe origin 127.0.0.1 "$DOMAIN" > "$tmp/origin"
  caddy_certificate_probe edge "$DOMAIN" "$DOMAIN" > "$tmp/edge"
  grep -q '源站' "$tmp/origin"; grep -q 'Cloudflare 边缘' "$tmp/edge"
  grep -q 'Fixture Issuer' "$tmp/origin"; grep -q '\*.example.com' "$tmp/origin"
  grep -q '2099' "$tmp/origin"; grep -q '2020' "$tmp/origin"
  grep -q 'connect 127.0.0.1' "$CADDY_EVENTS"; grep -q 'connect panel.example.com' "$CADDY_EVENTS"
  export CADDY_FIXTURE=expired
  if caddy_certificate_probe origin 127.0.0.1 "$DOMAIN" > "$tmp/expired"; then fail 'Expired cert reported valid'; fi
  grep -q '已过期' "$tmp/expired"; grep -q '未验证' "$tmp/expired"
  export CADDY_FIXTURE=untrusted
  if caddy_certificate_probe edge "$DOMAIN" "$DOMAIN" > "$tmp/untrusted"; then fail 'Untrusted cert reported valid'; fi
  grep -q '信任验证失败' "$tmp/untrusted"
  export CADDY_FIXTURE=connect-error
  if caddy_certificate_probe origin 127.0.0.1 "$DOMAIN" > "$tmp/connect-error"; then fail 'Failed connect reported valid'; fi
  grep -q '连接被拒绝' "$tmp/connect-error" || fail 'Connection refusal reason is missing'
  if grep -q Traceback "$tmp/connect-error"; then fail 'Verbose traceback in certificate report'; fi
  for CADDY_FIXTURE in dns-error timeout tls-error; do
    export CADDY_FIXTURE
    if caddy_certificate_probe edge "$DOMAIN" "$DOMAIN" > "$tmp/$CADDY_FIXTURE"; then fail 'Failed certificate probe reported success'; fi
  done
  grep -q 'DNS 解析失败' "$tmp/dns-error" || fail 'DNS failure reason is missing'
  grep -q '连接超时' "$tmp/timeout" || fail 'Timeout reason is missing'
  grep -q 'TLS 握手失败' "$tmp/tls-error" || fail 'TLS handshake reason is missing'
  export CADDY_FIXTURE=valid
  : > "$CADDY_EVENTS"
  caddy_ready > "$tmp/ready"
  grep -q 'running caddy' "$CADDY_EVENTS"; grep -q 'tls verified panel.example.com' "$CADDY_EVENTS"
  export CADDY_FIXTURE=untrusted
  if caddy_ready > "$tmp/not-ready" 2>&1; then fail 'Untrusted local TLS reported ready'; fi
  export CADDY_FIXTURE=stopped
  : > "$CADDY_EVENTS"
  if caddy_ready > "$tmp/stopped" 2>&1; then fail 'Stopped Caddy reported ready'; fi
  if grep -q '^tls ' "$CADDY_EVENTS"; then fail 'TLS endpoint substituted for stopped container'; fi
)
echo 'PASS: Caddy validation/reload, confirmed isolated restart, token redaction, certificate sources and bounded verified TLS readiness'
