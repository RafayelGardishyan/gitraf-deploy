#!/bin/bash
#
# gitraf deployment script
# https://github.com/RafayelGardishyan/gitraf-deploy
#
# A lightweight, self-hosted git server - free from corporations
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Configuration (set by user input)
TIER=3
ACCESS_MODEL="hybrid"
DOMAIN=""
TAILNET_URL=""
EMAIL=""

# Paths
OGIT_DIR="/opt/ogit"
GITRAF_SERVER_DIR="/opt/gitraf-server"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Binary URLs
GITRAF_SERVER_URL="https://git.rafayel.dev/releases/gitraf-server-linux-amd64"
GITRAF_CLI_URL="https://git.rafayel.dev/releases/gitraf-linux-amd64"

print_banner() {
    clear
    echo -e "${BLUE}"
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │                                                                 │"
    echo "  │   ${BOLD}GITRAF DEPLOYMENT SCRIPT${NC}${BLUE}                                     │"
    echo "  │                                                                 │"
    echo "  │   A lightweight, self-hosted git server                         │"
    echo "  │   Free from corporations. Simple. Fast.                         │"
    echo "  │                                                                 │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo -e "${NC}"
    echo ""
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo "  Run: sudo bash deploy.sh"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS. This script supports Ubuntu/Debian."
        exit 1
    fi

    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        log_warn "This script is designed for Ubuntu/Debian. Your OS: $ID"
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    log_success "OS: $PRETTY_NAME"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check for required commands
    local missing=""
    for cmd in curl git; do
        if ! command -v $cmd &> /dev/null; then
            missing="$missing $cmd"
        fi
    done

    if [[ -n "$missing" ]]; then
        log_info "Installing missing packages:$missing"
        apt-get update -qq
        apt-get install -y -qq curl git
    fi

    log_success "Prerequisites installed"
}

select_components() {
    echo ""
    echo -e "${CYAN}Select components to install:${NC}"
    echo ""
    echo "  [1] ${BOLD}Core${NC} (ogit + gitraf CLI)"
    echo "      - Git repository hosting via SSH"
    echo "      - Command-line management tool"
    echo "      - Requires: Tailscale"
    echo ""
    echo "  [2] ${BOLD}Core + Web Interface${NC}"
    echo "      - Everything in (1) plus:"
    echo "      - Web-based repository browser"
    echo "      - Git LFS support"
    echo ""
    echo "  [3] ${BOLD}Full Stack${NC} (recommended)"
    echo "      - Everything in (2) plus:"
    echo "      - Static site hosting ({repo}.yourdomain.com)"
    echo "      - Build support (npm, etc.)"
    echo ""

    while true; do
        read -p "Enter choice [1-3] (default: 3): " choice
        choice=${choice:-3}
        if [[ "$choice" =~ ^[1-3]$ ]]; then
            TIER=$choice
            break
        fi
        echo "Invalid choice. Please enter 1, 2, or 3."
    done

    log_success "Selected: Tier $TIER"
}

select_access_model() {
    echo ""
    echo -e "${CYAN}Select access model:${NC}"
    echo ""
    echo "  [1] ${BOLD}Tailnet-only${NC} (private)"
    echo "      - SSH access via Tailscale only"
    echo "      - No public internet exposure"
    echo "      - Most secure"
    echo ""
    echo "  [2] ${BOLD}Public${NC} (read-only)"
    echo "      - HTTPS for public repo access"
    echo "      - No Tailscale required for viewing"
    echo "      - Push requires authorized SSH keys"
    echo ""
    echo "  [3] ${BOLD}Hybrid${NC} (recommended)"
    echo "      - Public HTTPS for reading public repos"
    echo "      - SSH via Tailscale for full access"
    echo "      - Best of both worlds"
    echo ""

    while true; do
        read -p "Enter choice [1-3] (default: 3): " choice
        choice=${choice:-3}
        case "$choice" in
            1) ACCESS_MODEL="tailnet"; break ;;
            2) ACCESS_MODEL="public"; break ;;
            3) ACCESS_MODEL="hybrid"; break ;;
            *) echo "Invalid choice. Please enter 1, 2, or 3." ;;
        esac
    done

    log_success "Selected: $ACCESS_MODEL access"
}

get_domain_config() {
    echo ""
    echo -e "${CYAN}Configure your server:${NC}"
    echo ""

    # Domain (required for public/hybrid)
    if [[ "$ACCESS_MODEL" != "tailnet" ]]; then
        while [[ -z "$DOMAIN" ]]; do
            read -p "Enter your domain (e.g., git.example.com): " DOMAIN
            if [[ -z "$DOMAIN" ]]; then
                echo "Domain is required for public/hybrid access."
            fi
        done
        log_success "Domain: $DOMAIN"

        # Email for Let's Encrypt
        while [[ -z "$EMAIL" ]]; do
            read -p "Enter email for SSL certificates: " EMAIL
            if [[ -z "$EMAIL" ]]; then
                echo "Email is required for Let's Encrypt certificates."
            fi
        done
        log_success "Email: $EMAIL"
    fi

    # Tailnet URL (required for tailnet/hybrid)
    if [[ "$ACCESS_MODEL" != "public" ]]; then
        while [[ -z "$TAILNET_URL" ]]; do
            read -p "Enter Tailscale hostname (e.g., myserver.tail12345.ts.net): " TAILNET_URL
            if [[ -z "$TAILNET_URL" ]]; then
                echo "Tailscale hostname is required for tailnet/hybrid access."
            fi
        done
        log_success "Tailnet: $TAILNET_URL"
    fi
}

install_docker() {
    if command -v docker &> /dev/null; then
        log_success "Docker already installed"
        return
    fi

    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    log_success "Docker installed"
}

install_tailscale() {
    if [[ "$ACCESS_MODEL" == "public" ]]; then
        return
    fi

    if command -v tailscale &> /dev/null; then
        log_success "Tailscale already installed"
        return
    fi

    log_info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    log_warn "Run 'tailscale up' to connect to your tailnet"
}

create_directories() {
    log_info "Creating directory structure..."

    mkdir -p "$OGIT_DIR"/{data/repos,hooks,pages,config}

    # Create git user if doesn't exist
    if ! id -u git &>/dev/null; then
        useradd -r -m -d /home/git -s /bin/bash git
    fi

    chown -R git:git "$OGIT_DIR"
    log_success "Directory structure created"
}

install_ogit() {
    log_info "Setting up ogit (git server)..."

    # Create docker-compose.yml for ogit
    cat > "$OGIT_DIR/docker-compose.yml" << 'EOF'
version: '3.8'
services:
  ogit:
    image: ynohat/git-http-backend
    container_name: ogit
    restart: unless-stopped
    volumes:
      - ./data/repos:/git:rw
    environment:
      - GIT_HTTP_EXPORT_ALL=1
    ports:
      - "127.0.0.1:8080:80"
EOF

    # Create Dockerfile for ogit (if needed for custom build)
    cat > "$OGIT_DIR/Dockerfile" << 'EOF'
FROM alpine:latest
RUN apk add --no-cache git git-daemon
EOF

    # Start ogit container
    cd "$OGIT_DIR"
    docker compose up -d

    log_success "ogit container started"
}

install_ssh_proxy() {
    log_info "Setting up SSH proxy..."

    # Create gitraf-ssh-proxy script
    cat > /usr/local/bin/gitraf-ssh-proxy << 'EOFPROXY'
#!/bin/bash
# gitraf SSH proxy - handles git operations

REPO_BASE="/opt/ogit/data/repos"
ORIGINAL_CMD="$SSH_ORIGINAL_COMMAND"

# Parse git command
if [[ "$ORIGINAL_CMD" =~ ^git-receive-pack\ \'(.+)\' ]] || \
   [[ "$ORIGINAL_CMD" =~ ^git-upload-pack\ \'(.+)\' ]]; then
    REPO="${BASH_REMATCH[1]}"
    REPO="${REPO%.git}.git"
    CMD="${ORIGINAL_CMD%% *}"

    # Execute in docker
    docker exec -i ogit $CMD "/git/$REPO"
    EXIT_CODE=$?

    # Run post-receive hook on host after successful push
    if [[ "$CMD" == "git-receive-pack" && $EXIT_CODE -eq 0 ]]; then
        HOOK="$REPO_BASE/$REPO/hooks/post-receive"
        if [[ -x "$HOOK" || -L "$HOOK" ]]; then
            REF=$(cd "$REPO_BASE/$REPO" && git for-each-ref --count=1 --sort=-committerdate --format="%(refname)" refs/heads/)
            (cd "$REPO_BASE/$REPO" && echo "0000000 HEAD $REF" | bash "$HOOK") 2>&1
        fi
    fi

    exit $EXIT_CODE
else
    echo "Invalid git command"
    exit 1
fi
EOFPROXY

    chmod +x /usr/local/bin/gitraf-ssh-proxy

    # Configure SSH for git user
    mkdir -p /home/git/.ssh
    touch /home/git/.ssh/authorized_keys
    chown -R git:git /home/git/.ssh
    chmod 700 /home/git/.ssh
    chmod 600 /home/git/.ssh/authorized_keys

    # Set git user shell
    usermod -s /usr/local/bin/gitraf-ssh-proxy git

    log_success "SSH proxy configured"
}

install_gitraf_server() {
    if [[ $TIER -lt 2 ]]; then
        return
    fi

    log_info "Installing gitraf-server (web interface)..."

    mkdir -p "$GITRAF_SERVER_DIR/templates"

    # Download binary
    if [[ -f "$SCRIPT_DIR/binaries/gitraf-server" ]]; then
        cp "$SCRIPT_DIR/binaries/gitraf-server" "$GITRAF_SERVER_DIR/"
    else
        log_info "Downloading gitraf-server binary..."
        curl -fsSL -o "$GITRAF_SERVER_DIR/gitraf-server" "$GITRAF_SERVER_URL" || {
            log_warn "Could not download binary. Building from source..."
            install_gitraf_server_from_source
            return
        }
    fi

    chmod +x "$GITRAF_SERVER_DIR/gitraf-server"

    # Copy templates
    if [[ -d "$SCRIPT_DIR/templates" ]]; then
        cp -r "$SCRIPT_DIR/templates/"* "$GITRAF_SERVER_DIR/templates/"
    else
        download_templates
    fi

    # Create systemd service
    create_gitraf_server_service

    log_success "gitraf-server installed"
}

install_gitraf_server_from_source() {
    log_info "Building gitraf-server from source..."

    # Install Go if not present
    if ! command -v go &> /dev/null; then
        log_info "Installing Go..."
        curl -fsSL https://go.dev/dl/go1.21.5.linux-amd64.tar.gz | tar -C /usr/local -xzf -
        export PATH=$PATH:/usr/local/go/bin
    fi

    # Clone and build
    cd /tmp
    git clone --depth 1 https://github.com/RafayelGardishyan/gitraf-server.git
    cd gitraf-server
    go build -o "$GITRAF_SERVER_DIR/gitraf-server" .
    cp -r templates "$GITRAF_SERVER_DIR/"
    cd /
    rm -rf /tmp/gitraf-server

    chmod +x "$GITRAF_SERVER_DIR/gitraf-server"
}

download_templates() {
    log_info "Downloading templates..."

    # Download from GitHub
    cd "$GITRAF_SERVER_DIR/templates"
    for file in index.html layout.html repo.html blob.html commits.html; do
        curl -fsSL -o "$file" "https://raw.githubusercontent.com/RafayelGardishyan/gitraf-server/main/templates/$file" || true
    done
}

create_gitraf_server_service() {
    local args="--repos $OGIT_DIR/data/repos --port 8081 --templates $GITRAF_SERVER_DIR/templates"

    if [[ -n "$DOMAIN" ]]; then
        args="$args --public-url https://$DOMAIN"
    fi

    if [[ -n "$TAILNET_URL" ]]; then
        args="$args --tailnet-url $TAILNET_URL"
    fi

    cat > /etc/systemd/system/gitraf-server.service << EOF
[Unit]
Description=Gitraf Web Server
After=network.target docker.service

[Service]
Type=simple
ExecStart=$GITRAF_SERVER_DIR/gitraf-server $args
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gitraf-server
    systemctl start gitraf-server
}

install_pages() {
    if [[ $TIER -lt 3 ]]; then
        return
    fi

    log_info "Setting up gitraf-pages (static site hosting)..."

    # Install Node.js for builds
    if ! command -v node &> /dev/null; then
        log_info "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi

    # Install jq for JSON parsing
    apt-get install -y -qq jq rsync

    # Create post-receive-pages hook
    cat > "$OGIT_DIR/hooks/post-receive-pages" << 'EOFHOOK'
#!/bin/bash
# post-receive-pages hook for gitraf pages deployment

REPO_DIR="$PWD"
REPO_NAME=$(basename "$REPO_DIR" .git)
PAGES_DIR="/opt/ogit/pages/$REPO_NAME"
CONFIG_FILE="$REPO_DIR/git-pages.json"

# Check if pages config exists
if [ ! -f "$CONFIG_FILE" ]; then
    exit 0
fi

# Parse config using jq
ENABLED=$(jq -r '.enabled // true' "$CONFIG_FILE")
BRANCH=$(jq -r '.branch // "main"' "$CONFIG_FILE")
BUILD_CMD=$(jq -r '.build_command // ""' "$CONFIG_FILE")
OUTPUT_DIR=$(jq -r '.output_dir // "public"' "$CONFIG_FILE")

if [ "$ENABLED" != "true" ]; then
    exit 0
fi

# Check if the pushed branch matches configured branch
while read oldrev newrev refname; do
    PUSHED_BRANCH=$(basename "$refname")
    if [ "$PUSHED_BRANCH" != "$BRANCH" ]; then
        continue
    fi

    echo "==> Deploying $REPO_NAME"

    # Create directories
    mkdir -p "$PAGES_DIR/build" "$PAGES_DIR/site"

    # Checkout full repo for build
    git --work-tree="$PAGES_DIR/build" checkout -f "$BRANCH"

    # Run build command if specified
    if [ -n "$BUILD_CMD" ] && [ "$BUILD_CMD" != "null" ]; then
        echo "==> Running build: $BUILD_CMD"
        cd "$PAGES_DIR/build"

        # Install dependencies if package.json exists
        if [ -f "package.json" ]; then
            echo "==> Installing dependencies..."
            npm ci --silent 2>/dev/null || npm install --silent
        fi

        # Run build
        eval "$BUILD_CMD"

        if [ $? -ne 0 ]; then
            echo "==> Build failed!"
            exit 1
        fi
    fi

    # Copy output to site directory
    if [ -d "$PAGES_DIR/build/$OUTPUT_DIR" ]; then
        rsync -a --delete "$PAGES_DIR/build/$OUTPUT_DIR/" "$PAGES_DIR/site/"
        echo "==> Deployed successfully"
    else
        echo "==> Error: Output directory '$OUTPUT_DIR' not found"
        exit 1
    fi
done
EOFHOOK

    chmod +x "$OGIT_DIR/hooks/post-receive-pages"
    chown git:git "$OGIT_DIR/hooks/post-receive-pages"

    log_success "gitraf-pages configured"
}

configure_nginx() {
    log_info "Configuring nginx..."

    # Install nginx
    apt-get install -y -qq nginx

    # Generate nginx config based on access model
    case "$ACCESS_MODEL" in
        tailnet)
            configure_nginx_tailnet
            ;;
        public)
            configure_nginx_public
            ;;
        hybrid)
            configure_nginx_hybrid
            ;;
    esac

    # Test and reload nginx
    nginx -t
    systemctl enable nginx
    systemctl reload nginx

    log_success "nginx configured"
}

configure_nginx_tailnet() {
    cat > /etc/nginx/sites-available/gitraf << EOF
server {
    listen 80;
    server_name $TAILNET_URL;

    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/gitraf /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
}

configure_nginx_public() {
    cat > /etc/nginx/sites-available/gitraf << EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # Git Smart HTTP (read-only)
    location ~ ^/[^/]+\\.git(/.*)?$ {
        # Block push operations
        if (\$request_uri ~ /git-receive-pack$) {
            return 403;
        }

        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Web UI
    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/gitraf /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
}

configure_nginx_hybrid() {
    cat > /etc/nginx/sites-available/gitraf << EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    client_max_body_size 500m;

    # Git Smart HTTP
    location ~ ^/[^/]+\\.git(/.*)?$ {
        # Block push from non-tailnet IPs
        if (\$request_uri ~ /git-receive-pack$) {
            set \$deny_push 1;
        }
        if (\$remote_addr ~ ^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.) {
            set \$deny_push 0;
        }

        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Web UI
    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    # Add pages config if tier 3
    if [[ $TIER -ge 3 ]]; then
        cat >> /etc/nginx/sites-available/gitraf << EOF

# Wildcard for pages (requires wildcard SSL cert)
server {
    listen 443 ssl default_server;
    server_name ~^(?<subdomain>.+)\\.$DOMAIN$;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    root /opt/ogit/pages/\$subdomain/site;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ \$uri.html =404;
    }

    error_page 404 /404.html;

    location = /robots.txt {
        try_files \$uri @default_robots;
    }

    location @default_robots {
        return 200 "User-agent: *\\nDisallow: /\\n";
        add_header Content-Type text/plain;
    }
}
EOF
    fi

    ln -sf /etc/nginx/sites-available/gitraf /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
}

configure_ssl() {
    if [[ "$ACCESS_MODEL" == "tailnet" ]]; then
        log_info "Tailnet-only mode: Skipping SSL setup"
        return
    fi

    log_info "Setting up SSL certificates..."

    # Install certbot
    apt-get install -y -qq certbot

    # Create webroot directory
    mkdir -p /var/www/certbot

    # Get certificate
    certbot certonly --webroot -w /var/www/certbot \
        -d "$DOMAIN" \
        --email "$EMAIL" \
        --agree-tos \
        --non-interactive || {
            log_warn "Could not obtain certificate automatically."
            log_warn "Run 'certbot certonly --nginx -d $DOMAIN' manually."
        }

    # Reload nginx
    systemctl reload nginx

    log_success "SSL certificates configured"

    if [[ $TIER -ge 3 ]]; then
        echo ""
        log_warn "For pages hosting, you need a wildcard certificate."
        log_warn "Run: certbot certonly --manual --preferred-challenges dns -d \"*.$DOMAIN\""
    fi
}

install_gitraf_cli() {
    log_info "Installing gitraf CLI..."

    # Download or build
    if [[ -f "$SCRIPT_DIR/binaries/gitraf" ]]; then
        cp "$SCRIPT_DIR/binaries/gitraf" /usr/local/bin/
    else
        curl -fsSL -o /usr/local/bin/gitraf "$GITRAF_CLI_URL" || {
            log_info "Building gitraf CLI from source..."
            cd /tmp
            git clone --depth 1 https://github.com/RafayelGardishyan/gitraf.git
            cd gitraf
            go build -o /usr/local/bin/gitraf .
            cd /
            rm -rf /tmp/gitraf
        }
    fi

    chmod +x /usr/local/bin/gitraf

    log_success "gitraf CLI installed"
}

print_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    INSTALLATION COMPLETE                        ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}Components installed:${NC}"
    echo "  - ogit (git server)"
    echo "  - gitraf CLI"
    [[ $TIER -ge 2 ]] && echo "  - gitraf-server (web interface)"
    [[ $TIER -ge 3 ]] && echo "  - gitraf-pages (static hosting)"
    echo ""
    echo -e "${BOLD}Access URLs:${NC}"
    [[ -n "$DOMAIN" ]] && echo "  - Web: https://$DOMAIN"
    [[ -n "$TAILNET_URL" ]] && echo "  - Tailnet: $TAILNET_URL"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    if [[ "$ACCESS_MODEL" != "public" ]]; then
        echo "  1. Connect to Tailscale: tailscale up"
    fi
    echo "  2. Configure gitraf CLI:"
    if [[ -n "$DOMAIN" && -n "$TAILNET_URL" ]]; then
        echo "     gitraf config init https://$DOMAIN $TAILNET_URL"
    elif [[ -n "$DOMAIN" ]]; then
        echo "     gitraf config init https://$DOMAIN"
    else
        echo "     gitraf config init $TAILNET_URL"
    fi
    echo "  3. Create your first repo: gitraf create myrepo"
    echo ""
    if [[ $TIER -ge 3 ]]; then
        echo -e "${YELLOW}Note: For pages hosting with wildcard domains, obtain a wildcard SSL cert:${NC}"
        echo "  certbot certonly --manual --preferred-challenges dns -d \"*.$DOMAIN\""
        echo ""
    fi
    echo -e "${CYAN}Documentation: https://github.com/RafayelGardishyan/gitraf${NC}"
    echo ""
}

main() {
    print_banner
    check_root
    check_os
    check_prerequisites

    select_components
    select_access_model
    get_domain_config

    echo ""
    log_info "Starting installation..."
    echo ""

    install_docker
    install_tailscale
    create_directories
    install_ogit
    install_ssh_proxy
    install_gitraf_server
    install_pages
    configure_nginx
    configure_ssl
    install_gitraf_cli

    print_summary
}

# Allow sourcing for testing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
