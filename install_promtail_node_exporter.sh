#!/bin/bash

set -e

# === Usage check ===
if [ -z "$1" ]; then
  echo "Usage: $0 <LOKI_SERVER_IP>"
  exit 1
fi

LOKI_IP="$1"
INSTALL_DIR="/etc/promtail"
PROMTAIL_CONFIG="$INSTALL_DIR/promtail-config.yaml"
NODE_EXPORTER_VERSION="1.8.0"
PROMTAIL_VERSION="3.4.4"

echo "[INFO] Installing Promtail and Node Exporter"
echo "[INFO] Loki Server IP: $LOKI_IP"

# === Detect package manager (dnf or yum) ===
PKG_MGR=""
if command -v dnf &> /dev/null; then
  PKG_MGR="dnf"
elif command -v yum &> /dev/null; then
  PKG_MGR="yum"
else
  echo "[ERROR] Neither dnf nor yum found. Exiting."
  exit 1
fi

# === Install missing tools ===
echo "[INFO] Installing curl and unzip if missing..."
sudo $PKG_MGR install -y curl unzip --disablerepo=pgdg\*

# === Create install directory ===
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER":"$USER" "$INSTALL_DIR"

cd "$INSTALL_DIR"

# === Download Node Exporter ===
echo "[INFO] Downloading Node Exporter v$NODE_EXPORTER_VERSION..."
sudo wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
sudo tar -xzf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
echo "[INFO] Stopping Node Exporter if running to avoid file lock..."

sudo systemctl stop node_exporter || true

sudo cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"*

# === Download Promtail ===
echo "[INFO] Downloading Promtail v$PROMTAIL_VERSION..."
sudo wget "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip"
sudo unzip promtail-linux-amd64.zip
sudo chmod +x promtail-linux-amd64
sudo mv promtail-linux-amd64 /usr/local/bin/promtail
rm promtail-linux-amd64.zip

# === Create Promtail config ===
echo "[INFO] Creating Promtail config..."
cat <<EOF > "$PROMTAIL_CONFIG"
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: $INSTALL_DIR/positions.yaml

clients:
  - url: "http://${LOKI_IP}:3100/loki/api/v1/push"

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          host: $(hostname)
          __path__: /var/log/*log
EOF

# === Create systemd service for Promtail ===
echo "[INFO] Creating Promtail systemd service..."
sudo tee /etc/systemd/system/promtail.service > /dev/null <<EOF
[Unit]
Description=Promtail service for Loki
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/promtail -config.file=$PROMTAIL_CONFIG
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# === Create systemd service for Node Exporter ===
echo "[INFO] Creating Node Exporter systemd service..."
sudo tee /etc/systemd/system/node_exporter.service > /dev/null <<EOF
[Unit]
Description=Node Exporter for Prometheus
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# === Reload systemd and start services ===
echo "[INFO] Enabling and starting services..."
sudo systemctl daemon-reload
sudo systemctl enable --now promtail
sudo systemctl enable --now node_exporter

echo "[DONE] Promtail and Node Exporter installed and running!"
