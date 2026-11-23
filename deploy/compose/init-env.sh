#!/usr/bin/env bash
# Writes .env for this machine: .env.example with HOST_IP filled in and
# fresh random credentials -- the Monster UI admin password, the CouchDB
# password and the Erlang cookie. Nothing in .env.example is a usable
# credential, so a cluster cannot start with a published one.
#
#   ./init-env.sh [HOST_IP]
#   ./init-env.sh --force [HOST_IP]   replace an existing .env
#
# Without HOST_IP it uses the address this machine's default route leaves
# from. An existing .env is left alone unless --force is given: the
# cluster's volumes hold the credentials it was started with, so new ones
# need `docker compose down -v` first.
set -euo pipefail

cd "$(dirname "$0")"

force=no
if [ "${1:-}" = --force ]; then
  force=yes
  shift
fi
host_ip=${1:-}

if [ -f .env ] && [ "$force" != yes ]; then
  echo ".env exists; it is left as it is (./init-env.sh --force replaces it)" >&2
  exit 1
fi

detect_ip() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 route get 1.1.1.1 2>/dev/null \
      | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}'
  elif command -v ipconfig >/dev/null 2>&1; then
    ipconfig getifaddr en0 2>/dev/null || true
  fi
}

if [ -z "$host_ip" ]; then
  host_ip=$(detect_ip)
fi
case "$host_ip" in
  "")
    echo "could not work out this machine's address: ./init-env.sh <HOST_IP>" >&2
    exit 1 ;;
  127.*|localhost|0.0.0.0)
    echo "HOST_IP=$host_ip: use this machine's LAN address; phones cannot reach a loopback address" >&2
    exit 1 ;;
esac

# random <length>: letters and digits from the kernel's random source
random() {
  head -c 256 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-"$1"
}

cookie=$(random 32)
# CouchDB's password goes unquoted into the nodes' config.ini: letters and
# digits only, starting with a letter
couchdb_password="c$(random 23)"
admin_password=$(random 20)

umask 077
sed -e "s|^HOST_IP=.*|HOST_IP=$host_ip|" \
    -e "s|^KAZOO_COOKIE=.*|KAZOO_COOKIE=$cookie|" \
    -e "s|^COUCHDB_PASSWORD=.*|COUCHDB_PASSWORD=$couchdb_password|" \
    -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$admin_password|" \
    .env.example >.env.new
mv .env.new .env

cat <<EOF
wrote .env: HOST_IP=$host_ip, with a new admin password, CouchDB password
and Erlang cookie. The Monster UI login is ADMIN_USER and ADMIN_PASSWORD in
that file. Next: docker compose up -d && ./bootstrap.sh
EOF
