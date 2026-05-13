#!/bin/bash
# Run from ~/slowreverb

# Get the current user and home directory
USER=$(whoami)
HOME_DIR=$(eval echo ~$USER)

echo "Setting up services for user: $USER at $HOME_DIR"

# Build the API first
cd $HOME_DIR/slowreverb/apps/api
go build -o api ./cmd/api
echo "✅ API binary built"

# Build the Next.js app
cd $HOME_DIR/slowreverb/apps/web
npm run build
echo "✅ Next.js built"

# Create systemd service for Go API
sudo tee /etc/systemd/system/slowreverb-api.service > /dev/null << EOF
[Unit]
Description=SlowReverb Go API
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME_DIR/slowreverb/apps/api
Environment=PORT=8081
Environment=ALLOWED_ORIGIN=http://localhost:3001
Environment=DATABASE_URL=postgres://slowreverb:slowreverb_dev@localhost/slowreverb?sslmode=disable
Environment=WORK_DIR=/tmp/slowreverb
ExecStart=$HOME_DIR/slowreverb/apps/api/api
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create systemd service for Next.js
sudo tee /etc/systemd/system/slowreverb-web.service > /dev/null << EOF
[Unit]
Description=SlowReverb Next.js Frontend
After=network.target slowreverb-api.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME_DIR/slowreverb/apps/web
Environment=NODE_ENV=production
Environment=PORT=3001
Environment=NEXT_PUBLIC_API_URL=http://localhost:8081
ExecStart=/usr/bin/node_modules/.bin/next start -p 3001
ExecStart=$(which node) node_modules/.bin/next start -p 3001
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Fix the ExecStart for next (remove duplicate)
sudo tee /etc/systemd/system/slowreverb-web.service > /dev/null << EOF
[Unit]
Description=SlowReverb Next.js Frontend
After=network.target slowreverb-api.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME_DIR/slowreverb/apps/web
Environment=NODE_ENV=production
Environment=PORT=3001
Environment=NEXT_PUBLIC_API_URL=http://localhost:8081
ExecStart=$(which node) $HOME_DIR/slowreverb/apps/web/node_modules/.bin/next start -p 3001
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable slowreverb-api slowreverb-web
echo "✅ Services enabled"

echo ""
echo "To start now:     sudo systemctl start slowreverb-api slowreverb-web"
echo "To check status:  sudo systemctl status slowreverb-api slowreverb-web"
echo "To view logs:     journalctl -u slowreverb-api -f"
