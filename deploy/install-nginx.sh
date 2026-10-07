#!/usr/bin/env bash
set -euo pipefail
umask 077

# Co-hosting installer: the relay runs behind an nginx server that already owns
# the hostname and terminates TLS for a real site. Only /<base-path>/ is routed to
# the relay (BASE_PATH.md mode B). Caddy is not installed, /etc/nginx is never
# modified, and the front-proxy snippet is printed for the operator to merge.
# Existing TLS certificates stay under the operator's nginx configuration.

hostname=
base_path=
secret=
site_upstream=
static_routes=exact
mtproxy_workers=1
mtproxy_max_connections=4096

usage() {
	echo "usage: sudo ./deploy/install-nginx.sh --hostname example.com --site-upstream http://127.0.0.1:3000 [--base-path SLUG] [--static-routes exact|legacy] [--secret 32-or-34-hex] [--mtproxy-workers 1] [--mtproxy-max-connections 4096]" >&2
	echo "  --site-upstream must be the loopback backend the existing nginx serves at / (see BASE_PATH.md section 4)" >&2
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--hostname) hostname="${2:-}"; shift 2 ;;
		--base-path) base_path="${2:-}"; shift 2 ;;
		--secret) secret="${2:-}"; shift 2 ;;
		--site-upstream) site_upstream="${2:-}"; shift 2 ;;
		--static-routes) static_routes="${2:-}"; shift 2 ;;
		--mtproxy-workers) mtproxy_workers="${2:-}"; shift 2 ;;
		--mtproxy-max-connections) mtproxy_max_connections="${2:-}"; shift 2 ;;
		*) usage; exit 2 ;;
	esac
done

if [[ "${EUID}" -ne 0 ]]; then
	echo "run this installer as root" >&2
	exit 1
fi
if [[ "$(uname -m)" != "x86_64" ]]; then
	echo "the stock official MTProxy build requires an x86_64 server" >&2
	exit 1
fi
if ! command -v nginx >/dev/null 2>&1; then
	echo "warning: nginx was not found in PATH; install it or run this on the nginx host" >&2
fi
if systemctl is-active --quiet caddy.service 2>/dev/null; then
	echo "warning: caddy.service is active and owns 80/443; stop and disable it before" >&2
	echo "starting nginx, or the two front proxies will conflict" >&2
fi
if [[ -z "$secret" ]]; then
	read -r -s -p "WEB proxy secret (32 hex, optionally prefixed with dd): " secret
	echo
fi
# This variant co-hosts, so the relay must never take the host root. "none" is
# rejected; an existing config that serves the root is refused rather than
# silently converted into a prefix deployment.
if [[ "$base_path" == "none" ]]; then
	echo "co-hosting needs a base path; --base-path none takes over the whole hostname," >&2
	echo "which is the dedicated-host mode of deploy/install.sh" >&2
	exit 2
fi
if [[ -z "$base_path" ]]; then
	if [[ -f /etc/tproxy-server/config.json ]]; then
		# A reinstall keeps whatever prefix this host already serves. Rotating it
		# would invalidate every client link and drop live sessions.
		base_path="$(sed -n 's/.*"base_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /etc/tproxy-server/config.json | head -n1)"
	elif ! command -v base32 >/dev/null; then
		echo "base32 (coreutils) is required to generate a base path; pass --base-path explicitly" >&2
		exit 1
	else
		base_path="$(head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z')"
	fi
fi
if [[ -z "$base_path" ]]; then
	echo "co-hosting requires a non-empty base path, but the existing config serves the root" >&2
	echo "pass --base-path SLUG, or use deploy/install.sh for a dedicated relay hostname" >&2
	exit 2
fi
if ! [[ "$base_path" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]]; then
	echo "base path segments must match [A-Za-z0-9][A-Za-z0-9_-]* joined by /" >&2
	usage
	exit 1
fi
if [[ ${#base_path} -gt 128 ]]; then
	echo "base path must be at most 128 characters" >&2
	exit 1
fi
if [[ ! "$hostname" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || [[ "$hostname" != *.* ]]; then
	echo "hostname must be a lowercase ASCII DNS hostname" >&2
	exit 2
fi
if [[ ! "$secret" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]]; then
	echo "secret must be 32 lowercase hex characters, optionally prefixed with dd" >&2
	exit 2
fi
# Mode B fidelity depends on the in-prefix responses matching the site's own
# responses, so an explicit loopback website backend is required. There is no
# --site-dir here: the relay's in-process static server would answer in-prefix
# 404s with its own body and status, which is a distinguishable tell.
if [[ -z "$site_upstream" ]]; then
	echo "--site-upstream is required: point it at the loopback backend the existing" >&2
	echo "nginx serves at /, or at a loopback static mirror of the same site root" >&2
	echo "pass --site-upstream http://127.0.0.1:3000" >&2
	exit 2
fi
if [[ ! "$site_upstream" =~ ^http://(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]):[1-9][0-9]{0,4}$ ]]; then
	echo "site upstream must be http:// followed by a numeric loopback address and port" >&2
	exit 2
fi
if [[ ! "$mtproxy_workers" =~ ^[1-9][0-9]*$ ]] || ((mtproxy_workers > 256)); then
	echo "mtproxy workers must be between 1 and 256" >&2
	exit 2
fi
if [[ ! "$mtproxy_max_connections" =~ ^[1-9][0-9]*$ ]]; then
	echo "mtproxy max connections must be positive" >&2
	exit 2
fi

repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$static_routes" != exact && "$static_routes" != legacy ]]; then
	echo "--static-routes must be exact or legacy" >&2
	exit 2
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl nftables

"$repository/deploy/install-mtproxy.sh"

if ! id tproxy >/dev/null 2>&1; then
	useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
fi

go_binary=
if command -v go >/dev/null 2>&1; then
	go_minor="$(go env GOVERSION | sed -E 's/^go1\.([0-9]+).*/\1/')"
	if [[ "$go_minor" =~ ^[0-9]+$ ]] && [[ "$go_minor" -ge 20 ]]; then
		go_binary="$(command -v go)"
	fi
fi
if [[ -z "$go_binary" ]]; then
	go_version=1.26.5
	go_checksum=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053
	go_archive="$(mktemp /tmp/go-linux-amd64.XXXXXX.tar.gz)"
	go_directory="$(mktemp -d /tmp/go-linux-amd64.XXXXXX)"
	trap 'rm -f "$go_archive"; rm -rf "$go_directory"' EXIT
	curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
		--output "$go_archive" "https://go.dev/dl/go${go_version}.linux-amd64.tar.gz"
	test "$(sha256sum "$go_archive" | awk '{print $1}')" = "$go_checksum"
	tar -C "$go_directory" -xzf "$go_archive"
	if [[ -e "/opt/go${go_version}" ]]; then
		rm -rf "$go_directory/go"
	else
		mv "$go_directory/go" "/opt/go${go_version}"
	fi
	rm -f "$go_archive"
	rm -rf "$go_directory"
	trap - EXIT
	go_binary="/opt/go${go_version}/bin/go"
fi

(cd "$repository" && "$go_binary" test ./...)
(cd "$repository" && "$go_binary" build -trimpath -ldflags='-s -w' -o /usr/local/bin/tproxy-server ./cmd/tproxy-server)
chown root:root /usr/local/bin/tproxy-server
chmod 0755 /usr/local/bin/tproxy-server

install -d -o root -g tproxy -m 0750 /etc/tproxy-server
bash "$repository/deploy/ensure-token-key.sh"
cat > /etc/tproxy-server/config.json <<EOF
{
  "public_hostname": "$hostname",
  "base_path": "$base_path",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
  "public_upstream": "$site_upstream",
  "static_routes": "$static_routes",
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json"
}
EOF
cat > /etc/tproxy-server/profiles.json <<EOF
{"profiles":[{"name":"default","secret":"$secret","backend":"127.0.0.1:2398"}]}
EOF
chown root:tproxy /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json
chmod 0640 /etc/tproxy-server/config.json
chmod 0400 /etc/tproxy-server/profiles.json

backend_secret="$secret"
if [[ "$backend_secret" == dd* ]] && [[ ${#backend_secret} -eq 34 ]]; then
	backend_secret="${backend_secret:2}"
fi
# MTProxy derives the AES keys for its RPC session with a Telegram middle-end
# from its own source address (net/net-tcp-rpc-client.c passes
# nat_translate_ip(c->our_ip) and c->our_port into aes_create_keys). When the
# host is behind 1:1 NAT - EC2, GCE, a container bridge - the middle-end derives
# its half from the post-NAT public address instead, the two disagree, and every
# middle-end connection is dropped right after the handshake with "Disconnected
# from RPC Middle-End". Clients still complete the obfuscated2 handshake and are
# then answered by nobody, so the proxy looks reachable and every stream stalls.
mtproxy_nat_args=
# The address MTProxy binds its outbound middle-end sockets to.
local_address="$(ip -4 route get 149.154.175.50 2>/dev/null |
	sed -n 's/.*[[:space:]]src[[:space:]]\+\([0-9.]\+\).*/\1/p' | head -n 1)"
# The address a middle-end sees those sockets arrive from. An echo service
# measures the egress address directly, which is what MTProxy has to hash; the
# hostname's own A record is the offline fallback.
public_address=
for probe in https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
	candidate="$(curl --fail --silent --show-error --location --ipv4 --max-time 15 \
		--proto '=https' --proto-redir '=https' --tlsv1.2 "$probe" 2>/dev/null |
		tr -d '[:space:]')" || continue
	if [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		public_address="$candidate"
		break
	fi
done
if [[ -z "$public_address" ]]; then
	public_address="$(getent ahostsv4 "$hostname" 2>/dev/null | awk 'NR==1 {print $1}')"
fi
if [[ -n "$local_address" ]] && [[ -n "$public_address" ]] &&
	[[ "$local_address" != "$public_address" ]]; then
	mtproxy_nat_args="--nat-info $local_address:$public_address"
	echo "MTProxy is behind NAT ($local_address -> $public_address), using $mtproxy_nat_args"
elif [[ "$local_address" =~ ^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]] &&
	[[ -z "$mtproxy_nat_args" ]]; then
	echo "warning: $local_address is private and the public address could not be" >&2
	echo "determined; set MTPROXY_NAT_ARGS=--nat-info $local_address:<public-ip> in" >&2
	echo "/etc/mtproxy/mtproxy.env or MTProxy will accept clients and answer none" >&2
fi

cat > /etc/mtproxy/mtproxy.env <<EOF
MTPROXY_SECRET=$backend_secret
MTPROXY_WORKERS=$mtproxy_workers
MTPROXY_MAX_CONNECTIONS=$mtproxy_max_connections
MTPROXY_NAT_ARGS=$mtproxy_nat_args
EOF
chown root:mtproxy /etc/mtproxy/mtproxy.env
chmod 0640 /etc/mtproxy/mtproxy.env

install -m 0644 "$repository/deploy/tproxy-server.service" /etc/systemd/system/tproxy-server.service
install -m 0644 "$repository/deploy/mtproxy.service" /etc/systemd/system/mtproxy.service
install -m 0644 "$repository/deploy/tproxy-firewall.service" /etc/systemd/system/tproxy-firewall.service
install -m 0644 "$repository/deploy/refresh-mtproxy-config.service" /etc/systemd/system/refresh-mtproxy-config.service
install -m 0644 "$repository/deploy/refresh-mtproxy-config.timer" /etc/systemd/system/refresh-mtproxy-config.timer
install -m 0644 "$repository/deploy/firewall.nft" /etc/tproxy-server/firewall.nft
install -m 0755 "$repository/deploy/refresh-mtproxy-config.sh" /usr/local/sbin/refresh-mtproxy-config

/usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json \
	-profiles-file /etc/tproxy-server/profiles.json -check
systemctl daemon-reload
systemctl enable --now tproxy-firewall.service
systemctl enable --now mtproxy.service
systemctl restart mtproxy.service
systemctl enable --now tproxy-server.service
systemctl enable --now refresh-mtproxy-config.timer

# The front proxy is operator-owned and is never touched here. Validate the
# site's own configuration after merging the printed snippet.
relay_ready=
for ((attempt = 0; attempt != 20; ++attempt)); do
	if curl --fail --silent --output /dev/null \
			http://127.0.0.1:8081/readyz; then
		relay_ready=1
		break
	fi
	sleep 1
done
if [[ -z "$relay_ready" ]]; then
	echo "tproxy-server did not become ready" >&2
	exit 1
fi

# The client-facing proxy secret. Under a base path it is base64url of the marker
# byte 0x70 followed by the raw secret, so a client without base path support
# reports an unsupported proxy type and asks the user to update, instead of
# accepting a pathless proxy on an empty host. Never capture the raw secret in a
# variable: it can contain NUL bytes, which command substitution drops.
web_proxy_secret() {
	{
		printf '\x70'
		printf "$(printf %s "$secret" | sed 's/../\\x&/g')"
	} | base64 | tr '+/' '-_' | tr -d '=\n'
}

client_address="$hostname/$base_path"
proxy_secret="$(web_proxy_secret)"

echo
echo "Relay installed for https://$hostname/$base_path"
echo "nginx still owns 80/443; only the prefix below is routed to the relay."
echo
echo "=== http context (e.g. /etc/nginx/conf.d/tproxy-relay.conf) ==="
echo "If your http{} already defines \$connection_upgrade, drop the map and reuse"
echo "the existing name."
echo
cat <<'NGINX' | sed -e "s|__BASE__|$base_path|g" -e "s|__HOST__|$hostname|g"
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      "";
}

upstream tproxy_relay {
    server 127.0.0.1:8080;
    keepalive 32;
}
NGINX
echo
echo "=== inside the existing server {} for $hostname ==="
echo "TLS certificates, HSTS and security headers stay as they are; add only the"
echo "lines this block lacks."
echo
cat <<'NGINX' | sed -e "s|__BASE__|$base_path|g" -e "s|__HOST__|$hostname|g"
gzip on;
# Carrier uplink batches reach 2 MiB; nginx defaults to 1 MiB and would break
# the transport with 413.
client_max_body_size 4m;

location ^~ /__BASE__/ {
    # No URI part after the upstream name: the original path, including the
    # prefix, is forwarded unchanged. Do NOT write `.../;` here.
    proxy_pass http://tproxy_relay;
    proxy_http_version 1.1;

    proxy_set_header Host $host;
    # Exactly one address. $proxy_add_x_forwarded_for appends and can produce a
    # list, which the relay rejects.
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;

    # Parked long polls must not be cut or held back (relay long_poll is 25s).
    proxy_read_timeout 90s;
    proxy_send_timeout 90s;
    proxy_buffering off;
    proxy_request_buffering off;

    access_log off;     # never log carrier URIs or Authorization
}
NGINX
echo
echo "Apply:   sudo nginx -t && sudo systemctl reload nginx"
echo
echo "If nginx serves the site from static files rather than an upstream, give the"
echo "relay a loopback mirror of the same root and keep --site-upstream pointed at"
echo "it (BASE_PATH.md section 4); in-prefix 404s must match the site's own:"
echo
echo "server {"
echo "    listen 127.0.0.1:3000;"
echo "    server_name _;"
echo "    root /srv/www/$hostname;"
echo "    index index.html;"
echo "    error_page 404 /404.html;"
echo "}"
echo
echo "Verify against the live hostname:"
echo "  curl -sI https://$hostname/"
echo "  curl -sI https://$hostname/$base_path/"
echo "  curl -sI https://$hostname/$base_path/api/v1/ws"
echo "  curl -sI https://$hostname/api/v1/session"
echo
echo "Internal mtproxy secret: $secret"
echo "Proxy server:            $client_address"
echo "Proxy secret:            $proxy_secret"
echo "Proxy link:              https://t.me/webproxy?server=${client_address//\//%2F}&secret=$proxy_secret"
echo "Check: systemctl --no-pager --full status mtproxy tproxy-server"
echo "Check: curl --fail http://127.0.0.1:8081/readyz"
