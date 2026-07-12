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
API_PORT=8080

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
            xray_uuid TEXT DEFAULT '6e3b3083-f69d-4c98-a6d8-a8134a6d99f6',
            FOREIGN KEY(user_id) REFERENCES users(id)
        );
        CREATE INDEX IF NOT EXISTS idx_vpn_configs_user_isp_tier ON vpn_configs(user_id, isp, tier);
    """)
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
                return self._send({
                    "success": True,
                    "isp": isp,
                    "mode": mode,
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
                    "xray_uuid": cfg["xray_uuid"] or "6e3b3083-f69d-4c98-a6d8-a8134a6d99f6"
                })
            return self._send({"success": False, "message": "No config available"}, 404)

        elif path.startswith("/api/v1/config/") and path != "/api/v1/config/auto":
            uuid = path.split("/")[-1]
            code = self.headers.get("X-Activation-Code", "")
            user = self._get_user_by_uuid(uuid)
            if not user or not user["active"]:
                return self._send({"success": False, "message": "User not found or inactive"}, 404)
            if user["activation_code"] != code:
                return self._send({"success": False, "message": "Invalid activation code"}, 403)
            conn = get_db()
            cfg = conn.execute(
                "SELECT * FROM vpn_configs WHERE user_id = ?", (user["id"],)
            ).fetchone()
            conn.close()
            if cfg:
                return self._send({
                    "success": True,
                    "address": cfg["server_address"],
                    "port": cfg["server_port"],
                    "protocol": cfg["protocol"],
                    "transport": cfg["transport"],
                    "tls": bool(cfg["tls"]),
                    "sni": cfg["sni"] or cfg["server_address"],
                    "public_key": cfg["public_key"] or "",
                    "short_id": cfg["short_id"] or ""
                })
            return self._send({"success": False, "message": "No config assigned"}, 404)

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
                return self._send({"success": False, "message": "Device not registered. Contact admin."}, 404)
            if user["activation_code"] != code:
                return self._send({"success": False, "message": "Invalid activation code"}, 403)
            if user["phone"] != phone:
                return self._send({"success": False, "message": "Phone number does not match"}, 403)
            if not user["active"]:
                return self._send({"success": False, "message": "Device is disabled"}, 403)

            exp = user["expires_at"]
            if exp and datetime.fromisoformat(exp) < datetime.now():
                return self._send({"success": False, "message": "Subscription expired"}, 403)

            conn.execute(
                "UPDATE users SET device_install_id=?, hardware_id=?, app_version=? WHERE uuid=?",
                (uuid, hwid, body.get("app_version", ""), uuid)
            )
            conn.commit()

            cfg = conn.execute(
                "SELECT * FROM vpn_configs WHERE user_id = ?", (user["id"],)
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
    read -p "Xray UUID [default: 6e3b3083-f69d-4c98-a6d8-a8134a6d99f6]: " xray_uuid
    xray_uuid=${xray_uuid:-6e3b3083-f69d-4c98-a6d8-a8134a6d99f6}

    # Add name column if not exists (migration)
    sqlite3 "$DB_PATH" "ALTER TABLE users ADD COLUMN name TEXT DEFAULT '';" 2>/dev/null || true

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
EOF

    echo
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    echo "  ✅ Customer created!"
    echo
    echo "  • Name: $name"
    echo "  • Number: $phone"
    echo "  • UUID: $uuid"
    echo "  • Activation code: $code"
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
#  TUNNEL VPN Menu (Option 6)
# ──────────────────────────────────────────────

XRAY_DOMAIN="kiaje2.kingom.ggff.net"
XRAY_PATH="/vless-xhttp"
XRAY_UUID="6e3b3083-f69d-4c98-a6d8-a8134a6d99f6"

xray_install() {
    banner
    echo -e "${BOLD}Install Xray Tunnel${NC}\n"

    if ! command -v xray &>/dev/null; then
        info "Downloading Xray-core v25.12.8..."
        bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) --version v25.12.8 2>&1
        msg "Xray v25.12.8 installed"
    else
        current=$(xray version 2>/dev/null | head -1 | awk '{print $2}')
        if [[ "$current" != "25.12.8" ]]; then
            info "Upgrading Xray from $current to v25.12.8..."
            bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) --version v25.12.8 2>&1
            msg "Xray upgraded to v25.12.8"
        else
            msg "Xray v25.12.8 already installed"
        fi
    fi

    setcap cap_net_bind_service=+ep /usr/local/bin/xray 2>/dev/null || true

    mkdir -p /etc/xray

    # Use existing LE cert from acme.sh if available, else generate self-signed
    if [[ -f /root/.acme.sh/$XRAY_DOMAIN\_ecc/fullchain.cer ]]; then
        info "Using Let's Encrypt cert from acme.sh..."
        cp /root/.acme.sh/$XRAY_DOMAIN\_ecc/fullchain.cer /etc/xray/xray.crt
        cp /root/.acme.sh/$XRAY_DOMAIN\_ecc/$XRAY_DOMAIN.key /etc/xray/xray.key
        msg "Let's Encrypt certificate copied"
    elif [[ ! -f /etc/xray/xray.key ]]; then
        info "Generating self-signed TLS certificate for $XRAY_DOMAIN..."
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout /etc/xray/xray.key -out /etc/xray/xray.crt \
            -subj "/CN=$XRAY_DOMAIN" -days 36500 2>/dev/null
        msg "Self-signed TLS certificate generated"
    fi

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
        "clients": [{"id": "$XRAY_UUID"}],
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

    echo
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    echo -e "${GREEN}  Xray installed on port 443${NC}"
    echo -e "${CYAN}  Protocol: VLESS + XHTTP + TLS${NC}"
    echo -e "${CYAN}  UUID: $XRAY_UUID${NC}"
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

tunnel_menu() {
    while true; do
        banner
        echo -e "${BOLD}TUNNEL VPN - Xray Management${NC}\n"
        echo -e "  ${CYAN}1${NC})  Install Xray (VLESS + XHTTP + TLS on port 443)"
        echo -e "  ${CYAN}2${NC})  View Xray status"
        echo -e "  ${CYAN}3${NC})  Restart Xray"
        echo -e "  ${CYAN}4${NC})  Uninstall Xray"
        echo
        echo -e "  ${YELLOW}0${NC})  Back to main menu"
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
        echo -e "  ${CYAN}6${NC})  TUNNEL VPN (Xray management)"
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
