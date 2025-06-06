#!/bin/bash

# install-web.sh - VM startup script for web server installation
# This script runs automatically when the VM instance starts

# Update system packages
apt-get update
apt-get upgrade -y

# Install necessary packages
apt-get install -y \
    nginx \
    python3 \
    python3-pip \
    nodejs \
    npm \
    git \
    curl \
    wget \
    unzip

# Install Docker (optional)
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker $USER

# Configure nginx
systemctl enable nginx
systemctl start nginx

# Create a simple index page
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to VM Instance</title>
</head>
<body>
    <h1>VM Instance is Running!</h1>
    <p>Server started at: $(date)</p>
    <p>Hostname: $(hostname)</p>
</body>
</html>
EOF

# Install Python packages (example)
pip3 install flask gunicorn requests pandas

# Install Node.js packages globally (example)
npm install -g pm2 express

# Set up logging
mkdir -p /var/log/startup
echo "$(date): Startup script completed successfully" >> /var/log/startup/install.log

# Create a simple Flask app (example)
mkdir -p /opt/webapp
cat > /opt/webapp/app.py << EOF
from flask import Flask
import os

app = Flask(__name__)

@app.route('/')
def hello():
    return f"<h1>Flask App Running!</h1><p>Server: {os.uname().nodename}</p>"

@app.route('/health')
def health():
    return {"status": "healthy", "server": os.uname().nodename}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF

# Create systemd service for Flask app (optional)
cat > /etc/systemd/system/webapp.service << EOF
[Unit]
Description=Flask Web Application
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/webapp
ExecStart=/usr/bin/python3 /opt/webapp/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the Flask service
systemctl enable webapp.service
systemctl start webapp.service

# Configure firewall (if ufw is available)
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp   # SSH
    ufw allow 80/tcp   # HTTP
    ufw allow 443/tcp  # HTTPS
    ufw allow 5000/tcp # Flask app
    ufw --force enable
fi

# Final status
echo "$(date): Web server installation completed" >> /var/log/startup/install.log