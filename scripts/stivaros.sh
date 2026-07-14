#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
#  Stivaros VPN - Server Management Script
#  Version: 1.0.0
# ──────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
BOLD='\033[1m'

INSTALL_DIR="/opt/stivaros"
API_DIR="$INSTALL_DIR/api"
DB_PATH="$INSTALL_DIR/stivaros.db"
CONFIG_PATH="$INSTALL_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/stivaros-api.service"
API_PORT=9090

# ──────────────────────────────────────────────
#  ZIVPN (Camtel UDP Tunnel) Constants
# ──────────────────────────────────────────────
ZIVPN_BIN="/usr/local/bin/zivpn"
ZIVPN_SERVICE="zivpn.service"
ZIVPN_CONFIG="/etc/zivpn/config.json"
ZIVPN_USER_FILE="/etc/zivpn/users.list"
ZIVPN_DOMAIN_FILE="/etc/zivpn/domain.txt"
ZIVPN_PORT=5667

# ──────────────────────────────────────────────
#  Utility functions
# ──────────────────────────────────────────────

banner() {
    clear
    echo -e "${CYAN}"
    echo '  ╔══════════════════════════════════════════╗'
    echo '  ║          STIVAROS VPN PANEL              ║'
    echo '  ║     Server Management Console v1.0       ║'
    echo '  ╚══════════════════════════════════════════╝'
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        exit 1
    fi
}

msg()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; }
info()    { echo -e "${CYAN}[i]${NC} $1"; }

pause() {
    echo
    read -p "Press Enter to continue..."
}

confirm() {
    local prompt="$1"
    local reply
    read -p "$prompt [y/N]: " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]]
}

generate_secret() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -1
}

# ──────────────────────────────────────────────
#  API Server Code
# ──────────────────────────────────────────────

install_api_server() {
    info "Installing API server to $API_DIR..."
    mkdir -p "$API_DIR"

    cat > "$API_DIR/server.py" << 'PYEOF'
#!/usr/bin/env python3
"""Stivaros VPN API Server"""
import json, sqlite3, os, sys, urllib.request
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

DB_PATH = os.environ.get("STIVAROS_DB", "/opt/stivaros/stivaros.db")
API_KEY = os.environ.get("STIVAROS_API_KEY", "changeme")

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn

def init_db():
    conn = get_db()
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid TEXT UNIQUE NOT NULL,
            phone TEXT NOT NULL,
            name TEXT DEFAULT '',
            activation_code TEXT NOT NULL,
            hardware_id TEXT DEFAULT '',
            device_install_id TEXT DEFAULT '',
            app_version TEXT DEFAULT '',
            created_at TEXT DEFAULT (datetime('now')),
            expires_at TEXT,
            active INTEGER DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS vpn_configs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            server_address TEXT,
            server_port INTEGER DEFAULT 443,
            protocol TEXT DEFAULT 'vless',
            transport TEXT DEFAULT 'tcp',
            tls INTEGER DEFAULT 1,
            sni TEXT,
            public_key TEXT DEFAULT '',
            short_id TEXT DEFAULT '',
            isp TEXT DEFAULT '',
            mode TEXT DEFAULT '',
            flow TEXT DEFAULT '',
            tier TEXT DEFAULT '150',
            xray_uuid TEXT DEFAULT 'cfe75234-b0d9-477d-b30f-9d24654b2487',
            zivpn_password TEXT DEFAULT '',
            zivpn_port INTEGER DEFAULT 5667,
            zivpn_obfs TEXT DEFAULT 'hu``hqb`c',
            FOREIGN KEY(user_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_vpn_configs_user_isp_tier ON vpn_configs(user_id, isp, tier);
    """)
    # Migration: add zivpn columns for existing databases
    try:
        conn.execute("ALTER TABLE vpn_configs ADD COLUMN zivpn_password TEXT DEFAULT ''")
    except Exception:
        pass
    try:
        conn.execute("ALTER TABLE vpn_configs ADD COLUMN zivpn_port INTEGER DEFAULT 5667")
    except Exception:
        pass
    try:
        conn.execute("ALTER TABLE vpn_configs ADD COLUMN zivpn_obfs TEXT DEFAULT 'hu``hqb`c'")
    except Exception:
        pass
    conn.commit()
    conn.close()

def detect_isp(ip):
    """Detect ISP from IP address. Returns one of: mtn, orange, camtel, blue, unknown"""
    try:
        url = f"http://ip-api.com/json/{ip}?fields=isp,org"
        req = urllib.request.Request(url, headers={"User-Agent": "Stivaros/1.0"})
        resp = urllib.request.urlopen(req, timeout=5)
        data = json.loads(resp.read().decode())
        isp = (data.get("isp") or data.get("org") or "").lower()
        if "mtn" in isp: return "mtn"
        if "orange" in isp: return "orange"
        if "camtel" in isp: return "camtel"
        if "blue" in isp or "africell" in isp: return "blue"
        if "vodafone" in isp: return "blue"
        return "unknown"
    except Exception:
        return "unknown"


class APIHandler(BaseHTTPRequestHandler):
    def _send(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode())

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0: return {}
        return json.loads(self.rfile.read(length))

    def _get_user_by_uuid(self, uuid):
        conn = get_db()
        row = conn.execute("SELECT * FROM users WHERE uuid = ?", (uuid,)).fetchone()
        conn.close()
        return row

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Activation-Code")
        self.end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        params = parse_qs(parsed.query)

        if path == "/api/v1/devices/check":
            device_id = params.get("device_id", [None])[0]
            if not device_id:
                return self._send({"activated": False, "message": "Missing device_id"}, 400)
            user = self._get_user_by_uuid(device_id)
            if not user:
                user = conn.execute("SELECT * FROM users WHERE phone = ?", (device_id,)).fetchone()
            if user and user["active"]:
                exp = user["expires_at"]
                if exp and datetime.fromisoformat(exp) < datetime.now():
                    return self._send({"activated": False, "message": "Subscription expired"}, 403)
                return self._send({
                    "activated": True,
                    "phone": user["phone"],
                    "name": user["name"],
                    "expires_at": user["expires_at"],
                    "message": "Device is active"
                })
            return self._send({"activated": False, "message": "Device not found or inactive"}, 404)

        elif path == "/api/v1/config/auto":
            uuid = params.get("uuid", [None])[0]
            code = params.get("code", [""])[0]
            mode = params.get("mode", ["normal"])[0]
            tier = params.get("tier", ["150"])[0]
            if tier not in ("150", "100"):
                return self._send({"success": False, "message": "Invalid tier"}, 400)
            user = self._get_user_by_uuid(uuid)
            if not user or not user["active"]:
                c = get_db()
                user = c.execute("SELECT * FROM users WHERE device_install_id = ?", (uuid,)).fetchone()
                c.close()
            if not user or not user["active"]:
                return self._send({"success": False, "message": "User not found or inactive"}, 404)
            if user["activation_code"] != code:
                return self._send({"success": False, "message": "Invalid activation code"}, 403)
            exp = user["expires_at"]
            if exp and datetime.fromisoformat(exp) < datetime.now():
                return self._send({"success": False, "message": "Subscription expired"}, 403)

            client_ip = self.client_address[0]
            isp = detect_isp(client_ip)

            conn = get_db()
            cfg = conn.execute(
                "SELECT * FROM vpn_configs WHERE user_id = ? AND isp = ? AND tier = ? AND mode = ?",
                (user["id"], isp, tier, mode)
            ).fetchone()
            if not cfg:
                cfg = conn.execute(
                    "SELECT * FROM vpn_configs WHERE user_id = ? AND isp = ? AND tier = ? AND mode = ''",
                    (user["id"], isp, tier)
                ).fetchone()
            if not cfg:
                cfg = conn.execute(
                    "SELECT * FROM vpn_configs WHERE user_id = ? AND isp = '' AND tier = ? AND mode = ''",
                    (user["id"], tier)
                ).fetchone()
            conn.close()

            if cfg:
                resp = {
                    "success": True,
                    "isp": isp,
                    "mode": cfg["mode"] or mode,
                    "tier": tier,
                    "address": cfg["server_address"],
                    "port": cfg["server_port"],
                    "protocol": cfg["protocol"],
                    "transport": cfg["transport"] or "xhttp",
                    "tls": bool(cfg["tls"]),
                    "sni": cfg["sni"] or cfg["server_address"],
                    "flow": cfg["flow"] or "",
                    "public_key": cfg["public_key"] or "",
                    "short_id": cfg["short_id"] or "",
                    "config_id": cfg["id"],
                    "xray_uuid": cfg["xray_uuid"] or "cfe75234-b0d9-477d-b30f-9d24654b2487"
                }
                # Add ZIVPN/Camtel UDP fields if mode is zivpn
                if cfg["mode"] == "zivpn":
                    resp["zivpn_password"] = cfg["zivpn_password"] or ""
                return self._send(resp)

        elif path.startswith("/api/v1/config/") and path != "/api/v1/config/auto":
            uuid = path.split("/")[-1]
            code = self.headers.get("X-Activation-Code", "")
            user = self._get_user_by_uuid(uuid)
            if not user or not user["active"]:
                conn = get_db()
                user = conn.execute("SELECT * FROM users WHERE device_install_id = ?", (uuid,)).fetchone()
                conn.close()
            if not user or not user["active"]:
                return self._send({"success": False, "message": "User not found or inactive"}, 404)
            if user["activation_code"] != code:
                return self._send({"success": False, "message": "Invalid activation code"}, 403)
            conn = get_db()
            cfg = conn.execute(
                "SELECT * FROM vpn_configs WHERE user_id = ? AND mode != 'zivpn' ORDER BY id LIMIT 1", (user["id"],)
            ).fetchone()
            if not cfg:
                cfg = conn.execute(
                    "SELECT * FROM vpn_configs WHERE user_id = ? LIMIT 1", (user["id"],)
                ).fetchone()
            conn.close()
            if cfg:
                resp = {
                    "success": True,
                    "address": cfg["server_address"],
                    "port": cfg["server_port"],
                    "protocol": cfg["protocol"],
                    "transport": cfg["transport"],
                    "tls": bool(cfg["tls"]),
                    "sni": cfg["sni"] or cfg["server_address"],
                    "public_key": cfg["public_key"] or "",
                    "short_id": cfg["short_id"] or "",
                    "mode": cfg["mode"] or ""
                }
                if cfg["mode"] == "zivpn":
                    resp["zivpn_password"] = cfg["zivpn_password"] or ""
                return self._send(resp)

        elif path == "/api/v1/user/configs":
            params = parse_qs(parsed.query)
            uuid = params.get("uuid", [None])[0]
            code = params.get("code", [""])[0]
            isp = params.get("isp", [""])[0]
            if not uuid:
                return self._send({"success": False, "message": "Missing uuid"}, 400)
            user = self._get_user_by_uuid(uuid)
            if not user or not user["active"]:
                conn = get_db()
                user = conn.execute("SELECT * FROM users WHERE device_install_id = ?", (uuid,)).fetchone()
                conn.close()
            if not user or not user["active"]:
                return self._send({"success": False, "message": "User not found or inactive"}, 404)
            if user["activation_code"] != code:
                return self._send({"success": False, "message": "Invalid activation code"}, 403)
            exp = user["expires_at"]
            if exp and datetime.fromisoformat(exp) < datetime.now():
                return self._send({"success": False, "message": "Subscription expired"}, 403)

            conn = get_db()
            rows = conn.execute(
                "SELECT * FROM vpn_configs WHERE user_id = ? AND (mode = 'zivpn' OR (isp IN ('mtn','') AND mode = '')) ORDER BY tier DESC, mode ASC, id ASC", (user["id"],)
            ).fetchall()
            conn.close()

            configs = []
            seen = set()
            for cfg in rows:
                mode = cfg["mode"] or "xray"
                isp = cfg["isp"] or ""
                tier = cfg["tier"] or "150"
                if mode == "zivpn":
                    label = "Camtel UDP"
                elif isp == "mtn" and tier == "150":
                    label = "MTN 150Mo"
                elif isp == "mtn" and tier == "100":
                    label = "MTN 100Mo"
                else:
                    continue
                if label in seen:
                    continue
                seen.add(label)
                entry = {
                    "label": label,
                    "address": cfg["server_address"],
                    "port": cfg["server_port"],
                    "protocol": cfg["protocol"],
                    "transport": cfg["transport"],
                    "tls": bool(cfg["tls"]),
                    "sni": cfg["sni"],
                    "host": cfg["sni"] or cfg["server_address"],
                    "public_key": cfg["public_key"] or "",
                    "short_id": cfg["short_id"] or "",
                    "flow": cfg["flow"] or "",
                    "tier": tier,
                    "mode": "zivpn" if mode == "zivpn" else "xray",
                    "isp": isp,
                    "xray_uuid": cfg["xray_uuid"] or "cfe75234-b0d9-477d-b30f-9d24654b2487",
                    "config_id": cfg["id"],
                }
                if mode == "zivpn":
                    entry["zivpn_password"] = cfg["zivpn_password"] or ""
                configs.append(entry)

            return self._send({"success": True, "configs": configs})

        elif path == "/api/v1/status":
            conn = get_db()
            count = conn.execute("SELECT COUNT(*) as c FROM users WHERE active=1").fetchone()["c"]
            conn.close()
            return self._send({"status": "ok", "active_users": count})

        else:
            return self._send({"error": "Not found"}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/api/v1/devices/register":
            body = self._read_body()
            uuid = body.get("device_install_id") or body.get("uuid", "")
            phone = body.get("phone_number", "")
            code = body.get("activation_code", "")
            hwid = body.get("hardware_id", "")

            if not uuid or not phone or not code:
                return self._send({"success": False, "message": "Missing required fields"}, 400)

            conn = get_db()
            user = conn.execute("SELECT * FROM users WHERE uuid = ?", (uuid,)).fetchone()
            if not user:
                user = conn.execute("SELECT * FROM users WHERE phone = ?", (phone,)).fetchone()
            if not user:
                return self._send({"success": False, "message": "Device not registered. Contact admin."}, 404)
            if user["activation_code"] != code:
                return self._send({"success": False, "message": "Invalid activation code"}, 403)
            if not user["active"]:
                return self._send({"success": False, "message": "Device is disabled"}, 403)

            exp = user["expires_at"]
            if exp and datetime.fromisoformat(exp) < datetime.now():
                return self._send({"success": False, "message": "Subscription expired"}, 403)

            conn.execute(
                "UPDATE users SET device_install_id=?, hardware_id=?, app_version=? WHERE id=?",
                (uuid, hwid, body.get("app_version", ""), user["id"])
            )
            conn.commit()

            cfg = conn.execute(
                "SELECT * FROM vpn_configs WHERE user_id = ? AND mode != 'zivpn' ORDER BY tier DESC LIMIT 1", (user["id"],)
            ).fetchone()
            if not cfg:
                cfg = conn.execute(
                    "SELECT * FROM vpn_configs WHERE user_id = ? LIMIT 1", (user["id"],)
                ).fetchone()
            conn.close()

            server_data = None
            if cfg:
                server_data = {
                    "address": cfg["server_address"],
                    "port": cfg["server_port"],
                    "protocol": cfg["protocol"],
                    "transport": cfg["transport"],
                    "tls": bool(cfg["tls"]),
                    "sni": cfg["sni"] or cfg["server_address"],
                    "public_key": cfg["public_key"] or "",
                    "short_id": cfg["short_id"] or ""
                }
                if cfg["mode"] == "zivpn":
                    server_data["zivpn_password"] = cfg["zivpn_password"] or ""

            return self._send({
                "success": True,
                "message": "Device activated successfully",
                "phone": phone,
                "expires_at": exp,
                "server": server_data
            })

        else:
            return self._send({"error": "Not found"}, 404)

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        if path.startswith("/api/v1/config/"):
            parts = path.split("/")
            config_id = parts[-1] if len(parts) > 0 else None
            if config_id and config_id.isdigit():
                conn = get_db()
                conn.execute("DELETE FROM vpn_configs WHERE id = ?", (int(config_id),))
                conn.commit()
                conn.close()
                return self._send({"success": True, "message": "Config deleted"})
            return self._send({"success": False, "message": "Invalid config ID"}, 400)
        return self._send({"error": "Not found"}, 404)

    def log_message(self, format, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), format % args))

if __name__ == "__main__":
    init_db()
    port = int(os.environ.get("STIVAROS_PORT", 8080))
    server = HTTPServer(("0.0.0.0", port), APIHandler)
    print(f"[✓] Stivaros API running on 0.0.0.0:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()
PYEOF

    chmod +x "$API_DIR/server.py"
    msg "API server installed"
}

# ──────────────────────────────────────────────
#  Installation (Option 1)
# ──────────────────────────────────────────────

install_all() {
    banner
    echo -e "${BOLD}Complete Installation${NC}\n"

    # Check Python
    if ! command -v python3 &>/dev/null; then
        info "Installing Python3..."
        apt-get update -qq && apt-get install -y -qq python3 python3-pip sqlite3
        msg "Python3 installed"
    else
        msg "Python3 already installed"
    fi

    # Create directories
    mkdir -p "$INSTALL_DIR" "$API_DIR"
    msg "Created directories: $INSTALL_DIR"

    # Install API server
    install_api_server

    # Generate config
    SECRET=$(generate_secret)
    cat > "$CONFIG_PATH" << EOF
{
  "port": $API_PORT,
  "db": "$DB_PATH",
  "api_key": "$SECRET",
  "version": "1.0.0"
}
EOF
    msg "Config generated"

    # Initialize database
    python3 "$API_DIR/server.py" &
    local pid=$!
    sleep 1
    kill $pid 2>/dev/null || true
    msg "Database initialized"

    # Create systemd service
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Stivaros VPN API Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$API_DIR
ExecStart=/usr/bin/env python3 $API_DIR/server.py
Restart=always
RestartSec=5
Environment="STIVAROS_DB=$DB_PATH"
Environment="STIVAROS_PORT=$API_PORT"
Environment="STIVAROS_API_KEY=$SECRET"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable stivaros-api
    systemctl restart stivaros-api
    msg "API service started on port $API_PORT"

    # Save fixed API URL (change DNS via Cloudflare to point to any VPS)
    local API_URL="https://api-v1.kingom.ggff.net:5443"
    echo "$API_URL" > "$INSTALL_DIR/api_domain.txt"

    # Firewall
    if command -v ufw &>/dev/null; then
        ufw allow "$API_PORT/tcp" 2>/dev/null || true
        msg "Firewall: port $API_PORT opened"
    fi

    echo
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Installation complete!${NC}"
    echo -e "${CYAN}  API running on port $API_PORT${NC}"
    echo -e "${CYAN}  API Key: $SECRET${NC}"
    echo -e "${YELLOW}  Save this key for app configuration!${NC}"
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    pause
}

# ──────────────────────────────────────────────
#  Create User (Option 2)
# ──────────────────────────────────────────────

create_user() {
    banner
    echo -e "${BOLD}Create New User${NC}\n"

    if [[ ! -f "$DB_PATH" ]]; then
        error "Database not found. Install first (Option 1)."
        pause; return
    fi

    read -p "Enter Name           : " name
    read -p "Enter Device UUID   : " uuid
    read -p "Enter Phone Number  : " phone
    read -p "Enter Expiration date (YYYY-MM-DD): " expires

    if [[ -z "$name" || -z "$uuid" || -z "$phone" || -z "$expires" ]]; then
        error "All fields are required"
        pause; return
    fi

    # Generate 6-digit activation code
    code=$(tr -dc '0-9' < /dev/urandom | fold -w 6 | head -1)

    # Default server config
    read -p "Server address [default: kiaje2.kingom.ggff.net]: " server_addr
    server_addr=${server_addr:-kiaje2.kingom.ggff.net}
    read -p "Server port [default: 443]: " server_port
    server_port=${server_port:-443}
    read -p "Xray UUID [default: cfe75234-b0d9-477d-b30f-9d24654b2487]: " xray_uuid
    xray_uuid=${xray_uuid:-cfe75234-b0d9-477d-b30f-9d24654b2487}

    # Add name column if not exists (migration)
    sqlite3 "$DB_PATH" "ALTER TABLE users ADD COLUMN name TEXT DEFAULT '';" 2>/dev/null || true
    # Add zivpn columns if not exists (migration)
    sqlite3 "$DB_PATH" "ALTER TABLE vpn_configs ADD COLUMN zivpn_password TEXT DEFAULT '';" 2>/dev/null || true
    sqlite3 "$DB_PATH" "ALTER TABLE vpn_configs ADD COLUMN zivpn_port INTEGER DEFAULT 5667;" 2>/dev/null || true
    sqlite3 "$DB_PATH" "ALTER TABLE vpn_configs ADD COLUMN zivpn_obfs TEXT DEFAULT 'hu\`\`hqb\`c';" 2>/dev/null || true

    # Generate ZIVPN password for Camtel UDP
    zivpn_pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 12 | head -1)
    zivpn_expire=$(date -d "$expires" '+%Y-%m-%d' 2>/dev/null || echo "$expires")

    sqlite3 "$DB_PATH" << EOF
INSERT INTO users (uuid, phone, name, activation_code, expires_at, active)
VALUES ('$uuid', '$phone', '$name', '$code', '$expires', 1);

-- Default config (tier 150)
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $server_port, 'vless', 'xhttp', 1, '$server_addr', '', '', '', '150', '$xray_uuid');

-- Default config (tier 100)
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $server_port, 'vless', 'xhttp', 1, '$server_addr', '', '', '', '100', '$xray_uuid');

-- ISP-specific configs (tier 150)
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $server_port, 'vless', 'xhttp', 1, 'mtnplay.com', 'mtn', '', '', '150', '$xray_uuid');
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $server_port, 'vless', 'xhttp', 1, '$server_addr', 'orange', '', '', '150', '$xray_uuid');
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $server_port, 'vless', 'xhttp', 1, '$server_addr', 'camtel', '', '', '150', '$xray_uuid');
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $server_port, 'vless', 'xhttp', 1, '$server_addr', 'blue', '', '', '150', '$xray_uuid');
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $server_port, 'vless', 'xhttp', 1, '$server_addr', 'unknown', '', '', '150', '$xray_uuid');

-- ISP-specific configs (tier 100)
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $server_port, 'vless', 'xhttp', 1, 'mtnplay.com', 'mtn', '', '', '100', '$xray_uuid');
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $server_port, 'vless', 'xhttp', 1, '$server_addr', 'orange', '', '', '100', '$xray_uuid');
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $server_port, 'vless', 'xhttp', 1, '$server_addr', 'camtel', '', '', '100', '$xray_uuid');
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $server_port, 'vless', 'xhttp', 1, '$server_addr', 'blue', '', '', '100', '$xray_uuid');
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $server_port, 'vless', 'xhttp', 1, '$server_addr', 'unknown', '', '', '100', '$xray_uuid');

-- Camtel UDP (ZIVPN) configs - tier 150
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid, zivpn_password, zivpn_port, zivpn_obfs)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $ZIVPN_PORT, 'zivpn', 'udp', 0, '$server_addr', 'camtel', 'zivpn', '', '150', '$xray_uuid', '$zivpn_pass', $ZIVPN_PORT, 'hu\`\`hqb\`c');
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid, zivpn_password, zivpn_port, zivpn_obfs)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $ZIVPN_PORT, 'zivpn', 'udp', 0, '$server_addr', '', 'zivpn', '', '150', '$xray_uuid', '$zivpn_pass', $ZIVPN_PORT, 'hu\`\`hqb\`c');

-- Camtel UDP (ZIVPN) configs - tier 100
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid, zivpn_password, zivpn_port, zivpn_obfs)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $ZIVPN_PORT, 'zivpn', 'udp', 0, '$server_addr', 'camtel', 'zivpn', '', '100', '$xray_uuid', '$zivpn_pass', $ZIVPN_PORT, 'hu\`\`hqb\`c');
INSERT INTO vpn_configs (user_id, server_address, server_port, protocol, transport, tls, sni, isp, mode, flow, tier, xray_uuid, zivpn_password, zivpn_port, zivpn_obfs)
VALUES ((SELECT id FROM users WHERE uuid='$uuid'), '$server_addr', $ZIVPN_PORT, 'zivpn', 'udp', 0, '$server_addr', '', 'zivpn', '', '100', '$xray_uuid', '$zivpn_pass', $ZIVPN_PORT, 'hu\`\`hqb\`c');
EOF

    # Create ZIVPN system user for Camtel UDP tunnel
    if [[ -x "$ZIVPN_BIN" ]] && systemctl is-active --quiet "$ZIVPN_SERVICE" 2>/dev/null; then
        mkdir -p /etc/zivpn
        local ztmp
        ztmp=$(mktemp)
        zivpn_cleanup_expired
        [[ -f "$ZIVPN_USER_FILE" ]] && cp "$ZIVPN_USER_FILE" "$ztmp"
        grep -v "^$uuid|" "$ztmp" > "${ztmp}.2" 2>/dev/null || true
        echo "$uuid|$zivpn_pass|$zivpn_expire" >> "${ztmp}.2"
        mv "${ztmp}.2" "$ZIVPN_USER_FILE"
        rm -f "$ztmp"
        chmod 600 "$ZIVPN_USER_FILE"
        zivpn_update_config_passwords 2>/dev/null || true
    fi

    # Sync Xray server config with all active UUIDs
    if [[ -f /etc/xray/config.json ]]; then
        xray_sync_uuids
    fi

    echo
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    echo "  ✅ Customer created!"
    echo
    echo "  • Name: $name"
    echo "  • Number: $phone"
    echo "  • UUID: $uuid"
    echo "  • Activation code: $code"
    echo "  • Xray UUID: $xray_uuid"
    echo
    echo -e "${BOLD}  Camtel UDP (ZIVPN) config:${NC}"
    echo "  • Server: $server_addr"
    echo "  • Port: $ZIVPN_PORT"
    echo "  • Password: $zivpn_pass"
    echo "  • Obfs: zivpn"
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    pause
}

# ──────────────────────────────────────────────
#  List Users (Option 3)
# ──────────────────────────────────────────────

list_users() {
    banner
    echo -e "${BOLD}All Users${NC}\n"

    if [[ ! -f "$DB_PATH" ]]; then
        error "Database not found. Install first (Option 1)."
        pause; return
    fi

    printf "${CYAN}%-4s | %-16s | %-36s | %-16s | %-12s | %s${NC}\n" "#" "Name" "UUID" "Phone" "Expires" "Status"
    printf -- "-----|------------------|--------------------------------------|------------------|--------------|--------\n"

    local i=0
    while IFS='|' read -r id name uuid phone expires active; do
        i=$((i+1))
        local status
        if [[ "$active" -eq 0 ]]; then
            status="${RED}disabled${NC}"
        elif [[ -n "$expires" && "$(date +%s)" -gt "$(date -d "$expires" +%s 2>/dev/null || echo 0)" ]]; then
            status="${YELLOW}expired${NC}"
        else
            status="${GREEN}active${NC}"
        fi
        printf "%-4s | %-16s | %-36s | %-16s | %-12s | %b\n" "$id" "$name" "$uuid" "$phone" "$expires" "$status"
    done < <(sqlite3 "$DB_PATH" "SELECT id, COALESCE(name,''), uuid, phone, expires_at, active FROM users ORDER BY id;")

    if [[ $i -eq 0 ]]; then
        warn "No users found"
    fi
    echo -e "\n${CYAN}Total: $i users${NC}"
    pause
}

# ──────────────────────────────────────────────
#  Delete Users (Option 4)
# ──────────────────────────────────────────────

delete_users() {
    banner
    echo -e "${BOLD}Delete Users${NC}\n"

    if [[ ! -f "$DB_PATH" ]]; then
        error "Database not found. Install first (Option 1)."
        pause; return
    fi

    # Show user list with numbers
    printf "${CYAN}%-4s | %-36s | %-16s | %s${NC}\n" "#" "UUID" "Phone" "Expires"
    printf -- "-----|--------------------------------------|------------------|--------------\n"

    declare -a USER_IDS
    while IFS='|' read -r id uuid phone expires; do
        USER_IDS+=("$id")
        printf "%-4s | %-36s | %-16s | %s\n" "$id" "$uuid" "$phone" "$expires"
    done < <(sqlite3 "$DB_PATH" "SELECT id, uuid, phone, expires_at FROM users ORDER BY id;")

    if [[ ${#USER_IDS[@]} -eq 0 ]]; then
        warn "No users found"
        pause; return
    fi

    echo
    read -p "Enter number(s) to delete (e.g. 1,2,3,4): " input

    if [[ -z "$input" ]]; then
        warn "No input, cancelled"
        pause; return
    fi

    # Parse numbers
    local deleted=0
    IFS=',' read -ra NUMS <<< "$input"
    for num in "${NUMS[@]}"; do
        num=$(echo "$num" | xargs) # trim
        if [[ "$num" =~ ^[0-9]+$ ]]; then
            local found=0
            for uid in "${USER_IDS[@]}"; do
                if [[ "$uid" -eq "$num" ]]; then
                    sqlite3 "$DB_PATH" "DELETE FROM vpn_configs WHERE user_id=$uid;"
                    sqlite3 "$DB_PATH" "DELETE FROM users WHERE id=$uid;"
                    msg "User #$uid deleted"
                    deleted=$((deleted+1))
                    found=1
                    break
                fi
            done
            if [[ "$found" -eq 0 ]]; then
                warn "User #$num not found"
            fi
        else
            warn "Invalid number: $num"
        fi
    done

    if [[ $deleted -gt 0 ]]; then
        systemctl restart stivaros-api 2>/dev/null || true
        msg "API service restarted"
        if [[ -f /etc/xray/config.json ]]; then
            xray_sync_uuids
        fi
    fi
    pause
}

# ──────────────────────────────────────────────
#  Uninstall (Option 5)
# ──────────────────────────────────────────────

uninstall_all() {
    banner
    echo -e "${BOLD}Complete Uninstallation${NC}\n"
    echo -e "${RED}WARNING: This will remove ALL data and services!${NC}\n"

    if ! confirm "Are you sure you want to uninstall Stivaros?"; then
        info "Uninstallation cancelled"
        pause; return
    fi
    if ! confirm "Really? This cannot be undone!"; then
        info "Uninstallation cancelled"
        pause; return
    fi

    echo
    info "Stopping and removing service..."
    systemctl stop stivaros-api 2>/dev/null || true
    systemctl disable stivaros-api 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    msg "Service removed"

    info "Removing installation directory..."
    rm -rf "$INSTALL_DIR"
    msg "Directory removed"

    echo
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Stivaros completely uninstalled${NC}"
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    pause
}

# ──────────────────────────────────────────────
#  ZIVPN (Camtel UDP) Functions
# ──────────────────────────────────────────────

zivpn_write_optimized_config() {
    cat > "$ZIVPN_CONFIG" << 'EOF'
{
  "listen": ":5667",
  "cert": "/etc/zivpn/zivpn.crt",
  "key": "/etc/zivpn/zivpn.key",
  "obfs": "hu``hqb`c",
  "recv_window_conn": 15728640,
  "recv_window_client": 67108864,
  "disable_mtu_discovery": false,
  "max_conn_client": 4096,
  "exclude_port": [53,5300,4466,36712,20000],
  "auth": {
    "mode": "passwords",
    "config": ["zi"]
  }
}
EOF
}

zivpn_write_optimized_service() {
    cat > "/etc/systemd/system/$ZIVPN_SERVICE" << EOF
[Unit]
Description=ZIVPN UDP Server (High-Speed)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$ZIVPN_BIN server -c $ZIVPN_CONFIG
WorkingDirectory=/etc/zivpn
Restart=always
RestartSec=10
StartLimitBurst=0
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
LimitNOFILE=1048576
LimitNPROC=infinity
LimitMEMLOCK=infinity
StandardOutput=append:/var/log/zivpn.log
StandardError=append:/var/log/zivpn.log

[Install]
WantedBy=multi-user.target
EOF
}

zivpn_apply_optimizations() {
    echo -e "${CYAN}⚙️  Applying network optimizations...${NC}"
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true
    local KEYS=(net.core.rmem_default net.core.wmem_default net.core.rmem_max net.core.wmem_max net.core.netdev_max_backlog net.core.optmem_max net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.ip_forward net.ipv4.udp_mem fs.file-max net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing)
    for KEY in "${KEYS[@]}"; do
        sed -i "/^${KEY}=/d" /etc/sysctl.conf 2>/dev/null || true
    done
    cat >> /etc/sysctl.conf << 'SYSEOF'
# === ZIVPN High-Speed Optimizations ===
net.core.rmem_default=26214400
net.core.wmem_default=26214400
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.optmem_max=25165824
fs.file-max=1000000
net.core.netdev_max_backlog=250000
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.ipv4.udp_mem=102400 873800 16777216
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
# === FIN ZIVPN ===
SYSEOF
    sysctl -p >/dev/null 2>&1 || true
    local IFACE
    IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
    if [[ -n "$IFACE" ]]; then
        tc qdisc del dev "$IFACE" root 2>/dev/null || true
        tc qdisc add dev "$IFACE" root fq 2>/dev/null || true
        echo -e "${GREEN}✅ FQ qdisc applied on $IFACE${NC}"
    fi
    echo -e "${GREEN}✅ Network optimizations applied (BBR + 67MB buffers + FQ)${NC}"
}

zivpn_apply_nftables() {
    local TMP_NFT
    TMP_NFT=$(mktemp)
    cat > "$TMP_NFT" << 'EOF'
table inet zivpn {
    chain input {
        type filter hook input priority 0; policy accept;
        udp dport 5667 accept
        udp dport 6000-19999 accept
    }
    chain prerouting {
        type nat hook prerouting priority -100;
        udp dport 6000-19999 dnat to :5667
    }
}
EOF
    if nft -c -f "$TMP_NFT" 2>/dev/null; then
        mkdir -p /etc/nftables
        cp "$TMP_NFT" /etc/nftables/zivpn.nft
        systemctl daemon-reload 2>/dev/null || true
        echo -e "${GREEN}✅ nftables ZIVPN rules applied${NC}"
    else
        echo -e "${RED}❌ nftables syntax error — rules not applied${NC}"
    fi
    rm -f "$TMP_NFT"
}

zivpn_update_config_passwords() {
    local TODAY PASSWORDS TMP
    TODAY=$(date +%Y-%m-%d)
    PASSWORDS=$(awk -F'|' -v today="$TODAY" '$3>=today {print $2}' "$ZIVPN_USER_FILE" 2>/dev/null | sort -u | paste -sd, -)
    if [[ -z "$PASSWORDS" ]]; then
        echo -e "${YELLOW}⚠️  No active ZIVPN users — config unchanged${NC}"
        return 0
    fi
    TMP=$(mktemp)
    if jq --arg passwords "$PASSWORDS" '.auth.config = ($passwords | split(","))' "$ZIVPN_CONFIG" > "$TMP" 2>/dev/null && jq empty "$TMP" >/dev/null 2>&1; then
        mv "$TMP" "$ZIVPN_CONFIG"
        systemctl restart "$ZIVPN_SERVICE" 2>/dev/null || true
        return 0
    else
        echo -e "${RED}❌ Invalid JSON — config unchanged${NC}"
        rm -f "$TMP"
        return 1
    fi
}

zivpn_restore_from_db() {
    local ENV_FILE="/opt/kighmu-panel/.env"
    if [[ ! -f "$ENV_FILE" ]]; then return 0; fi
    local DB_HOST DB_USER DB_PASS DB_NAME DB_PORT COUNT
    DB_HOST=$(grep '^DB_HOST=' "$ENV_FILE" | cut -d'=' -f2 | tr -d '"'"'"' ')
    DB_USER=$(grep '^DB_USER=' "$ENV_FILE" | cut -d'=' -f2 | tr -d '"'"'"' ')
    DB_PASS=$(grep '^DB_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2 | tr -d '"'"'"' ')
    DB_NAME=$(grep '^DB_NAME=' "$ENV_FILE" | cut -d'=' -f2 | tr -d '"'"'"' ')
    DB_PORT=$(grep '^DB_PORT=' "$ENV_FILE" | cut -d'=' -f2 | tr -d '"'"'"' ')
    DB_HOST=${DB_HOST:-127.0.0.1}; DB_PORT=${DB_PORT:-3306}
    command -v mysql &>/dev/null || return 0
    COUNT=$(mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" -P"$DB_PORT" -N -e "SELECT COUNT(*) FROM clients WHERE tunnel_type='udp-zivpn' AND expires_at >= NOW() AND is_active=1;" "$DB_NAME" 2>/dev/null)
    [[ -z "$COUNT" || "$COUNT" -eq 0 ]] && return 0
    echo -e "${CYAN}♻️  Restoring ${COUNT} ZIVPN user(s) from DB...${NC}"
    local ROWS
    ROWS=$(mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" -P"$DB_PORT" -N -e "SELECT username, password, DATE(expires_at) FROM clients WHERE tunnel_type='udp-zivpn' AND expires_at >= NOW() AND is_active=1 ORDER BY expires_at ASC;" "$DB_NAME" 2>/dev/null)
    [[ -z "$ROWS" ]] && return 0
    mkdir -p /etc/zivpn
    local TMP INJECTED
    TMP=$(mktemp)
    [[ -f "$ZIVPN_USER_FILE" && -s "$ZIVPN_USER_FILE" ]] && cp "$ZIVPN_USER_FILE" "$TMP"
    INJECTED=0
    while IFS=$'\t' read -r UNAME UPASS UEXP; do
        [[ -z "$UNAME" ]] && continue
        grep -v "^${UNAME}|" "$TMP" > "${TMP}.2" 2>/dev/null || true
        mv "${TMP}.2" "$TMP"
        echo "${UNAME}|${UPASS}|${UEXP}" >> "$TMP"
        (( INJECTED++ ))
    done <<< "$ROWS"
    mv "$TMP" "$ZIVPN_USER_FILE"
    chmod 600 "$ZIVPN_USER_FILE"
    zivpn_update_config_passwords
    echo -e "${GREEN}✅ ${INJECTED} ZIVPN user(s) restored from DB${NC}"
}

zivpn_cleanup_expired() {
    [[ ! -f "$ZIVPN_USER_FILE" ]] && return 0
    local TODAY TMP
    TODAY=$(date +%Y-%m-%d)
    TMP=$(mktemp)
    awk -F'|' -v today="$TODAY" '$3>=today {print $0}' "$ZIVPN_USER_FILE" > "$TMP" 2>/dev/null || true
    mv "$TMP" "$ZIVPN_USER_FILE"
    chmod 600 "$ZIVPN_USER_FILE"
}

zivpn_install() {
    banner
    echo -e "${BOLD}Install ZIVPN (Camtel UDP Tunnel)${NC}\n"
    if [[ -x "$ZIVPN_BIN" ]] && systemctl list-unit-files 2>/dev/null | grep -q "^$ZIVPN_SERVICE"; then
        warn "ZIVPN already installed"
        pause; return
    fi

    systemctl stop ufw 2>/dev/null || true; ufw disable 2>/dev/null || true
    apt-get update -qq && apt-get install -y -qq wget curl jq openssl iproute2 nftables

    info "Downloading ZIVPN binary..."
    wget -q "https://github.com/kinf744/Kighmu/releases/download/v1.0.0/udp-zivpn-linux-amd64" -O "$ZIVPN_BIN"
    chmod +x "$ZIVPN_BIN"

    mkdir -p /etc/zivpn
    local DOMAIN
    while [[ -z "$DOMAIN" ]]; do
        read -p "Domain for ZIVPN certificate (e.g. vps.example.com): " DOMAIN
    done
    echo "$DOMAIN" > "$ZIVPN_DOMAIN_FILE"

    local CERT="/etc/zivpn/zivpn.crt" KEY="/etc/zivpn/zivpn.key"
    openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" -nodes -days 3650 -subj "/CN=$DOMAIN"
    chmod 600 "$KEY"; chmod 644 "$CERT"

    zivpn_write_optimized_config
    zivpn_write_optimized_service
    systemctl daemon-reload
    systemctl enable "$ZIVPN_SERVICE"

    zivpn_apply_nftables
    zivpn_apply_optimizations

    systemctl start "$ZIVPN_SERVICE" || true
    sleep 3

    if systemctl is-active --quiet "$ZIVPN_SERVICE"; then
        local IP
        IP=$(hostname -I | awk '{print $1}')
        echo -e "\n${GREEN}✅ ZIVPN installed and active!${NC}"
        echo -e "📱 Config: Server=$IP Port=$ZIVPN_PORT Obfs=zivpn"
        zivpn_restore_from_db
    else
        echo -e "${RED}❌ ZIVPN failed to start${NC}"
        journalctl -u zivpn.service -n 20 --no-pager
    fi
    pause
}

zivpn_uninstall() {
    banner
    echo -e "${BOLD}Uninstall ZIVPN${NC}\n"
    if ! confirm "Remove ZIVPN completely?"; then
        info "Cancelled"; pause; return
    fi
    systemctl stop "$ZIVPN_SERVICE" 2>/dev/null || true
    systemctl disable "$ZIVPN_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$ZIVPN_SERVICE"
    systemctl daemon-reload
    rm -f "$ZIVPN_BIN"
    rm -rf /etc/zivpn
    rm -f /etc/nftables/zivpn.nft
    msg "ZIVPN removed"
    pause
}

zivpn_create_user_panel() {
    banner
    echo -e "${BOLD}Create ZIVPN User${NC}\n"

    if ! systemctl is-active --quiet "$ZIVPN_SERVICE" 2>/dev/null; then
        error "ZIVPN service not running. Install first."
        pause; return
    fi

    read -p "Username/Phone: " USER_ID
    [[ -z "$USER_ID" ]] && { error "Username required"; pause; return; }
    read -p "Password: " PASS
    [[ -z "$PASS" ]] && { error "Password required"; pause; return; }
    read -p "Duration (days): " DAYS
    [[ ! "$DAYS" =~ ^[0-9]+$ ]] && { error "Invalid duration"; pause; return; }

    local EXPIRE TODAY TMP
    EXPIRE=$(date -d "+${DAYS} days" '+%Y-%m-%d')
    TODAY=$(date +%Y-%m-%d)
    TMP=$(mktemp)

    mkdir -p /etc/zivpn
    [[ -f "$ZIVPN_USER_FILE" ]] && awk -F'|' -v today="$TODAY" '$3>=today {print $0}' "$ZIVPN_USER_FILE" > "$TMP" 2>/dev/null || true
    grep -v "^$USER_ID|" "$TMP" > "${TMP}.2" 2>/dev/null || true
    echo "$USER_ID|$PASS|$EXPIRE" >> "${TMP}.2"
    mv "${TMP}.2" "$ZIVPN_USER_FILE"
    rm -f "$TMP"
    chmod 600 "$ZIVPN_USER_FILE"

    if zivpn_update_config_passwords; then
        local DOMAIN
        DOMAIN=$(cat "$ZIVPN_DOMAIN_FILE" 2>/dev/null || hostname -I | awk '{print $1}')
        echo -e "\n${GREEN}✅ ZIVPN USER CREATED${NC}"
        echo -e "━━━━━━━━━━━━━━━━━━━━━"
        echo -e "🌐 Server : $DOMAIN"
        echo -e "🔌 Port   : $ZIVPN_PORT"
        echo -e "🎭 Obfs   : zivpn"
        echo -e "🔐 Password: $PASS"
        echo -e "📅 Expires: $EXPIRE"
        echo -e "━━━━━━━━━━━━━━━━━━━━━"
    fi
    pause
}

zivpn_delete_user_panel() {
    banner
    echo -e "${BOLD}Delete ZIVPN User${NC}\n"
    if [[ ! -f "$ZIVPN_USER_FILE" || ! -s "$ZIVPN_USER_FILE" ]]; then
        error "No ZIVPN users"
        pause; return
    fi
    zivpn_cleanup_expired
    mapfile -t USERS < <(sort -t'|' -k3 "$ZIVPN_USER_FILE")
    if [[ ${#USERS[@]} -eq 0 ]]; then
        error "No active ZIVPN users"
        pause; return
    fi
    echo -e "Active users:"
    echo "────────────────────────────────────"
    for i in "${!USERS[@]}"; do
        local UNAME EXP
        UNAME=$(echo "${USERS[$i]}" | cut -d'|' -f1)
        EXP=$(echo "${USERS[$i]}" | cut -d'|' -f3)
        echo "$((i+1)). $UNAME | Expires: $EXP"
    done
    echo "────────────────────────────────────"
    read -p "Number to delete (1-${#USERS[@]}): " NUM
    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || (( NUM < 1 || NUM > ${#USERS[@]} )); then
        error "Invalid number"; pause; return
    fi
    local LINE USER_ID
    LINE="${USERS[$((NUM-1))]}"
    USER_ID=$(echo "$LINE" | cut -d'|' -f1 | tr -d '[:space:]')
    grep -v "^$USER_ID|" "$ZIVPN_USER_FILE" > "${ZIVPN_USER_FILE}.tmp" 2>/dev/null || true
    mv "${ZIVPN_USER_FILE}.tmp" "$ZIVPN_USER_FILE"
    chmod 600 "$ZIVPN_USER_FILE"
    zivpn_update_config_passwords
    msg "$USER_ID deleted"
    pause
}

# ──────────────────────────────────────────────
#  TUNNEL VPN Menu (Option 6)
# ──────────────────────────────────────────────

XRAY_DOMAIN_FILE="/etc/xray/domain"
XRAY_PATH="/vless-xhttp"
XRAY_UUID_DEFAULT="cfe75234-b0d9-477d-b30f-9d24654b2487"

xray_install() {
    banner
    echo -e "${BOLD}Install Xray Tunnel${NC}\n"

    apt-get install -y -qq unzip 2>/dev/null || true

    if ! command -v xray &>/dev/null || [[ "$(xray version 2>/dev/null | head -1 | awk '{print $2}')" != "25.12.8" ]]; then
        info "Downloading Xray-core v25.12.8..."
        local arch
        arch=$(uname -m)
        case "$arch" in
            x86_64|amd64) arch="64" ;;
            aarch64|arm64) arch="arm64-v8a" ;;
            *) error "Unsupported arch: $arch"; pause; return 1 ;;
        esac
        local tmpdir
        tmpdir=$(mktemp -d)
        curl -fsSL "https://github.com/XTLS/Xray-core/releases/download/v25.12.8/Xray-linux-${arch}.zip" -o "$tmpdir/xray.zip"
        unzip -qo "$tmpdir/xray.zip" -d "$tmpdir" xray
        cp "$tmpdir/xray" /usr/local/bin/xray
        chmod +x /usr/local/bin/xray
        rm -rf "$tmpdir"
        msg "Xray v25.12.8 installed"
    else
        msg "Xray v25.12.8 already installed"
    fi

    setcap cap_net_bind_service=+ep /usr/local/bin/xray 2>/dev/null || true

    mkdir -p /etc/xray

    local XRAY_DOMAIN
    while [[ -z "$XRAY_DOMAIN" ]]; do
        read -p "Domain for Xray (e.g. vps.example.com): " XRAY_DOMAIN
    done

    local ACME_EMAIL="adrienkiaje@gmail.com"
    if ! command -v acme.sh &>/dev/null; then
        info "Installing acme.sh for Let's Encrypt..."
        curl -fsSL https://get.acme.sh | sh -s email="$ACME_EMAIL" 2>&1
    fi
    export LE_WORKING_DIR="/root/.acme.sh"
    if [[ -f /root/.acme.sh/${XRAY_DOMAIN}_ecc/fullchain.cer ]]; then
        info "Using existing Let's Encrypt cert from acme.sh..."
        cp /root/.acme.sh/${XRAY_DOMAIN}_ecc/fullchain.cer /etc/xray/xray.crt
        cp /root/.acme.sh/${XRAY_DOMAIN}_ecc/${XRAY_DOMAIN}.key /etc/xray/xray.key
        msg "Let's Encrypt certificate copied"
    else
        info "Issuing Let's Encrypt certificate for $XRAY_DOMAIN..."
        ~/.acme.sh/acme.sh --issue --standalone -d "$XRAY_DOMAIN" --keylength ec-256 \
            --server letsencrypt --accountemail "$ACME_EMAIL" 2>&1
        if [[ -f /root/.acme.sh/${XRAY_DOMAIN}_ecc/fullchain.cer ]]; then
            cp /root/.acme.sh/${XRAY_DOMAIN}_ecc/fullchain.cer /etc/xray/xray.crt
            cp /root/.acme.sh/${XRAY_DOMAIN}_ecc/${XRAY_DOMAIN}.key /etc/xray/xray.key
            msg "Let's Encrypt certificate issued"
        else
            warn "Let's Encrypt failed, using self-signed certificate"
            openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                -keyout /etc/xray/xray.key -out /etc/xray/xray.crt \
                -subj "/CN=$XRAY_DOMAIN" -days 36500 2>/dev/null
        fi
    fi

    # Save domain for client configs
    echo "$XRAY_DOMAIN" > "$XRAY_DOMAIN_FILE"

    chmod 644 /etc/xray/xray.crt 2>/dev/null
    chmod 600 /etc/xray/xray.key 2>/dev/null

    # Write Xray config
    cat > /etc/xray/config.json << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$XRAY_UUID_DEFAULT"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{
            "certificateFile": "/etc/xray/xray.crt",
            "keyFile": "/etc/xray/xray.key"
          }]
        },
        "xhttpSettings": {
          "path": "$XRAY_PATH"
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked" }
    ]
  },
  "stats": {},
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  }
}
EOF
    msg "Xray config written"

    # Systemd service
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray -config /etc/xray/config.json
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray

    # Sync all user UUIDs from DB into Xray config
    if [[ -f "$DB_PATH" ]]; then
        xray_sync_uuids
    fi

    echo
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Xray installed on port 443${NC}"
    echo -e "${CYAN}  Protocol: VLESS + XHTTP + TLS${NC}"
    echo -e "${CYAN}  UUID: $XRAY_UUID_DEFAULT${NC}"
    echo -e "${CYAN}  Path: $XRAY_PATH${NC}"
    echo -e "${CYAN}  Domain: $XRAY_DOMAIN${NC}"
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    pause
}

xray_uninstall() {
    banner
    echo -e "${BOLD}Uninstall Xray Tunnel${NC}\n"
    if ! confirm "Remove Xray completely?"; then
        info "Cancelled"; pause; return
    fi

    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service
    systemctl daemon-reload

    rm -rf /etc/xray
    rm -f /usr/local/bin/xray
    msg "Xray removed"
    pause
}

xray_sync_uuids() {
    DB_PATH="$DB_PATH" XRAY_UUID_DEFAULT="$XRAY_UUID_DEFAULT" python3 << 'PYXRAY' 2>/dev/null || true
import json, sqlite3, os

db_path = os.environ.get('DB_PATH', '/opt/stivaros/stivaros.db')
default_uuid = os.environ.get('XRAY_UUID_DEFAULT', 'cfe75234-b0d9-477d-b30f-9d24654b2487')

uuids = []
try:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("""
        SELECT DISTINCT v.xray_uuid FROM vpn_configs v
        JOIN users u ON v.user_id = u.id
        WHERE u.active = 1 AND (u.expires_at IS NULL OR u.expires_at >= DATE('now'))
    """)
    uuids = [row[0] for row in cur.fetchall() if row[0]]
    conn.close()
except Exception:
    pass

if default_uuid not in uuids:
    uuids.insert(0, default_uuid)

with open('/etc/xray/config.json') as f:
    config = json.load(f)
config['inbounds'][0]['settings']['clients'] = [{'id': uid} for uid in uuids]
with open('/etc/xray/config.json', 'w') as f:
    json.dump(config, f, indent=2)
PYXRAY
    systemctl restart xray
    msg "Xray config synced with $(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT xray_uuid) FROM vpn_configs" 2>/dev/null || echo 0)+1 UUIDs"
}

xray_tunnel_menu() {
    while true; do
        banner
        echo -e "${CYAN}  ╔══════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}  ║${NC}          ${BOLD}XRAY TUNNEL PANEL${NC}            ${CYAN}║${NC}"
        echo -e "${CYAN}  ║${NC}       VLESS + XHTTP + TLS (Port 443)     ${CYAN}║${NC}"
        echo -e "${CYAN}  ╚══════════════════════════════════════════╝${NC}"
        echo
        echo -e "  ${CYAN}1${NC})  Install Xray"
        echo -e "  ${CYAN}2${NC})  View Xray status"
        echo -e "  ${CYAN}3${NC})  Restart Xray"
        echo -e "  ${CYAN}4${NC})  Uninstall Xray"
        echo
        echo -e "  ${YELLOW}0${NC})  Back to TUNNEL VPN menu"
        echo
        read -p "Select an option [0-4]: " choice

        case "$choice" in
            1) xray_install ;;
            2) systemctl status xray --no-pager 2>&1 | head -20; pause ;;
            3) systemctl restart xray; msg "Xray restarted"; pause ;;
            4) xray_uninstall ;;
            0) return ;;
            *) warn "Invalid option" ;;
        esac
    done
}

zivpn_udp_menu() {
    while true; do
        banner
        echo -e "${CYAN}  ╔══════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}  ║${NC}          ${BOLD}ZIVPN UDP PANEL${NC}               ${CYAN}║${NC}"
        echo -e "${CYAN}  ║${NC}       Camtel UDP Tunnel (Port $ZIVPN_PORT)      ${CYAN}║${NC}"
        echo -e "${CYAN}  ╚══════════════════════════════════════════╝${NC}"
        echo
        echo -e "  ${CYAN}1${NC})  Install ZIVPN UDP"
        echo -e "  ${CYAN}2${NC})  View ZIVPN status"
        echo -e "  ${CYAN}3${NC})  Restart ZIVPN"
        echo -e "  ${CYAN}4${NC})  Uninstall ZIVPN"
        echo
        echo -e "  ${YELLOW}0${NC})  Back to TUNNEL VPN menu"
        echo
        read -p "Select an option [0-4]: " choice

        case "$choice" in
            1) zivpn_install ;;
            2) systemctl status "$ZIVPN_SERVICE" --no-pager 2>&1 | head -20; pause ;;
            3) systemctl restart "$ZIVPN_SERVICE"; msg "ZIVPN restarted"; pause ;;
            4) zivpn_uninstall ;;
            0) return ;;
            *) warn "Invalid option" ;;
        esac
    done
}

tunnel_menu() {
    while true; do
        banner
        echo -e "${BOLD}TUNNEL VPN${NC}\n"
        echo -e "  ${CYAN}1${NC})  Xray Tunnel (VLESS + XHTTP + TLS)"
        echo -e "  ${CYAN}2${NC})  ZIVPN UDP (Camtel UDP Tunnel)"
        echo
        echo -e "  ${YELLOW}0${NC})  Back to main menu"
        echo
        read -p "Select an option [0-2]: " choice

        case "$choice" in
            1) xray_tunnel_menu ;;
            2) zivpn_udp_menu ;;
            0) return ;;
            *) warn "Invalid option" ;;
        esac
    done
}

# ──────────────────────────────────────────────
#  Main Menu
# ──────────────────────────────────────────────

menu() {
    while true; do
        banner
        echo -e "${BOLD}Main Menu${NC}\n"
        echo -e "  ${CYAN}1${NC})  Install Stivaros (full setup)"
        echo -e "  ${CYAN}2${NC})  Create User"
        echo -e "  ${CYAN}3${NC})  List All Users"
        echo -e "  ${CYAN}4${NC})  Delete User(s)"
        echo -e "  ${CYAN}5${NC})  Uninstall (complete)"
        echo -e "  ${CYAN}6${NC})  TUNNEL VPN (Xray / ZIVPN)"
        echo
        echo -e "  ${YELLOW}0${NC})  Exit"
        echo
        read -p "Select an option [0-6]: " choice

        case "$choice" in
            1) install_all ;;
            2) create_user ;;
            3) list_users ;;
            4) delete_users ;;
            5) uninstall_all ;;
            6) tunnel_menu ;;
            0) echo -e "\n${GREEN}Goodbye!${NC}"; exit 0 ;;
            *) warn "Invalid option" ;;
        esac
    done
}

# ──────────────────────────────────────────────
#  Entry Point
# ──────────────────────────────────────────────

check_root
menu
