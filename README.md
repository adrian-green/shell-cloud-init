# Shell Cloud-Init

A cloud-init compatible bootstrap system implemented in pure bash with `yq` for YAML parsing. This tool provides first-boot operations for new machines by parsing cloud-init compatible YAML configuration files.

## Features

- **Cloud-Init Compatible**: Supports standard cloud-init YAML configuration format
- **Dry-Run by Default**: Safe testing mode prevents accidental changes
- **Comprehensive Logging**: Detailed logging with configurable levels (ERROR, WARN, INFO, DEBUG)
- **Error Handling**: Robust error handling with cleanup and recovery
- **Backup System**: Automatic backup of modified files before changes
- **Validation**: Configuration validation before execution
- **Universal Compatibility**: Works across different Linux distributions

## Supported Configuration Sections

The bootstrap system supports the following cloud-init compatible YAML sections:

- **`packages`**: List of packages to install
- **`users`**: User account creation and configuration
- **`ssh_authorized_keys`**: SSH public keys for authentication
- **`write_files`**: File creation with content, permissions, and ownership
- **`hostname`**: System hostname configuration
- **`timezone`**: System timezone setting
- **`locale`**: System locale configuration
- **`bootcmd`**: Commands to run before package installation
- **`runcmd`**: Commands to run after configuration
- **`final_message`**: Message to display upon completion

## Requirements

- **Bash 4.0+**: Modern bash shell
- **yq**: YAML processor (can be auto-installed with `--install-yq`)
- **Root privileges**: Required for system modifications

## Installation

1. Clone or download the repository:
   ```bash
   git clone <repository-url>
   cd shell-cloud-init
   ```

2. Make the script executable:
   ```bash
   chmod +x bootstrap.sh
   ```

3. Optionally install `yq` system-wide:
   ```bash
   sudo ./bootstrap.sh --install-yq
   ```

## Usage

### Basic Usage

```bash
# Dry-run (default) - shows what would be done without making changes
sudo ./bootstrap.sh --config /path/to/config.yaml

# Execute changes
sudo ./bootstrap.sh --config /path/to/config.yaml --execute

# Force execution even if already completed
sudo ./bootstrap.sh --config /path/to/config.yaml --execute --force
```

### Command Line Options

| Option | Description |
|--------|-------------|
| `--config FILE` | Path to YAML configuration file (required) |
| `--execute` | Execute changes (default is dry-run) |
| `--force` | Force execution even if already completed |
| `--install-yq` | Install yq permanently to /usr/local/bin |
| `--debug` | Enable debug mode with verbose logging |
| `--log-level LEVEL` | Set log level (ERROR, WARN, INFO, DEBUG) |
| `--no-backup` | Disable backup creation before changes |
| `--override VALUES` | Override config values (key:value pairs or YAML Flow) |
| `--help, -h` | Show help message |

### Exit Codes

| Code | Description |
|------|-------------|
| 0 | Success |
| 1 | Invalid usage |
| 2 | Missing or invalid config |
| 3 | Missing yq and unable to install |
| 4 | Bootstrap already completed (unless --force) |
| 5 | Validation error |
| 6 | Execution error |

## Configuration Examples

### Basic Configuration

```yaml
#cloud-config

hostname: my-server
timezone: UTC
locale: en_US.UTF-8

packages:
  - curl
  - vim
  - git

users:
  - name: admin
    groups: sudo
    shell: /bin/bash

ssh_authorized_keys:
  - "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7... user@example.com"

write_files:
  - path: /etc/motd
    content: "Welcome to my server!"
    permissions: "0644"

runcmd:
  - systemctl enable ssh
  - echo "Setup complete" >> /var/log/bootstrap.log

final_message: "Server bootstrap completed successfully!"
```

### Advanced Configuration

```yaml
#cloud-config

hostname: production-server
timezone: Australia/Brisbane
locale: en_AU.UTF-8

users:
  - name: deploy
    groups: [sudo, docker]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL

ssh_authorized_keys:
  - "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... deploy@company.com"

packages:
  - htop
  - curl
  - git
  - docker.io
  - nginx

write_files:
  - path: /etc/nginx/sites-available/default
    owner: root:root
    permissions: "0644"
    content: |
      server {
          listen 80 default_server;
          server_name _;
          root /var/www/html;
          index index.html;
      }

  - path: /home/deploy/.bashrc
    owner: deploy:deploy
    permissions: "0644"
    content: |
      export EDITOR=vim
      alias ll='ls -alF'
      alias docker-clean='docker system prune -f'

bootcmd:
  - echo "Pre-installation setup" >> /var/log/bootstrap.log

runcmd:
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker deploy
  - systemctl enable nginx
  - systemctl start nginx
  - echo "Production setup complete at $(date)" >> /var/log/bootstrap.log

final_message: "Production server is ready for deployment!"
```

## File Locations

- **Log File**: `/var/log/bootstrap.log`
- **Completion Stamp**: `/var/lib/bootstrap.done`
- **Backup Directory**: `/var/lib/bootstrap-backups`

## Integration with RC.local

For first-boot execution, add to `/etc/rc.local`:

```bash
#!/bin/bash
if [ ! -f /var/lib/bootstrap.done ]; then
    /path/to/bootstrap.sh --config /path/to/config.yaml --execute
fi
exit 0
```

## Logging

The bootstrap system provides comprehensive logging with multiple levels:

- **ERROR**: Critical errors that prevent execution
- **WARN**: Warnings about potential issues
- **INFO**: General information about operations (default)
- **DEBUG**: Detailed debugging information

Logs are written to both the console and `/var/log/bootstrap.log`.

## Safety Features

- **Dry-run by default**: Prevents accidental changes
- **Completion tracking**: Prevents duplicate execution
- **Automatic backups**: Files are backed up before modification
- **Configuration validation**: YAML syntax and content validation
- **Error recovery**: Comprehensive error handling and cleanup

## Configuration Overrides

The `--override` parameter allows you to modify configuration values at runtime without editing the YAML file. This is particularly useful for:

- **Environment-specific deployments**: Override hostnames, timezones, or packages for different environments
- **Dynamic configuration**: Apply runtime values from CI/CD pipelines or deployment scripts
- **Quick testing**: Test configuration changes without modifying files

### Override Formats

#### Simple Key-Value Format
```bash
# Override single values
sudo ./bootstrap.sh --config config.yaml --override 'hostname=prod-server' --execute

# Override multiple values (comma-separated)
sudo ./bootstrap.sh --config config.yaml --override 'hostname=prod-server,timezone=UTC,locale=en_US.UTF-8' --execute
```

#### YAML Flow Format
```bash
# Simple YAML Flow override
sudo ./bootstrap.sh --config config.yaml --override '{"hostname":"prod-server","timezone":"UTC"}' --execute

# Complex JSON with arrays
sudo ./bootstrap.sh --config config.yaml --override '{"hostname":"prod-server","packages":["vim","curl","htop"]}' --execute
```

### Override Examples

```bash
# Override hostname for production deployment
sudo ./bootstrap.sh --config base-config.yaml --override 'hostname=prod-web-01' --execute

# Override multiple system settings
sudo ./bootstrap.sh --config config.yaml --override 'hostname=dev-server,timezone=America/New_York,locale=en_US.UTF-8' --execute

# Add additional packages via JSON
sudo ./bootstrap.sh --config config.yaml --override '{"packages":["docker.io","nginx","certbot"]}' --execute

# Override final message
sudo ./bootstrap.sh --config config.yaml --override 'final_message=Production deployment completed!' --execute
```

### Override Behavior

- **Merge Strategy**: Override values are merged with the original configuration, with override values taking precedence
- **Type Preservation**: YAML Flow format preserves data types (arrays, objects), while key-value format treats all values as strings
- **Validation**: Override values are validated for JSON syntax and merged configuration is validated before execution
- **One-Shot Operation**: Overrides are applied temporarily and don't modify the original configuration file

## Testing

Test your configuration safely:

```bash
# Validate configuration without changes
sudo ./bootstrap.sh --config test-config.yaml

# Test with debug output
sudo ./bootstrap.sh --config test-config.yaml --debug

# Test with overrides
sudo ./bootstrap.sh --config test-config.yaml --override 'hostname=test-server' --debug

# Execute with verbose logging
sudo ./bootstrap.sh --config test-config.yaml --execute --log-level DEBUG
```

## Troubleshooting

### Common Issues

1. **Missing yq**: Install with `--install-yq` or install manually
2. **Permission denied**: Run with `sudo` for system modifications
3. **Invalid YAML**: Validate your YAML syntax
4. **Already completed**: Use `--force` to re-run

### Debug Mode

Enable debug mode for detailed troubleshooting:

```bash
sudo ./bootstrap.sh --config config.yaml --debug --log-level DEBUG
```

## TODO
- ARCH detection
- A deterministic unique ID generator (Snowflake‑style or simpler)
- A first‑boot ISO‑based data source