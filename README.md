# gitraf-deploy

Interactive deployment script for the gitraf self-hosted git server ecosystem.

## What is gitraf?

A lightweight, self-hosted git server. Simple, fast, and free from corporate control.

- **No dependencies** on GitHub, GitLab, or any cloud provider
- **Tailscale integration** for secure private access
- **Optional public access** for open source projects
- **Static site hosting** deploy sites from repos to `{repo}.yourdomain.com`
- **Git LFS support** with S3-compatible storage

## Quick Start

```bash
curl -sSL https://raw.githubusercontent.com/RafayelGardishyan/gitraf-deploy/main/deploy.sh | sudo bash
```

Or clone and run:

```bash
git clone https://github.com/RafayelGardishyan/gitraf-deploy.git
cd gitraf-deploy
sudo ./deploy.sh
```

## Components

The installer offers three tiers:

### Tier 1: Core
- **ogit** - Git repository hosting via SSH
- **gitraf CLI** - Command-line management tool
- Requires Tailscale for access

### Tier 2: Core + Web Interface
Everything in Tier 1, plus:
- **gitraf-server** - Web-based repository browser
- **Git LFS** support with S3 storage

### Tier 3: Full Stack (Recommended)
Everything in Tier 2, plus:
- **gitraf-pages** - Static site hosting
- Build support (npm, etc.)
- Sites served at `{repo}.yourdomain.com`

## Access Models

### Tailnet-only (Private)
- SSH access via Tailscale only
- No public internet exposure
- Most secure option

### Public (Read-only)
- HTTPS for public repo access
- No Tailscale required for viewing
- Push requires authorized SSH keys

### Hybrid (Recommended)
- Public HTTPS for reading public repos
- SSH via Tailscale for full access
- Best of both worlds

## Requirements

- Ubuntu 20.04+ or Debian 11+
- Root access
- Domain name (for public/hybrid access)
- Tailscale account (for tailnet/hybrid access)

## Manual Installation

If you prefer manual setup, see the individual scripts in the `scripts/` directory.

## Rate Limiting

The deployment includes nginx rate limiting to protect against abuse:

| Endpoint | Rate | Burst |
|----------|------|-------|
| Web UI | 10 req/s | 20 |
| Git operations | 2 req/s | 5 |
| Connections per IP | 10 | - |

Default rate limits are configured in the nginx configuration and can be customized by editing `/etc/nginx/nginx.conf`.

## SSH Key Setup for GitHub Mirroring

To enable GitHub mirroring from the web interface:

1. Navigate to any repository settings page
2. Under "GitHub Mirror", click "Generate SSH Key" if no key exists
3. Copy the public key
4. Add it to your [GitHub SSH keys](https://github.com/settings/keys)
5. Configure the mirror URL and enable mirroring

## Post-Installation

After installation, configure the gitraf CLI on your local machine:

```bash
# Install gitraf CLI locally
git clone https://github.com/RafayelGardishyan/gitraf.git
cd gitraf
./install.sh

# Configure
gitraf config init https://git.yourdomain.com yourserver.tail12345.ts.net
```

Then you can:

```bash
# Create a repository
gitraf create myrepo

# Clone it
gitraf clone myrepo

# Make it public
gitraf public myrepo

# Enable pages hosting
gitraf pages enable myrepo
```

## Project Status

This project is maintained by a single developer and is provided as-is. While care is taken to ensure stability, bugs may exist.

**Contributions are always welcome!**

## Related Repositories

- [gitraf](https://github.com/RafayelGardishyan/gitraf) - CLI tool
- [gitraf-server](https://github.com/RafayelGardishyan/gitraf-server) - Web interface

## License

MIT

## Acknowledgments

This project was built with significant contributions from [Claude Code](https://claude.ai/claude-code), Anthropic's AI coding assistant.
