# l2tp-connect

Bash helper that writes **StrongSwan (IPsec)** and **xl2tpd (L2TP/PPP)** drop-in configuration, restarts the relevant services, and brings up an IKEv1 L2TP VPN. It targets a typical Linux setup with `ppp0` as the PPP interface.

## Prerequisites

Install and enable the stack your distribution uses (names vary slightly):

- **IPsec**: `strongswan`
- **L2TP**: `xl2tpd`
- **PPP**: `ppp` (often pulled in by xl2tpd)
- **Tools**: `ip` from **iproute2**, `systemctl` (systemd), `grep` with Perl-style regex (`grep -oP`, GNU grep)

Examples:

- **Arch Linux**: `sudo pacman -S strongswan xl2tpd`
- **Debian / Ubuntu**: `sudo apt install strongswan xl2tpd`

Ensure `xl2tpd` and IPsec are enabled so they start at boot if you rely on them:

```bash
sudo systemctl enable --now xl2tpd
sudo systemctl enable --now strongswan-starter
```

## Installation

```bash
curl -fsSL raw.githubusercontent.com/AliAlmasiZ/l2tp-connect/main/l2tp-connect.sh -o /usr/local/bin/l2tp-connect
chmod +x /usr/local/bin/l2tp-connect
```

Run it as **root** (`sudo`). The script edits files under `/etc` and controls services.
```bash
sudo l2tp-connect -s vpn.example.com -n myuser -p 'my-password' -psk 'pre-shared-key'
```

### Optional defaults file

If `/etc/l2tp-connect.conf` exists, it is **sourced** as a shell snippet before command-line arguments are parsed. Use it to set defaults (CLI flags override these values).

```bash
# /etc/l2tp-connect.conf
SERVER="vpn.example.com"
NAME="myuser"
PASSWORD='secret'
PSK='shared-secret'
# Optional tunables (also overridable on the CLI):
# MAX_RETRIES=20
# IP_RETRY_SLEEP=5
```

Protect the file permissions :

```bash
sudo chmod 600 /etc/l2tp-connect.conf
```

## How to run

The script must run as **root**. Required parameters are **server**, **VPN username**, **VPN password**, and **IPsec PSK** (unless all are supplied via `/etc/l2tp-connect.conf`).

### Foreground (manual session)

Connect and stay in the foreground until `ppp0` loses its IPv4 address or you press **Ctrl+C** (which disconnects cleanly):

```bash
sudo l2tp-connect \
  -s vpn.example.com \
  -n myuser \
  -p 'my-password' \
  -psk 'pre-shared-key'
```

### Keepalive (systemd service)

Install a systemd unit that reconnects automatically (`vpn-keepalive.service`) and exit:

```bash
sudo l2tp-connect -s … -n … -p … -psk … --keepalive
```


### All options

| Option | Description |
|--------|-------------|
| `-s`, `--server` | VPN server hostname or IP |
| `-n`, `--name` | VPN login username |
| `-p`, `--password` | VPN login password |
| `-psk`, `--psk` | IPsec pre-shared key |
| `-k`, `--keepalive` | Install/start systemd auto-reconnect service instead of staying in foreground |
| `-r`, `--retries` | Max attempts while waiting for an IPv4 on `ppp0` (default: 15) |
| `-w`, `--retry-sleep` | Seconds between those attempts (default: 10) |
| `-h`, `--help` | Show usage and exit |

Example with tunables:

```bash
sudo l2tp-connect -s vpn.example.com -n u -p p -psk k -r 30 -w 5
```
