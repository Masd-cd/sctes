#!/bin/bash
# ==========================================
# Master Installer MasD Tunneling (FINAL)
# OS Support: Debian 12
# Core: Dropbear 2019, Nginx, HAProxy, Python WS
# ==========================================

clear
echo "=========================================="
echo "   Setup Autoscript Tunneling MasD        "
echo "=========================================="
read -p "Masukkan Domain aktif Anda (contoh: myvpn.com): " domain
read -p "Masukkan Email Anda (untuk daftar SSL Acme): " email

echo ""
echo "Memulai instalasi dalam 3 detik..."
sleep 3

# 1. Update & Install Basic Tools (Senyap)
apt update -y
DEBIAN_FRONTEND=noninteractive apt upgrade -y
DEBIAN_FRONTEND=noninteractive apt install -y screen curl wget python3 python3-pip nginx haproxy socat cron systemd build-essential zlib1g-dev bzip2 dos2unix

# Mendaftarkan /bin/false agar user VPN diizinkan login
if ! grep -q "/bin/false" /etc/shells; then
    echo "/bin/false" >> /etc/shells
fi

# 2. Hapus Dropbear bawaan & Rakit Dropbear 2019 secara manual
echo "[INFO] Menginstal Dropbear 2019..."
systemctl stop dropbear &>/dev/null
apt purge dropbear -y &>/dev/null

cd /tmp
wget -q https://matt.ucc.asn.au/dropbear/releases/dropbear-2019.78.tar.bz2
tar -xvjf dropbear-2019.78.tar.bz2
cd dropbear-2019.78
./configure
make
make install

# Membuat Kunci Keamanan Dropbear agar tidak crash
mkdir -p /etc/dropbear
dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key
dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key

# Membuat Service Dropbear di Port 143 & 109
cat << 'EOF' > /etc/systemd/system/dropbear.service
[Unit]
Description=Dropbear SSH 2019 MasD
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/dropbear -EF -p 143 -W 65536 -p 109
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dropbear
systemctl start dropbear

# 3. Setup Python WS (Backend di Port 2082)
echo "[INFO] Mengkonfigurasi Python Websocket..."
cat << 'EOF' > /usr/local/bin/ws-python.py
import socket, threading, select, sys

def proxy(client, target):
    while True:
        r, w, e = select.select([client, target], [], [])
        if client in r:
            data = client.recv(4096)
            if not data: break
            target.send(data)
        if target in r:
            data = target.recv(4096)
            if not data: break
            client.send(data)
    client.close()
    target.close()

def handle_client(client_socket):
    try:
        data = client_socket.recv(1024).decode('utf-8', errors='ignore')
        if "Upgrade: websocket" in data or "Upgrade: Websocket" in data:
            target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            target.connect(('127.0.0.1', 143)) # Connect ke port Dropbear
            client_socket.send(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            proxy(client_socket, target)
        else:
            client_socket.close()
    except:
        client_socket.close()

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', 2082))
server.listen(100)
while True:
    client, addr = server.accept()
    threading.Thread(target=handle_client, args=(client,)).start()
EOF
chmod +x /usr/local/bin/ws-python.py

cat << 'EOF' > /etc/systemd/system/ws-python.service
[Unit]
Description=Python Websocket Proxy MasD
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ws-python.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ws-python
systemctl start ws-python

# 4. Install Acme.sh & Certificate
echo "[INFO] Memproses Sertifikat SSL..."
# Matikan Nginx & HAProxy agar port 80 kosong untuk validasi Acme
systemctl stop nginx
systemctl stop haproxy

curl https://get.acme.sh | sh -s email=$email
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d $domain --standalone --force

mkdir -p /etc/haproxy/certs/
~/.acme.sh/acme.sh --install-cert -d $domain \
--fullchain-file /etc/haproxy/certs/$domain.crt \
--key-file /etc/haproxy/certs/$domain.key

cat /etc/haproxy/certs/$domain.crt /etc/haproxy/certs/$domain.key > /etc/haproxy/certs/$domain.pem

# 5. Konfigurasi Nginx (Port 80 HTTP Proxy to WS)
echo "[INFO] Mengkonfigurasi Nginx Port 80..."
rm -f /etc/nginx/sites-enabled/default
cat << 'EOF' > /etc/nginx/conf.d/websocket.conf
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:2082;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;
    }
}
EOF
systemctl restart nginx
systemctl enable nginx

# 6. Konfigurasi HAProxy (Port 443 HTTPS Proxy to WS)
echo "[INFO] Mengkonfigurasi HAProxy Port 443..."
cat << EOF > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend https-in
    bind *:443 ssl crt /etc/haproxy/certs/$domain.pem
    mode http
    acl is_websocket hdr(Upgrade) -i websocket
    use_backend ws-backend if is_websocket
    default_backend ws-backend

backend ws-backend
    mode http
    server ws-server 127.0.0.1:2082 check
EOF
systemctl restart haproxy
systemctl enable haproxy

# 7. Menginstal Menu Manajemen
echo "[INFO] Menginstal Menu Manajemen..."
cat << 'EOF' > /usr/local/bin/menu
#!/bin/bash
# ==========================================
# Menu Manajemen MasD Tunneling
# ==========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo -e "${BLUE}==========================================${NC}"
echo -e "${GREEN}        PANEL MANAJEMEN TUNNELING         ${NC}"
echo -e "${BLUE}==========================================${NC}"
echo -e " 1. Buat Akun SSH/Websocket"
echo -e " 2. Hapus Akun"
echo -e " 3. Perpanjang Masa Aktif Akun"
echo -e " 4. Cek Akun yang Sedang Login"
echo -e " 5. Lihat Daftar Semua Akun"
echo -e " 6. Restart Semua Service"
echo -e " 0. Keluar"
echo -e "${BLUE}==========================================${NC}"
read -p "Pilih menu [0-6]: " menu

case $menu in
    1)
        clear
        echo -e "${GREEN}--- Buat Akun Baru ---${NC}"
        read -p "Masukkan Username : " user
        read -p "Masukkan Password : " pass
        read -p "Masa Aktif (hari) : " aktif
        expdate=$(date -d "+$aktif days" +"%Y-%m-%d")
        useradd -e $expdate -s /bin/false -M $user
        echo "$user:$pass" | chpasswd
        clear
        echo -e "${GREEN}Akun Berhasil Dibuat!${NC}"
        echo -e "=========================="
        echo -e "Username   : $user"
        echo -e "Password   : $pass"
        echo -e "Expired    : $expdate"
        echo -e "=========================="
        ;;
    2)
        clear
        echo -e "${RED}--- Hapus Akun ---${NC}"
        read -p "Masukkan Username yang akan dihapus: " user
        userdel -f $user &> /dev/null
        echo -e "${GREEN}Akun $user berhasil dihapus.${NC}"
        ;;
    3)
        clear
        echo -e "${YELLOW}--- Perpanjang Masa Aktif ---${NC}"
        read -p "Masukkan Username: " user
        read -p "Tambahan Aktif (hari): " aktif
        expdate=$(date -d "+$aktif days" +"%Y-%m-%d")
        chage -E $expdate $user
        echo -e "${GREEN}Masa aktif $user berhasil diperpanjang hingga $expdate.${NC}"
        ;;
    4)
        clear
        echo -e "${BLUE}--- Cek User Login (Dropbear) ---${NC}"
        cat /var/log/auth.log | grep -i dropbear | grep -i "Password auth succeeded" > /tmp/login-db.txt
        echo -e "Daftar koneksi terakhir:"
        cat /tmp/login-db.txt | awk '{print $1,$2,$3,$10}' | tail -n 10
        ;;
    5)
        clear
        echo -e "${YELLOW}--- Daftar Semua Akun ---${NC}"
        awk -F: '$3>=1000 {print $1}' /etc/passwd | while read user; do
            exp=$(chage -l $user | grep "Account expires" | awk -F": " '{print $2}')
            echo -e "Username: $user | Expired: $exp"
        done
        ;;
    6)
        clear
        echo -e "${GREEN}Merestart Service...${NC}"
        systemctl restart dropbear ws-python haproxy nginx
        echo -e "${GREEN}Service berhasil direstart!${NC}"
        ;;
    0)
        clear
        exit 0
        ;;
    *)
        echo -e "${RED}Pilihan tidak valid!${NC}"
        ;;
esac
EOF
chmod +x /usr/local/bin/menu

echo "=========================================="
echo " Instalasi Selesai!                       "
echo "=========================================="
echo " Domain      : $domain"
echo " Port HTTPS  : 443 (Websocket SSL via HAProxy)"
echo " Port HTTP   : 80 (Websocket via Nginx)"
echo " Port SSH    : 143, 109 (Dropbear 2019)"
echo " Websocket   : 2082 (Internal Python)"
echo "=========================================="
echo "Ketik 'menu' untuk mengatur user VPS Anda."
echo "Ketik 'reboot' lalu tekan enter untuk memulai ulang VPS."
