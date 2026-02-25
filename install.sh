#!/bin/bash
# ==========================================
# Master Installer MasD Tunneling
# OS Support: Debian 12
# ==========================================

clear
echo "=========================================="
echo "   Setup Autoscript Tunneling MasD        "
echo "=========================================="
# Meminta input domain dan email di awal agar script bisa jalan otomatis setelahnya
read -p "Masukkan Domain aktif Anda (contoh: myvpn.com): " domain
read -p "Masukkan Email Anda (untuk daftar SSL Acme): " email

echo ""
echo "Memulai instalasi dalam 3 detik..."
sleep 3

# 1. Update & Install Basic Tools
apt update -y && DEBIAN_FRONTEND=noninteractive apt upgrade -y
DEBIAN_FRONTEND=noninteractive apt install -y screen curl wget python3 python3-pip nginx haproxy dropbear socat cron systemd

# 2. Setup Dropbear (Port 109 & 143)
echo "[INFO] Mengkonfigurasi Dropbear..."
sed -i 's/NO_START=1/NO_START=0/g' /etc/default/dropbear
sed -i 's/DROPBEAR_PORT=22/DROPBEAR_PORT=143/g' /etc/default/dropbear
sed -i 's/DROPBEAR_EXTRA_ARGS=.*/DROPBEAR_EXTRA_ARGS="-p 109"/g' /etc/default/dropbear
systemctl restart dropbear
systemctl enable dropbear

# 3. Setup Python WS (Backend)
echo "[INFO] Mengkonfigurasi Python Websocket..."
cat <<EOF > /usr/local/bin/ws-python.py
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

# Membuat Service agar Python WS jalan 24/7 otomatis
cat <<EOF > /etc/systemd/system/ws-python.service
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
systemctl stop nginx
systemctl stop haproxy

curl https://get.acme.sh | sh -s email=$email
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d $domain --standalone --force

# Buat folder cert untuk HAProxy dan gabungkan file crt + key menjadi .pem
mkdir -p /etc/haproxy/certs/
~/.acme.sh/acme.sh --install-cert -d $domain \
--fullchain-file /etc/haproxy/certs/$domain.crt \
--key-file /etc/haproxy/certs/$domain.key

cat /etc/haproxy/certs/$domain.crt /etc/haproxy/certs/$domain.key > /etc/haproxy/certs/$domain.pem

# 5. Konfigurasi HAProxy
echo "[INFO] Mengkonfigurasi HAProxy..."
cat <<EOF > /etc/haproxy/haproxy.cfg
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
    
    # Deteksi Websocket, jika ya lempar ke backend python WS
    acl is_websocket hdr(Upgrade) -i websocket
    use_backend ws-backend if is_websocket
    
    default_backend ws-backend

backend ws-backend
    mode http
    server ws-server 127.0.0.1:2082 check
EOF

systemctl restart haproxy
systemctl enable haproxy

cat << 'EOF' > /usr/local/bin/menu
#!/bin/bash
# ==========================================
# Menu Manajemen MasD Tunneling
# ==========================================

# Warna untuk tampilan terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}==========================================${NC}"
echo -e "${GREEN}        PANEL MANAJEMEN TUNNELING         ${NC}"
echo -e "${BLUE}==========================================${NC}"
echo -e " 1. Buat Akun SSH/Websocket"
echo -e " 2. Hapus Akun"
echo -e " 3. Perpanjang Masa Aktif Akun"
echo -e " 4. Cek Akun yang Sedang Login"
echo -e " 5. Lihat Daftar Semua Akun"
echo -e " 6. Restart Semua Service (Websocket, SSH, HAProxy)"
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

        # Menghitung tanggal expired
        expdate=$(date -d "+$aktif days" +"%Y-%m-%d")
        
        # Membuat user tanpa akses shell penuh (demi keamanan)
        useradd -e $expdate -s /bin/false -M $user
        echo -e "$pass\n$pass" | passwd $user &> /dev/null
        
        clear
        echo -e "${GREEN}Akun Berhasil Dibuat!${NC}"
        echo -e "=========================="
        echo -e "Username   : $user"
        echo -e "Password   : $pass"
        echo -e "Expired    : $expdate"
        echo -e "=========================="
        echo -e "Format Payload Websocket:"
        echo -e "GET / HTTP/1.1[crlf]Host: [domainmu][crlf]Connection: Upgrade[crlf]User-Agent: [ua][crlf]Upgrade: websocket[crlf][crlf]"
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
        
        # Mengubah tanggal expired user
        expdate=$(date -d "+$aktif days" +"%Y-%m-%d")
        chage -E $expdate $user
        echo -e "${GREEN}Masa aktif $user berhasil diperpanjang hingga $expdate.${NC}"
        ;;
    4)
        clear
        echo -e "${BLUE}--- Cek User Login (Dropbear) ---${NC}"
        # Membaca log dropbear untuk melihat siapa yang terhubung
        cat /var/log/auth.log | grep -i dropbear | grep -i "Password auth succeeded" > /tmp/login-db.txt
        echo -e "Daftar koneksi terakhir:"
        cat /tmp/login-db.txt | awk '{print $1,$2,$3,$10}' | tail -n 10
        echo -e "\n(Catatan: IP asli mungkin tersembunyi di balik HAProxy/Cloudflare)"
        ;;
    5)
        clear
        echo -e "${YELLOW}--- Daftar Semua Akun ---${NC}"
        # Menampilkan user yang memiliki masa aktif
        awk -F: '$3>=1000 {print $1}' /etc/passwd | while read user; do
            exp=$(chage -l $user | grep "Account expires" | awk -F": " '{print $2}')
            echo -e "Username: $user | Expired: $exp"
        done
        ;;
    6)
        clear
        echo -e "${GREEN}Merestart Service...${NC}"
        systemctl restart dropbear
        systemctl restart ws-python
        systemctl restart haproxy
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
echo " Port HTTPS  : 443 (Websocket SSL)"
echo " Port SSH    : 143, 109"
echo " Websocket   : 2082 (Internal)"
echo "=========================================="
echo "Ketik 'reboot' lalu tekan enter untuk memulai ulang VPS."
    