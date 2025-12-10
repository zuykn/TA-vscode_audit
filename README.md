# VS Code Audit Add-on by zuykn.io

Collects Visual Studio Code configuration, extensions, workspace settings, and remote development telemetry for security and operational monitoring.

## Features

### Platform
- **Cross-platform**: Windows (batch), macOS (POSIX shell) – zero external dependencies, maximum compatibility across environments.
- **Multi-variant detection**: Discovers VS Code Stable, Insiders, VSCodium, Code-OSS, Cursor, and Windsurf installations (v1: full collection for VS Code Stable only; others reported in installation inventory).
- **Installation inventory**: Captures version, commit ID, architecture, install type (user/system), and client + server components.
- **Complete extension inventory**: Captures client and server extensions with install source, dependencies, trust mode, and pinned versions.
- **Remote session tracking**: SSH, WSL, attached containers, and dev-containers with connection metadata (host, user, auth method).
- **User configuration**: Collects `settings.json` and `argv.json` (startup arguments).
- **Workspace configuration audit**: Collects per-project `.vscode/settings.json`, `tasks.json`, `launch.json`, and `devcontainer.json`.

### Customization
- Collection scope (both scripts):

  - `-user <username>` – collect only for a specific user (default: all users)
  - `-user-dir <path>` – override VS Code user directory
  - `-extensions-dir <path>` – override extensions directory
  - `-workspace-paths <paths>` – custom workspace search paths (comma-separated)
  - `-max-workspace-depth <num>` – max directory depth for workspace scan (default: `5`)

- Disable specific collections:

  - `-no-settings` – skip `settings.json`
  - `-no-argv` – skip `argv.json`
  - `-no-workspace-settings` – skip `.vscode/settings.json`
  - `-no-tasks` – skip `.vscode/tasks.json`
  - `-no-launch` – skip `.vscode/launch.json`
  - `-no-devcontainer` – skip `.devcontainer/devcontainer.json`
  - `-no-installation` – skip installation discovery
  - `-no-extensions` – skip extensions inventory
  - `-no-sessions` – skip sessions (`vscode:sessions`)

- SSH access (Windows only):

  - `-grant-ssh-config-read` – grant SYSTEM read access to `.ssh\config` for SSH username detection

### Security
- Does **not** collect API keys, secrets, or credentials.
- Local filesystem only; no network calls.
- Only metadata from SSH configuration is used (user and auth method).

> **Note – SSH username detection (Windows)**: The scripts read `%USERPROFILE%\.ssh\config` to resolve SSH usernames and auth methods. When Splunk runs as **LocalSystem**, it cannot read user SSH configs—SSH usernames will appear as `"unknown"`. To enable SSH username detection, use the `-grant-ssh-config-read` flag or manually grant access:
> ```cmd
> icacls "C:\Users\<username>\.ssh\config" /grant "SYSTEM:R"
> ```
> ⚠️ **Why this isn't default**: Windows protects `.ssh` directories with user-only ACLs by design—SSH clients require restricted permissions and will refuse to use keys if permissions are too open. The command above grants SYSTEM read access to **only** the `config` file (not private keys). Evaluate whether exposing SSH config metadata (hostnames, usernames, key paths) to LocalSystem processes aligns with your security policies before enabling.

### Performance
- Chunked output for large lists (extensions and sessions) – 10 items per event.
- Depth‑limited workspace scanning (default depth 5).
- Single‑line JSON events for efficient ingestion.

## VS Code Variants

Both scripts detect installations for these variants and expose them via `vscode:installation`:

- Visual Studio Code – Insiders
- VSCodium
- Code – OSS
- Cursor
- Windsurf

For **v1**:

- Full data collection (settings, extensions, sessions, workspace files) is limited to **VS Code Stable**.
- Other variants are currently reported in installation inventory only (for visibility).

## Installation

1. Install the add‑on under `$SPLUNK_HOME/etc/apps/` on:
  - **Universal Forwarders** (to run the collection scripts).
  - **Search heads** (for search‑time field extractions and props).
2. On each Universal Forwarder, configure `inputs.conf`:
  - Set the target `index`.
  - Set `interval` (recommended: `3600` seconds).
  - Add or adjust script stanzas as needed (see examples below).
  - **Enable only one scripted input stanza per Universal Forwarder** to avoid duplicate events.
3. Ensure each scripted input has `disabled = 0` in `inputs.conf`.
4. Restart:
  - The **Universal Forwarders** where the add‑on is installed.
  - Any **search heads** using the add‑on.

## Usage

Both scripts share a consistent CLI and output.

```text
Usage: vscode_audit.[bat|sh] [options]

Options:
    -user <name>               Collect only for specific user (default: all users)
    -user-dir <path>           Override VS Code user directory path
    -extensions-dir <path>     Override extensions directory path
    -workspace-paths <paths>   Custom workspace search paths (comma-separated)
    -max-workspace-depth <num> Max workspace search depth (default: 5)

Disable collections:
    -no-settings               Skip settings.json
    -no-argv                   Skip argv.json
    -no-workspace-settings     Skip .vscode/settings.json
    -no-tasks                  Skip .vscode/tasks.json
    -no-launch                 Skip .vscode/launch.json
    -no-devcontainer           Skip .devcontainer/devcontainer.json
    -no-installation           Skip installation discovery
    -no-extensions             Skip extensions inventory
    -no-sessions               Skip session collection

SSH Config SYSTEM Read Access (Windows only):
    -grant-ssh-config-read     Grant SYSTEM read access to `%USERPROFILE%\.ssh\config` to enable SSH username detection for remote sessions.
```

### Example inputs.conf stanzas

**Windows:**

```ini
# Basic collection (all users)
[script://.\bin\\vscode_audit.bat]
index = main
interval = 3600
disabled = 0
 
# Single user, skip devcontainer
[script://.\bin\vscode_audit.bat -user developer -no-devcontainer]
index = main
interval = 3600
disabled = 0
 
# Extensions-only audit for one user
[script://.\bin\vscode_audit.bat -user developer -no-settings -no-argv -no-workspace-settings -no-tasks -no-launch -no-devcontainer -no-installation -no-sessions]
index = main
interval = 3600
disabled = 0
```

**macOS:**

```ini
# Basic collection (all users)
[script://./bin/vscode_audit.sh]
index = main
interval = 3600
disabled = 0
 
# Single user, skip extensions
[script://./bin/vscode_audit.sh -user dev -no-extensions]
index = main
interval = 3600
disabled = 0
 
# Single user with custom workspaces, shallow scan
[script://./bin/vscode_audit.sh -user dev -workspace-paths "/Users/dev/src,/Users/dev/projects" -max-workspace-depth 3]
index = main
interval = 3600
disabled = 0
```

## Sourcetypes

The add‑on emits **9** sourcetypes:

### `vscode:installation`

Discovered VS Code installations (client and remote server components) per user. Use `target` to distinguish local client installs from remote server installs.

| Field | Description |
|-------|-------------|
| `version` | VS Code version number |
| `commit_id` | Git commit hash of the build |
| `architecture` | CPU architecture (x64, arm64) |
| `target` | `client` or `server` (remote) |
| `install_type` | `user` or `system` scope |
| `install_path` | Root installation directory |
| `executable_path` | Path to the VS Code binary |
| `product_name` | Product variant name (same for client and server; use `target` to distinguish) |
| `update_url` | Update endpoint URL |
| `user_data_dir` | User settings directory |
| `extensions_dir` | Extensions directory |

### `vscode:settings`

User-level `settings.json` containing editor preferences, enabled features, and security-relevant settings like workspace trust configuration.

| Field | Description |
|-------|-------------|
| `file_path` | Path to settings.json |
| `content` | Raw file content |

### `vscode:argv`

User-level `argv.json` containing VS Code startup arguments (locale, crash reporter settings, sandbox configuration).

| Field | Description |
|-------|-------------|
| `file_path` | Path to argv.json |
| `content` | Raw file content |

### `vscode:workspace_settings`

Project-level `.vscode/settings.json` containing workspace-specific editor and language settings that may override user defaults.

| Field | Description |
|-------|-------------|
| `file_path` | Path to workspace settings.json |
| `content` | Raw file content |

### `vscode:tasks`

Project-level `.vscode/tasks.json` defining build, test, and automation tasks.

| Field | Description |
|-------|-------------|
| `file_path` | Path to tasks.json |
| `content` | Raw file content |

### `vscode:launch`

Project-level `.vscode/launch.json` defining debug configurations, including program paths, environment variables, and remote attach settings.

| Field | Description |
|-------|-------------|
| `file_path` | Path to launch.json |
| `content` | Raw file content |

### `vscode:devcontainer`

Project-level `.devcontainer/devcontainer.json` defining development container configuration (base image, features, extensions, port forwarding, and post-create commands).

| Field | Description |
|-------|-------------|
| `file_path` | Path to devcontainer.json |
| `content` | Raw file content |

### `vscode:extensions`

Installed extensions inventory for client and server environments (chunked, 10 items/event). Includes install source, trust mode, executable detection, and activation events.

| Field | Description |
|-------|-------------|
| `extension_id` | Directory name with version (e.g., `ms-python.python-2025.1.0`) |
| `name` | Internal extension name |
| `display_name` | Human-readable name |
| `publisher` | Extension publisher |
| `version` | Extension version |
| `target` | `client` or `server` |
| `install_source` | `gallery` (VS Code Marketplace), `vsix` (manual/local .vsix file, potentially from OpenVSX), or `unknown` |
| `installed_timestamp` | Unix timestamp of installation |
| `is_prerelease` | Whether prerelease version |
| `is_pinned_version` | Extension is locked to a specific version |
| `vscode_engine` | Minimum required VS Code version |
| `workspace_trust_mode` | Extension's compatibility with VS Code workspace trust: `supported`, `unsupported`, `limited`, or `unknown` |
| `contains_executables` | Extension contains one or more of the following executable files:<br>• **Native**: `.exe`, `.dll`, `.so`, `.dylib`, `.node`, `.a`, `.lib`<br>• **Bytecode**: `.wasm`, `.jar`, `.class`, `.pyc`, `.pyo`<br>• **Scripts**: `.ps1`, `.bat`, `.cmd`, `.sh`, `.bash`, `.py`, `.rb`, `.pl`, `.lua`, `.vbs`, `.fish` |
| `activation_events` | Events that trigger activation |
| `extension_dependencies` | List of required extension IDs (dependencies) |
| `chunk` / `chunk_total` | Chunk index and total count |
| `chunk_set_id_extensions` | Unique ID to correlate chunks |

### `vscode:sessions`

Active and recent sessions inventory (chunked, 10 items/event). Tracks local, SSH, WSL, and container connections with authentication method and workspace context.

| Field | Description |
|-------|-------------|
| `connection_type` | `local`, `ssh-remote`, `wsl`, `dev-container`, `attached-container` |
| `remote_host` | SSH host, WSL distro, or container name |
| `user` | Remote username (or local user if unknown) |
| `auth_method` | `local`, `publickey`, `password`, `docker` |
| `window_type` | `folder`, `workspace`, or `empty` |
| `workspace_path` | Path to opened folder/workspace |
| `is_active` | `true` if VS Code running and window open |
| `storage_file_path` | Path to storage.json source |
| `chunk` / `chunk_total` | Chunk index and total count |
| `chunk_set_id_sessions` | Unique ID to correlate chunks |

## Support

Need help, want a custom version, or have a feature request? Contact us—​we're happy to help!
- **Website**: https://zuykn.io
- **Docs**: https://docs.zuykn.io
- **Email**: support@zuykn.io

## License
This add-on is licensed under the zuykn Private Commercial Use License Version 1.0.
See the `LICENSE` file in the project root for full terms.

---
© 2023–2025 zuykn. All Rights Reserved.
