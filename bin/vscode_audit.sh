#!/bin/sh

# Script: vscode_audit.sh
# Author: zuykn.io
#
# zuykn Private Commercial Use License Version 1.0
# Copyright (c) 2023–2025 zuykn — https://zuykn.io
#
# Use of this file is governed by the zuykn Private Commercial Use License
# included in the LICENSE file in the project root.

# Config
SCRIPT_NAME=$(basename "$0")
CURRENT_USER=$(whoami 2>/dev/null || echo "unknown")

# ISO8601 timestamp
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null | sed 's/\([0-9][0-9]\)$/:\1/' || echo "unknown")

# Chunk IDs
TIME_SUFFIX=$(date '+%H%M%S' 2>/dev/null)
if [ -n "$RANDOM" ]; then
    RANDOM_ID_EXT="$((RANDOM * 32768 + RANDOM))"
else
    RANDOM_ID_EXT="$(($(date +%N 2>/dev/null || echo $$) % 10000000000))"
fi
CHUNK_SET_ID_EXTENSIONS="${RANDOM_ID_EXT}-${TIME_SUFFIX}"
if [ -n "$RANDOM" ]; then
    RANDOM_ID_SES="$((RANDOM * 32768 + RANDOM))"
else
    RANDOM_ID_SES="$(($(date +%N 2>/dev/null || echo $$ * 2) % 10000000000))"
fi
CHUNK_SET_ID_SESSIONS="${RANDOM_ID_SES}-${TIME_SUFFIX}"

# Paths
VSCODE_USER_DIR=""
VSCODE_EXTENSIONS_DIR=""

# Variant tracking
CURRENT_VARIANT=""
CURRENT_PRODUCT_NAME=""
COLLECT_FULL_DATA=1

# Collection flags
COLLECT_SETTINGS=1
COLLECT_ARGV=1
COLLECT_WORKSPACE_SETTINGS=1
COLLECT_TASKS=1
COLLECT_LAUNCH=1
COLLECT_DEVCONTAINER=1
COLLECT_INSTALLATION=1
COLLECT_EXTENSIONS=1
COLLECT_EXTENSION_METADATA=1
COLLECT_ACTIVE_SESSION=1
CUSTOM_USER_DIR=""
CUSTOM_EXTENSIONS_DIR=""
MAX_WORKSPACE_DEPTH=5
CHUNK_SIZE=10
WORKSPACE_SEARCH_PATHS=""
COLLECT_ALL_USERS=1
TARGET_USER=""

# Parse args
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|-help|--help)
                usage 0
                exit 0
                ;;
            -user)
                if [ -z "$2" ]; then
                    log_error "-user requires a username argument. Example: -user admin"
                    exit 1
                fi
                TARGET_USER="$2"
                COLLECT_ALL_USERS=0
                shift 2
                ;;
            -user-dir)
                if [ -z "$2" ]; then
                    log_error "-user-dir requires a path argument"
                    exit 1
                fi
                CUSTOM_USER_DIR="$2"
                shift 2
                ;;
            -extensions-dir)
                if [ -z "$2" ]; then
                    log_error "-extensions-dir requires a path argument"
                    exit 1
                fi
                CUSTOM_EXTENSIONS_DIR="$2"
                shift 2
                ;;
            -workspace-paths)
                if [ -z "$2" ]; then
                    log_error "-workspace-paths requires comma-separated paths"
                    exit 1
                fi
                WORKSPACE_SEARCH_PATHS="$2"
                shift 2
                ;;
            -max-workspace-depth)
                if [ -z "$2" ]; then
                    log_error "-max-workspace-depth requires a number argument"
                    exit 1
                fi
                MAX_WORKSPACE_DEPTH="$2"
                shift 2
                ;;
            -no-settings)
                COLLECT_SETTINGS=0
                shift
                ;;
            -no-argv)
                COLLECT_ARGV=0
                shift
                ;;
            -no-workspace-settings)
                COLLECT_WORKSPACE_SETTINGS=0
                shift
                ;;
            -no-installation)
                COLLECT_INSTALLATION=0
                shift
                ;;
            -no-extensions)
                COLLECT_EXTENSIONS=0
                shift
                ;;
            -no-sessions)
                COLLECT_ACTIVE_SESSION=0
                shift
                ;;
            -no-tasks)
                COLLECT_TASKS=0
                shift
                ;;
            -no-launch)
                COLLECT_LAUNCH=0
                shift
                ;;
            -no-devcontainer)
                COLLECT_DEVCONTAINER=0
                shift
                ;;
            -*)
                log_error "Unknown flag: $1"
                exit 1
                ;;
            *)
                log_error "Unexpected argument: $1"
                exit 1
                ;;
        esac
    done
}

# Error logging
log_error() {
    echo "ERROR: $1" >&2
}

# Usage
usage() {
    code="${1:-1}"
    cat <<'EOF' >&2
Usage: vscode_audit.sh [options]

Description: VS Code Audit Add-on by zuykn.io - Collects Microsoft Visual Studio Code configuration, extension, workspace, and remote activity telemetry for security and operational monitoring.
             Produces 9 sourcetypes in NDJSON format for Splunk ingestion:
             - vscode:settings          (user settings.json)
             - vscode:argv              (startup arguments)
             - vscode:workspace_settings (project-level settings)
             - vscode:tasks             (project-level tasks.json)
             - vscode:launch            (project-level launch.json)
             - vscode:devcontainer      (project-level devcontainer.json)
             - vscode:installation      (VS Code client/server installations)
             - vscode:extensions        (installed extensions inventory)
             - vscode:sessions          (active and recent sessions)

Options:
    -user <name>               Collect only for specific user (default: all users)
    -user-dir <path>           Override VS Code user directory path
    -extensions-dir <path>     Override extensions directory path
    -workspace-paths <paths>   Custom workspace search paths (comma-separated)
    -max-workspace-depth <num> Maximum directory depth for workspace search (default: 5)

Disable Collections:
    -no-settings                Skip settings.json collection
    -no-argv                    Skip argv.json collection
    -no-workspace-settings      Skip workspace-level settings.json
    -no-tasks                   Skip workspace-level tasks.json
    -no-launch                  Skip workspace-level launch.json
    -no-devcontainer            Skip workspace-level devcontainer.json
    -no-installation            Skip VS Code installation collection
    -no-extensions              Skip extensions collection
    -no-sessions                Skip session collection

Examples:
    vscode_audit.sh                    # Collect all 9 sourcetypes for all users
    vscode_audit.sh -user admin        # Collect only for admin user
    vscode_audit.sh -no-extensions     # Skip extensions collection
EOF
    exit "$code"
}

get_users_to_process() {
    if [ "$COLLECT_ALL_USERS" = "0" ] && [ -n "$TARGET_USER" ]; then
        echo "$TARGET_USER"
        return
    fi
    
    # Enumerate users based on platform
    case "$(uname -s)" in
        Darwin)
            # macOS - use dscl to list local users (UID >= 500, excluding system accounts)
            dscl . list /Users UniqueID 2>/dev/null | awk '$2 >= 500 && $2 < 1000 { print $1 }' | grep -v '^_' | sort -u
            ;;
        Linux)
            # Linux - extract from /etc/passwd (UID >= 1000)
            awk -F: '$3 >= 1000 && $3 < 60000 && $1 !~ /^(nobody|nfsnobody)$/ { print $1 }' /etc/passwd 2>/dev/null | sort -u
            ;;
        *)
            # Fallback to current user
            echo "$CURRENT_USER"
            ;;
    esac
}

get_user_home() {
    target_user="$1"
    
    # Use HOME for current user
    if [ "$target_user" = "$CURRENT_USER" ] && [ -n "$HOME" ]; then
        echo "$HOME"
        return 0
    fi
    
    # Platform-specific home directory lookup
    case "$(uname -s)" in
        Darwin)
            # macOS - use dscl
            home_dir=$(dscl . -read /Users/"$target_user" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
            ;;
        Linux)
            # Linux - extract from /etc/passwd
            home_dir=$(awk -F: -v user="$target_user" '$1 == user { print $6 }' /etc/passwd 2>/dev/null)
            ;;
        *)
            home_dir=""
            ;;
    esac
    
    # Fallback to standard patterns
    if [ -z "$home_dir" ] || [ ! -d "$home_dir" ]; then
        if [ -d "/Users/$target_user" ]; then
            home_dir="/Users/$target_user"
        elif [ -d "/home/$target_user" ]; then
            home_dir="/home/$target_user"
        fi
    fi
    
    # Verify directory exists and is readable
    if [ -d "$home_dir" ] && [ -r "$home_dir" ]; then
        echo "$home_dir"
        return 0
    fi
    
    return 1
}

# Variant configuration
# Format: user_dir_suffix|extensions_dir_suffix|collect_full_data
get_variant_config() {
    variant_id="$1"
    case "$variant_id" in
        stable)
            echo "Code|.vscode|1"
            ;;
        insiders)
            echo "Code - Insiders|.vscode-insiders|0"
            ;;
        vscodium)
            echo "VSCodium|.vscode-oss|0"
            ;;
        cursor)
            echo "Cursor|.cursor|0"
            ;;
        code-oss)
            echo "Code - OSS|.vscode-oss|0"
            ;;
        windsurf)
            echo "Windsurf|.windsurf|0"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Get official product name for a variant
# Returns: Official product name string
get_product_name() {
    variant_id="$1"
    case "$variant_id" in
        stable)
            echo "Visual Studio Code"
            ;;
        insiders)
            echo "Visual Studio Code - Insiders"
            ;;
        vscodium)
            echo "VSCodium"
            ;;
        cursor)
            echo "Cursor"
            ;;
        code-oss)
            echo "Code - OSS"
            ;;
        windsurf)
            echo "Windsurf"
            ;;
        *)
            echo "Unknown"
            ;;
    esac
}

# Detect paths for a specific VS Code variant
# Args: target_user variant_id
# Sets: VSCODE_USER_DIR, VSCODE_EXTENSIONS_DIR, CURRENT_VARIANT, CURRENT_PRODUCT_NAME, COLLECT_FULL_DATA
detect_variant_paths() {
    target_user="$1"
    variant_id="$2"
    
    user_home=$(get_user_home "$target_user")
    if [ $? -ne 0 ] || [ -z "$user_home" ]; then
        return 1
    fi
    
    # Get variant configuration
    variant_config=$(get_variant_config "$variant_id")
    if [ -z "$variant_config" ]; then
        return 1
    fi
    
    # Parse variant config: user_dir_suffix|extensions_dir_suffix|collect_full_data
    user_dir_suffix=$(echo "$variant_config" | cut -d'|' -f1)
    extensions_dir_suffix=$(echo "$variant_config" | cut -d'|' -f2)
    COLLECT_FULL_DATA=$(echo "$variant_config" | cut -d'|' -f3)
    CURRENT_VARIANT="$variant_id"
    CURRENT_PRODUCT_NAME=$(get_product_name "$variant_id")
    
    # Set user directory path
    if [ -n "$CUSTOM_USER_DIR" ]; then
        VSCODE_USER_DIR="$CUSTOM_USER_DIR"
    else
        # Platform-specific paths
        case "$(uname -s)" in
            Darwin)
                VSCODE_USER_DIR="$user_home/Library/Application Support/$user_dir_suffix/User"
                ;;
            Linux)
                VSCODE_USER_DIR="$user_home/.config/$user_dir_suffix/User"
                ;;
            *)
                VSCODE_USER_DIR="$user_home/.config/$user_dir_suffix/User"
                ;;
        esac
    fi
    
    # Set extensions directory path
    if [ -n "$CUSTOM_EXTENSIONS_DIR" ]; then
        VSCODE_EXTENSIONS_DIR="$CUSTOM_EXTENSIONS_DIR"
    else
        VSCODE_EXTENSIONS_DIR="$user_home/$extensions_dir_suffix/extensions"
    fi
    
    return 0
}

# Legacy function - detects paths for VS Code Stable only
# Kept for backward compatibility
detect_vscode_paths() {
    target_user="$1"
    detect_variant_paths "$target_user" "stable"
}

check_file() {
    file_path="$1"
    if [ -f "$file_path" ] && [ -r "$file_path" ]; then
        return 0
    fi
    return 1
}

check_security_patterns() {
    file_path="$1"
    if [ ! -f "$file_path" ]; then
        return 0
    fi
    
    # Check for dangerous patterns
    if grep -qE "BEGIN (RSA |OPENSSH |)PRIVATE KEY|password.*:|privateKey|passphrase" "$file_path" 2>/dev/null; then
        return 1
    fi
    
    return 0
}

# Escape JSON string
escape_json() {
    input_file="$1"
    # Read file and perform JSON escaping
    sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' "$input_file" 2>/dev/null | \
    tr '\r' ' ' | tr '\f' ' ' | \
    awk 'BEGIN{ORS="\\n"} {print}' | \
    sed 's/\\n$//'
}

# Escape string
escape_json_string() {
    input_string="$1"
    # Escape backslashes, quotes, tabs, newlines
    printf '%s' "$input_string" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr '\n' ' '
}

# Process JSON file
process_json_file() {
    file_path="$1"
    target_user="$2"
    
    check_file "$file_path" || return 0
    check_security_patterns "$file_path" || return 0
    
    # Escape file content for JSON
    escaped_content=$(escape_json "$file_path" 2>/dev/null)
    if [ -z "$escaped_content" ]; then
        escaped_content="{}"
    fi
    
    # Escape file path for JSON
    safe_file_path=$(echo "$file_path" | sed 's/\\/\\\\/g; s/"/\\"/g')
    
    # Output JSON event
    printf '{"timestamp":"%s","user":"%s","product_name":"%s","file_path":"%s","content":"%s"}\n' \
        "$TIMESTAMP" "$target_user" "$CURRENT_PRODUCT_NAME" "$safe_file_path" "$escaped_content"
}

calculate_total_chunks() {
    total_items="$1"
    chunk_size="$2"
    
    if [ "$chunk_size" -eq 0 ] 2>/dev/null; then
        chunk_size=1
    fi
    if [ -z "$chunk_size" ]; then
        chunk_size=1
    fi
    
    # Calculate ceiling division: (total + size - 1) / size
    echo $(( (total_items + chunk_size - 1) / chunk_size ))
}

get_search_paths() {
    user_home="$1"
    
    if [ -n "$WORKSPACE_SEARCH_PATHS" ]; then
        echo "$WORKSPACE_SEARCH_PATHS"
    else
        # All paths scanned at MAX_WORKSPACE_DEPTH (default 5)
        echo "$user_home/Workspace,$user_home/workspace,$user_home/Projects,$user_home/projects,$user_home/Code,$user_home/code,$user_home/Dev,$user_home/dev,$user_home/Developer,$user_home/developer,$user_home/Src,$user_home/src,$user_home/Git,$user_home/git,$user_home/Www,$user_home/www,$user_home/Sites,$user_home/sites,$user_home/Documents,$user_home/documents,$user_home/Desktop,$user_home/desktop,$user_home/Downloads,$user_home/downloads"
    fi
}

get_workspacestorage_paths() {
    user_home="$1"
    
    # Platform-specific workspaceStorage path
    case "$(uname -s)" in
        Darwin)
            workspace_storage_dir="$user_home/Library/Application Support/Code/User/workspaceStorage"
            ;;
        *)
            workspace_storage_dir="$user_home/.config/Code/User/workspaceStorage"
            ;;
    esac
    
    # Return early if workspaceStorage doesn't exist
    if [ ! -d "$workspace_storage_dir" ]; then
        return
    fi
    
    # Find all workspace.json files and extract folder paths
    find "$workspace_storage_dir" -maxdepth 2 -name "workspace.json" 2>/dev/null | while read -r workspace_file; do
        # Extract folder path from workspace.json (handles both "folder" and "workspace" keys)
        grep -o '"folder":"file://[^"]*"' "$workspace_file" 2>/dev/null | sed 's/"folder":"file:\/\///' | sed 's/"$//' | while read -r folder_path; do
            # Decode URL encoding using POSIX-compliant sed (no bash parameter expansion)
            echo "$folder_path" | sed 's/%20/ /g; s/%3A/:/g; s/%2B/+/g; s/%2F/\//g; s/%5C/\\/g'
        done
    done
}

find_workspace_vscode_dirs() {
    search_path="$1"
    user="$2"
    max_depth="${3:-5}"
    
    [ ! -d "$search_path" ] && return
    
    # Find .vscode directories and process files
    # Save and set IFS to newline for proper iteration
    old_ifs="$IFS"
    IFS='
'
    vscode_dirs=$(find "$search_path" -maxdepth "$max_depth" -type d -name ".vscode" 2>/dev/null)
    for vscode_dir in $vscode_dirs; do
        if [ "$COLLECT_WORKSPACE_SETTINGS" = "1" ] && [ -f "$vscode_dir/settings.json" ]; then
            file_path="$vscode_dir/settings.json"
            inode=$(ls -i "$file_path" 2>/dev/null | awk '{print $1}')
            if [ -n "$inode" ]; then
                case "$SEEN_WORKSPACE_FILES" in
                    *"|$inode|"*) ;;
                    *) process_json_file "$file_path" "$user" && SEEN_WORKSPACE_FILES="$SEEN_WORKSPACE_FILES|$inode|" ;;
                esac
            fi
        fi
        if [ "$COLLECT_TASKS" = "1" ] && [ -f "$vscode_dir/tasks.json" ]; then
            file_path="$vscode_dir/tasks.json"
            inode=$(ls -i "$file_path" 2>/dev/null | awk '{print $1}')
            if [ -n "$inode" ]; then
                case "$SEEN_WORKSPACE_FILES" in
                    *"|$inode|"*) ;;
                    *) process_json_file "$file_path" "$user" && SEEN_WORKSPACE_FILES="$SEEN_WORKSPACE_FILES|$inode|" ;;
                esac
            fi
        fi
        if [ "$COLLECT_LAUNCH" = "1" ] && [ -f "$vscode_dir/launch.json" ]; then
            file_path="$vscode_dir/launch.json"
            inode=$(ls -i "$file_path" 2>/dev/null | awk '{print $1}')
            if [ -n "$inode" ]; then
                case "$SEEN_WORKSPACE_FILES" in
                    *"|$inode|"*) ;;
                    *) process_json_file "$file_path" "$user" && SEEN_WORKSPACE_FILES="$SEEN_WORKSPACE_FILES|$inode|" ;;
                esac
            fi
        fi
    done
    IFS="$old_ifs"
    
    # Find .devcontainer directories and process files
    old_ifs="$IFS"
    IFS='
'
    devcontainer_dirs=$(find "$search_path" -maxdepth "$max_depth" -type d -name ".devcontainer" 2>/dev/null)
    for devcontainer_dir in $devcontainer_dirs; do
        if [ "$COLLECT_DEVCONTAINER" = "1" ] && [ -f "$devcontainer_dir/devcontainer.json" ]; then
            file_path="$devcontainer_dir/devcontainer.json"
            inode=$(ls -i "$file_path" 2>/dev/null | awk '{print $1}')
            if [ -n "$inode" ]; then
                case "$SEEN_WORKSPACE_FILES" in
                    *"|$inode|"*) ;;
                    *) process_json_file "$file_path" "$user" && SEEN_WORKSPACE_FILES="$SEEN_WORKSPACE_FILES|$inode|" ;;
                esac
            fi
        fi
    done
    IFS="$old_ifs"
}

process_settings() {
    target_user="$1"
    
    if [ "$COLLECT_SETTINGS" = "0" ]; then
        return 0
    fi
    
    if [ ! -d "$VSCODE_USER_DIR" ]; then
        return 0
    fi
    
    settings_json_file="$VSCODE_USER_DIR/settings.json"
    process_json_file "$settings_json_file" "$target_user"
}

process_argv() {
    target_user="$1"
    
    if [ "$COLLECT_ARGV" = "0" ]; then
        return 0
    fi
    
    if [ ! -d "$VSCODE_USER_DIR" ]; then
        return 0
    fi
    
    argv_file="$VSCODE_USER_DIR/argv.json"
    process_json_file "$argv_file" "$target_user"
}

process_workspace_files() {
    target_user="$1"
    user_home="$2"
    
    # Skip if all collection disabled
    [ "$COLLECT_WORKSPACE_SETTINGS" != "1" ] && [ "$COLLECT_TASKS" != "1" ] && [ "$COLLECT_LAUNCH" != "1" ] && [ "$COLLECT_DEVCONTAINER" != "1" ] && return
    
    # Initialize deduplication tracker
    SEEN_WORKSPACE_FILES=""
    
    search_paths=$(get_search_paths "$user_home")
    
    # Process all paths at MAX_WORKSPACE_DEPTH
    old_ifs="$IFS"
    IFS=','
    for search_path in $search_paths; do
        [ -n "$search_path" ] && find_workspace_vscode_dirs "$search_path" "$target_user" "$MAX_WORKSPACE_DEPTH"
    done
    IFS="$old_ifs"
    
    # Process workspaceStorage paths - use for loop to avoid subshell
    ws_paths=$(get_workspacestorage_paths "$user_home")
    old_ifs="$IFS"
    IFS='
'
    for workspace_path in $ws_paths; do
        [ -n "$workspace_path" ] && find_workspace_vscode_dirs "$workspace_path" "$target_user" "$MAX_WORKSPACE_DEPTH"
    done
    IFS="$old_ifs"
}

lookup_extension_metadata() {
    ext_id="$1"
    extensions_json_file="$2"
    
    # Initialize metadata with default values
    EXT_INSTALL_SOURCE="unknown"
    EXT_INSTALLED_TIMESTAMP="unknown"
    EXT_IS_PRERELEASE="false"
    EXT_IS_PINNED_VERSION="false"
    
    # Skip metadata lookup if disabled (returns with default values above)
    if [ "$COLLECT_EXTENSION_METADATA" = "0" ]; then
        return 0
    fi
    
    # Skip if extensions.json doesn't exist
    if [ ! -f "$extensions_json_file" ]; then
        return 0
    fi
    
    # Read the entire JSON file and search for the extension object
    # The file is a single-line JSON array, so we need to split on extension boundaries
    # and find the extension object that matches our ID
    ext_json=$(cat "$extensions_json_file" | sed 's/},{"identifier/}\n{"identifier/g' | grep "\"id\":\"$ext_id\"")
    
    if [ -n "$ext_json" ]; then
        # Extract source field from metadata
        source_value=$(echo "$ext_json" | sed -n 's/.*"metadata".*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        if [ -n "$source_value" ]; then
            EXT_INSTALL_SOURCE="$source_value"
        fi
        
        # Extract installedTimestamp field from metadata
        timestamp_value=$(echo "$ext_json" | sed -n 's/.*"metadata".*"installedTimestamp"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
        if [ -n "$timestamp_value" ]; then
            EXT_INSTALLED_TIMESTAMP="$timestamp_value"
        fi
        
        # Extract isPreReleaseVersion field from metadata
        prerelease_value=$(echo "$ext_json" | sed -n 's/.*"metadata".*"isPreReleaseVersion"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')
        if [ "$prerelease_value" = "true" ]; then
            EXT_IS_PRERELEASE="true"
        elif [ "$prerelease_value" = "false" ]; then
            EXT_IS_PRERELEASE="false"
        fi
        
        # Extract pinned field (version pinning - auto-update disabled)
        pinned_value=$(echo "$ext_json" | sed -n 's/.*"pinned"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')
        if [ "$pinned_value" = "true" ]; then
            EXT_IS_PINNED_VERSION="true"
        elif [ "$pinned_value" = "false" ]; then
            EXT_IS_PINNED_VERSION="false"
        fi
    fi
}

check_contains_executables() {
    ext_path="$1"
    
    # Check for executable files (comprehensive list)
    # Native/compiled: .exe .dll .so .dylib .node .a .lib
    # Bytecode: .wasm .jar .class .pyc .pyo
    # Scripts: .ps1 .bat .cmd .sh .bash .py .rb .pl .lua .vbs .fish
    if find "$ext_path" -type f \( \
        -iname "*.exe" -o \
        -iname "*.dll" -o \
        -iname "*.so" -o \
        -iname "*.dylib" -o \
        -iname "*.node" -o \
        -iname "*.a" -o \
        -iname "*.lib" -o \
        -iname "*.wasm" -o \
        -iname "*.jar" -o \
        -iname "*.class" -o \
        -iname "*.pyc" -o \
        -iname "*.pyo" -o \
        -iname "*.ps1" -o \
        -iname "*.bat" -o \
        -iname "*.cmd" -o \
        -iname "*.sh" -o \
        -iname "*.bash" -o \
        -iname "*.py" -o \
        -iname "*.rb" -o \
        -iname "*.pl" -o \
        -iname "*.lua" -o \
        -iname "*.vbs" -o \
        -iname "*.fish" \
        \) -print -quit 2>/dev/null | grep -q .; then
        echo "true"
    else
        echo "false"
    fi
}

parse_extension_package_json() {
    ext_name="$1"
    package_json_file="$2"
    
    # Initialize with unknown values
    ext_internal_name="unknown"
    ext_display_name="unknown"
    publisher_name="unknown"
    ext_version="unknown"
    ext_repository="unknown"
    ext_vscode_engine="unknown"
    ext_activation_events="[]"
    ext_workspace_trust_mode="unknown"
    ext_contains_executables="false"
    ext_dependencies="[]"
    
    # Extract fallback values from directory name (publisher.name-version)
    publisher_and_name=$(echo "$ext_name" | sed 's/-[0-9].*//')
    fallback_version=$(echo "$ext_name" | sed 's/.*-\([0-9].*\)/\1/')
    fallback_publisher=$(echo "$publisher_and_name" | cut -d'.' -f1)
    fallback_name=$(echo "$publisher_and_name" | cut -d'.' -f2-)
    
    # Single-pass extraction: read file once and extract all fields
    if [ -f "$package_json_file" ]; then
        # Use single grep to get all relevant lines, then parse in-memory
        pkg_content=$(grep -E '"name"|"displayName"|"publisher"|"version"|"url"|"vscode"|"activationEvents"|"untrustedWorkspaces"|"supported"|"extensionDependencies"' "$package_json_file" 2>/dev/null)
        
        # Extract simple fields from cached content
        name_line=$(echo "$pkg_content" | grep -m1 '"name"')
        if [ -n "$name_line" ]; then
            ext_internal_name=$(echo "$name_line" | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        fi
        
        display_line=$(echo "$pkg_content" | grep -m1 '"displayName"')
        if [ -n "$display_line" ]; then
            ext_display_name=$(echo "$display_line" | sed 's/.*"displayName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's/,$//' | sed 's/[[:space:]]*$//')
        fi
        
        pub_line=$(echo "$pkg_content" | grep -m1 '"publisher"')
        if [ -n "$pub_line" ]; then
            publisher_name=$(echo "$pub_line" | sed 's/.*"publisher"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        fi
        
        ver_line=$(echo "$pkg_content" | grep -m1 '"version"')
        if [ -n "$ver_line" ]; then
            ext_version=$(echo "$ver_line" | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        fi
        
        repo_line=$(echo "$pkg_content" | grep -m1 '"url"')
        if [ -n "$repo_line" ]; then
            ext_repository=$(echo "$repo_line" | sed 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        fi
        
        engine_line=$(echo "$pkg_content" | grep -m1 '"vscode"')
        if [ -n "$engine_line" ]; then
            ext_vscode_engine=$(echo "$engine_line" | sed 's/.*"vscode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's/}$//' | sed 's/,$//')
        fi
        
        # Extract workspace trust mode
        trust_line=$(echo "$pkg_content" | grep '"supported"' | head -1)
        if [ -n "$trust_line" ]; then
            trust_value=$(echo "$trust_line" | sed 's/.*"supported"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/' | tr -d ' ')
            case "$trust_value" in
                true) ext_workspace_trust_mode="supported" ;;
                false) ext_workspace_trust_mode="unsupported" ;;
                \"limited\"|*limited*) ext_workspace_trust_mode="limited" ;;
                *) ext_workspace_trust_mode="unknown" ;;
            esac
        fi
        
        # For arrays, we need the full file context - use single grep with context
        activation_section=$(grep -A 50 '"activationEvents"' "$package_json_file" 2>/dev/null | awk '/"activationEvents"[[:space:]]*:[[:space:]]*\[/,/\]/' | grep -v '"activationEvents"' | grep '"' | sed 's/.*"\([^"]*\)".*/\1/' | tr '\n' ',' | sed 's/,$//')
        if [ -n "$activation_section" ]; then
            ext_activation_events="[\"$(echo "$activation_section" | sed 's/,/","/g')\"]"
        fi
        
        deps_section=$(grep -A 50 '"extensionDependencies"' "$package_json_file" 2>/dev/null | awk '/"extensionDependencies"[[:space:]]*:[[:space:]]*\[/,/\]/' | grep -v '"extensionDependencies"' | grep '"' | sed 's/.*"\([^"]*\)".*/\1/' | tr '\n' ',' | sed 's/,$//')
        if [ -n "$deps_section" ]; then
            ext_dependencies="[\"$(echo "$deps_section" | sed 's/,/","/g')\"]"
        fi
    fi
    
    # Apply fallback values if parsing failed
    if [ "$ext_internal_name" = "unknown" ] && [ -n "$fallback_name" ]; then
        ext_internal_name="$fallback_name"
    fi
    if [ "$ext_display_name" = "unknown" ]; then
        ext_display_name="$ext_internal_name"
    fi
    if [ "$publisher_name" = "unknown" ] && [ -n "$fallback_publisher" ]; then
        publisher_name="$fallback_publisher"
    fi
    if [ "$ext_version" = "unknown" ] && [ -n "$fallback_version" ]; then
        ext_version="$fallback_version"
    fi
    
    # Handle placeholder display names (starting with %)
    case "$ext_display_name" in
        %*)
            if [ "$ext_internal_name" != "unknown" ]; then
                ext_display_name="$ext_internal_name"
            else
                ext_display_name="$ext_name"
            fi
            ;;
    esac
}

# Process extensions
process_extensions() {
    target_user="$1"
    
    if [ "$COLLECT_EXTENSIONS" = "0" ]; then
        return 0
    fi
    
    user_home=$(get_user_home "$target_user")
    if [ $? -ne 0 ] || [ -z "$user_home" ]; then
        return 0
    fi
    
    # Check if extensions directory exists - skip if not
    if [ ! -d "$VSCODE_EXTENSIONS_DIR" ]; then
        return 0
    fi
    
    # Locate extensions.json file for metadata lookup
    client_extensions_json="$user_home/.vscode/extensions/extensions.json"
    server_extensions_json="$user_home/.vscode-server/extensions/extensions.json"
    
    # Chunked extension processing
    chunk_size=$CHUNK_SIZE
    current_chunk=0
    extensions_in_chunk=0
    total_extensions_processed=0
    extensions_array=""
    first_in_chunk=1
    
    # Process client extensions
    for ext_path in "$VSCODE_EXTENSIONS_DIR"/*; do
        if [ ! -d "$ext_path" ]; then
            continue
        fi
        
        ext_name=$(basename "$ext_path")
        
        # Skip hidden directories
        case "$ext_name" in
            .*)
                continue
                ;;
        esac
        
        # Add separator if not first
        if [ "$first_in_chunk" = "0" ]; then
            extensions_array="${extensions_array},"
        fi
        first_in_chunk=0
        
        # Parse package.json
        package_json_file="$ext_path/package.json"
        parse_extension_package_json "$ext_name" "$package_json_file"
        
        # Check for executable files
        ext_contains_executables=$(check_contains_executables "$ext_path")
        
        # Extract base extension ID for metadata lookup (strip version and platform suffix)
        # Example: github.copilot-1.388.0 → github.copilot
        # Example: ms-python.debugpy-2025.16.0-darwin-arm64 → ms-python.debugpy
        base_ext_id=$(echo "$ext_name" | sed 's/-[0-9][0-9]*\.[0-9].*$//')
        
        # Lookup extension metadata from extensions.json
        lookup_extension_metadata "$base_ext_id" "$client_extensions_json"
        
        # Escape package.json path for JSON
        safe_package_json_path=$(echo "$package_json_file" | sed 's/\\/\\\\/g; s/"/\\"/g')
        
        # Build extension entry with new metadata fields
        extensions_array="${extensions_array}{\"extension_id\":\"$ext_name\",\"name\":\"$ext_internal_name\",\"display_name\":\"$ext_display_name\",\"publisher\":\"$publisher_name\",\"version\":\"$ext_version\",\"target\":\"client\",\"install_type\":\"user\",\"install_source\":\"$EXT_INSTALL_SOURCE\",\"installed_timestamp\":\"$EXT_INSTALLED_TIMESTAMP\",\"is_prerelease\":$EXT_IS_PRERELEASE,\"is_pinned_version\":$EXT_IS_PINNED_VERSION,\"vscode_engine\":\"$ext_vscode_engine\",\"repository\":\"$ext_repository\",\"package_json_path\":\"$safe_package_json_path\",\"activation_events\":$ext_activation_events,\"workspace_trust_mode\":\"$ext_workspace_trust_mode\",\"contains_executables\":$ext_contains_executables,\"extension_dependencies\":$ext_dependencies}"
        
        extensions_in_chunk=$((extensions_in_chunk + 1))
        total_extensions_processed=$((total_extensions_processed + 1))
        
        # Output chunk when we reach chunk_size
        if [ "$extensions_in_chunk" -eq "$chunk_size" ]; then
            output_extensions_chunk "$target_user" "$current_chunk" "$total_extensions_processed" "$chunk_size"
            # Reset for next chunk
            current_chunk=$((current_chunk + 1))
            extensions_in_chunk=0
            extensions_array=""
            first_in_chunk=1
        fi
    done
    
    # Process server extensions (if directory exists)
    server_ext_dir="$user_home/.vscode-server/extensions"
    if [ -d "$server_ext_dir" ]; then
        for ext_path in "$server_ext_dir"/*; do
            if [ ! -d "$ext_path" ]; then
                continue
            fi
            
            ext_name=$(basename "$ext_path")
            
            # Skip hidden directories
            case "$ext_name" in
                .*)
                    continue
                    ;;
            esac
            
            # Add separator if not first
            if [ "$first_in_chunk" = "0" ]; then
                extensions_array="${extensions_array},"
            fi
            first_in_chunk=0
            
            # Parse package.json
            package_json_file="$ext_path/package.json"
            parse_extension_package_json "$ext_name" "$package_json_file"
            
            # Check for executable files
            ext_contains_executables=$(check_contains_executables "$ext_path")
            
            # Extract base extension ID for metadata lookup (strip version and platform suffix)
            base_ext_id=$(echo "$ext_name" | sed 's/-[0-9][0-9]*\.[0-9].*$//')
            
            # Lookup extension metadata from server extensions.json
            lookup_extension_metadata "$base_ext_id" "$server_extensions_json"
            
            # Escape package.json path for JSON
            safe_package_json_path=$(echo "$package_json_file" | sed 's/\\/\\\\/g; s/"/\\"/g')
            
            # Build extension entry with target="server" and new metadata fields
            extensions_array="${extensions_array}{\"extension_id\":\"$ext_name\",\"name\":\"$ext_internal_name\",\"display_name\":\"$ext_display_name\",\"publisher\":\"$publisher_name\",\"version\":\"$ext_version\",\"target\":\"server\",\"install_type\":\"user\",\"install_source\":\"$EXT_INSTALL_SOURCE\",\"installed_timestamp\":\"$EXT_INSTALLED_TIMESTAMP\",\"is_prerelease\":$EXT_IS_PRERELEASE,\"is_pinned_version\":$EXT_IS_PINNED_VERSION,\"vscode_engine\":\"$ext_vscode_engine\",\"repository\":\"$ext_repository\",\"package_json_path\":\"$safe_package_json_path\",\"activation_events\":$ext_activation_events,\"workspace_trust_mode\":\"$ext_workspace_trust_mode\",\"contains_executables\":$ext_contains_executables,\"extension_dependencies\":$ext_dependencies}"
            
            extensions_in_chunk=$((extensions_in_chunk + 1))
            total_extensions_processed=$((total_extensions_processed + 1))
            
            # Output chunk when we reach chunk_size
            if [ "$extensions_in_chunk" -eq "$chunk_size" ]; then
                output_extensions_chunk "$target_user" "$current_chunk" "$total_extensions_processed" "$chunk_size"
                # Reset for next chunk
                current_chunk=$((current_chunk + 1))
                extensions_in_chunk=0
                extensions_array=""
                first_in_chunk=1
            fi
        done
    fi
    
    # Output remaining extensions if any
    if [ "$extensions_in_chunk" -gt 0 ]; then
        output_extensions_chunk "$target_user" "$current_chunk" "$total_extensions_processed" "$chunk_size"
    fi
}

output_extensions_chunk() {
    chunk_user="$1"
    chunk_number="$2"
    total_count="$3"
    chunk_size="$4"
    
    # Calculate total chunks
    chunk_total=$(calculate_total_chunks "$total_count" "$chunk_size")
    
    # Output chunk
    printf '{"timestamp":"%s","user":"%s","product_name":"%s","chunk_set_id_extensions":"%s","chunk":%d,"chunk_total":%d,"items":[%s]}\n' \
        "$TIMESTAMP" "$chunk_user" "$CURRENT_PRODUCT_NAME" "$CHUNK_SET_ID_EXTENSIONS" "$chunk_number" "$chunk_total" "$extensions_array"
}

# Process installation for the CURRENT variant only
# Uses CURRENT_VARIANT global set by detect_variant_paths()
process_installation() {
    target_user="$1"
    
    if [ "$COLLECT_INSTALLATION" = "0" ]; then
        return 0
    fi
    
    user_home=$(get_user_home "$target_user")
    if [ $? -ne 0 ] || [ -z "$user_home" ]; then
        return 0
    fi

    # Initialize installation array and deduplication tracker
    installations_array=""
    array_first=1
    SEEN_INSTALL_PATHS=""
    
    # Get variant-specific installation paths based on CURRENT_VARIANT
    case "$CURRENT_VARIANT" in
        stable)
            # macOS
            process_variant_installation "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
                "/Applications/Visual Studio Code.app" "Visual Studio Code" "$target_user" "$user_home"
            # Linux /usr/bin
            process_variant_installation "/usr/bin/code" "/usr/share/code" "Visual Studio Code" "$target_user" "$user_home"
            # Linux /usr/local/bin
            process_variant_installation "/usr/local/bin/code" "/opt/visual-studio-code" "Visual Studio Code" "$target_user" "$user_home"
            
            # VS Code Server installations (only for stable variant)
            server_base_dir="$user_home/.vscode-server"
            if [ -d "$server_base_dir" ]; then
                # Check for CLI-based server installations
                if [ -d "$server_base_dir/cli/servers" ]; then
                    for server_dir in "$server_base_dir/cli/servers"/Stable-*; do
                        if [ -d "$server_dir" ] && [ -f "$server_dir/server/product.json" ]; then
                            process_server_installation "$server_dir" "$server_dir/server/product.json" "$target_user"
                        fi
                    done
                fi
                # Check for legacy server installations
                if [ -d "$server_base_dir/bin" ]; then
                    for server_dir in "$server_base_dir/bin"/*; do
                        if [ -d "$server_dir" ] && [ -f "$server_dir/product.json" ]; then
                            process_server_installation "$server_dir" "$server_dir/product.json" "$target_user"
                        fi
                    done
                fi
            fi
            ;;
        insiders)
            # macOS
            process_variant_installation "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders" \
                "/Applications/Visual Studio Code - Insiders.app" "Visual Studio Code - Insiders" "$target_user" "$user_home"
            # Linux /usr/bin
            process_variant_installation "/usr/bin/code-insiders" "/usr/share/code-insiders" "Visual Studio Code - Insiders" "$target_user" "$user_home"
            # Linux /usr/local/bin
            process_variant_installation "/usr/local/bin/code-insiders" "/opt/visual-studio-code-insiders" "Visual Studio Code - Insiders" "$target_user" "$user_home"
            ;;
        vscodium)
            # macOS
            process_variant_installation "/Applications/VSCodium.app/Contents/Resources/app/bin/codium" \
                "/Applications/VSCodium.app" "VSCodium" "$target_user" "$user_home"
            # Linux /usr/bin
            process_variant_installation "/usr/bin/codium" "/usr/share/vscodium" "VSCodium" "$target_user" "$user_home"
            # Linux /usr/local/bin
            process_variant_installation "/usr/local/bin/codium" "/opt/vscodium" "VSCodium" "$target_user" "$user_home"
            ;;
        cursor)
            # macOS
            process_variant_installation "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" \
                "/Applications/Cursor.app" "Cursor" "$target_user" "$user_home"
            # Linux /usr/bin
            process_variant_installation "/usr/bin/cursor" "/opt/cursor" "Cursor" "$target_user" "$user_home"
            # Linux /usr/local/bin
            process_variant_installation "/usr/local/bin/cursor" "/opt/cursor" "Cursor" "$target_user" "$user_home"
            ;;
        code-oss)
            # Linux /usr/bin (Code-OSS is typically Linux only)
            process_variant_installation "/usr/bin/code-oss" "/usr/share/code-oss" "Code - OSS" "$target_user" "$user_home"
            # Linux /usr/local/bin
            process_variant_installation "/usr/local/bin/code-oss" "/opt/code-oss" "Code - OSS" "$target_user" "$user_home"
            ;;
        windsurf)
            # macOS
            process_variant_installation "/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf" \
                "/Applications/Windsurf.app" "Windsurf" "$target_user" "$user_home"
            # Linux /usr/bin
            process_variant_installation "/usr/bin/windsurf" "/opt/Windsurf" "Windsurf" "$target_user" "$user_home"
            # Linux /usr/local/bin
            process_variant_installation "/usr/local/bin/windsurf" "/opt/Windsurf" "Windsurf" "$target_user" "$user_home"
            ;;
    esac
    
    # Only output if we found at least one installation
    if [ -n "$installations_array" ]; then
        printf '{"timestamp":"%s","user":"%s","product_name":"%s","items":[%s]}\n' \
            "$TIMESTAMP" "$target_user" "$CURRENT_PRODUCT_NAME" "$installations_array"
    fi
}

# Process a single VS Code variant installation
# Args: executable_path install_dir product_name target_user user_home
process_variant_installation() {
    var_executable="$1"
    var_install_dir="$2"
    var_product_name="$3"
    var_user="$4"
    var_user_home="$5"
    
    # Fast exit if executable doesn't exist
    [ ! -x "$var_executable" ] && return 0
    
    # Fast exit if install directory doesn't exist (prevents symlink duplicates)
    [ ! -d "$var_install_dir" ] && return 0
    
    # Deduplication: Skip if we've already processed this install_path
    case "$SEEN_INSTALL_PATHS" in
        *"|$var_install_dir|"*) return 0 ;;
    esac
    SEEN_INSTALL_PATHS="${SEEN_INSTALL_PATHS}|$var_install_dir|"
    
    # Build installation info
    vscode_info=""
    first=1
    
    # Get version info from executable
    version_output=$("$var_executable" --version 2>/dev/null)
    version=$(echo "$version_output" | sed -n '1p')
    commit=$(echo "$version_output" | sed -n '2p')
    architecture=$(echo "$version_output" | sed -n '3p')
    
    if [ -n "$version" ]; then
        vscode_info="\"version\":\"$version\""
        first=0
        
        if [ -n "$commit" ]; then
            vscode_info="${vscode_info},\"commit_id\":\"$commit\""
        fi
        
        if [ -n "$architecture" ]; then
            vscode_info="${vscode_info},\"architecture\":\"$architecture\""
        fi
    fi
    
    # Add executable path
    if [ "$first" = "0" ]; then
        vscode_info="${vscode_info},"
    fi
    safe_exe_path=$(echo "$var_executable" | sed 's/\\/\\\\/g; s/"/\\"/g')
    vscode_info="${vscode_info}\"executable_path\":\"$safe_exe_path\""
    first=0
    
    # Add target field
    vscode_info="${vscode_info},\"target\":\"client\""
    
    # Add install path if directory exists
    if [ -d "$var_install_dir" ]; then
        safe_install_dir=$(echo "$var_install_dir" | sed 's/\\/\\\\/g; s/"/\\"/g')
        vscode_info="${vscode_info},\"install_path\":\"$safe_install_dir\""
    fi
    
    # Determine install type
    install_type="user"
    case "$var_install_dir" in
        /Applications/*|/usr/share/*|/usr/local/*|/opt/*)
            install_type="system"
            ;;
    esac
    vscode_info="${vscode_info},\"install_type\":\"$install_type\""
    
    # Add product name
    vscode_info="${vscode_info},\"product_name\":\"$var_product_name\""
    
    # Extract update_url from product.json
    update_url="unknown"
    product_json=""
    
    # macOS .app bundle structure
    if [ -f "$var_install_dir/Contents/Resources/app/product.json" ]; then
        product_json="$var_install_dir/Contents/Resources/app/product.json"
    # Standard Linux structure
    elif [ -f "$var_install_dir/resources/app/product.json" ]; then
        product_json="$var_install_dir/resources/app/product.json"
    fi
    
    if [ -n "$product_json" ] && [ -f "$product_json" ]; then
        update_url=$(grep -m1 '"updateUrl"' "$product_json" 2>/dev/null | sed 's/.*"updateUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        [ -z "$update_url" ] && update_url="unknown"
    fi
    vscode_info="${vscode_info},\"update_url\":\"$update_url\""
    
    # Add user data and extensions directories (based on variant)
    case "$var_product_name" in
        "Visual Studio Code")
            case "$(uname -s)" in
                Darwin) user_data_dir="$var_user_home/Library/Application Support/Code/User" ;;
                *) user_data_dir="$var_user_home/.config/Code/User" ;;
            esac
            extensions_dir="$var_user_home/.vscode/extensions"
            ;;
        "Visual Studio Code - Insiders")
            case "$(uname -s)" in
                Darwin) user_data_dir="$var_user_home/Library/Application Support/Code - Insiders/User" ;;
                *) user_data_dir="$var_user_home/.config/Code - Insiders/User" ;;
            esac
            extensions_dir="$var_user_home/.vscode-insiders/extensions"
            ;;
        "VSCodium")
            case "$(uname -s)" in
                Darwin) user_data_dir="$var_user_home/Library/Application Support/VSCodium/User" ;;
                *) user_data_dir="$var_user_home/.config/VSCodium/User" ;;
            esac
            extensions_dir="$var_user_home/.vscode-oss/extensions"
            ;;
        "Code - OSS")
            case "$(uname -s)" in
                Darwin) user_data_dir="$var_user_home/Library/Application Support/Code - OSS/User" ;;
                *) user_data_dir="$var_user_home/.config/Code - OSS/User" ;;
            esac
            extensions_dir="$var_user_home/.vscode-oss/extensions"
            ;;
        "Cursor")
            case "$(uname -s)" in
                Darwin) user_data_dir="$var_user_home/Library/Application Support/Cursor/User" ;;
                *) user_data_dir="$var_user_home/.config/Cursor/User" ;;
            esac
            extensions_dir="$var_user_home/.cursor/extensions"
            ;;
        "Windsurf")
            case "$(uname -s)" in
                Darwin) user_data_dir="$var_user_home/Library/Application Support/Windsurf/User" ;;
                *) user_data_dir="$var_user_home/.config/Windsurf/User" ;;
            esac
            extensions_dir="$var_user_home/.windsurf/extensions"
            ;;
        *)
            user_data_dir="$VSCODE_USER_DIR"
            extensions_dir="$VSCODE_EXTENSIONS_DIR"
            ;;
    esac
    
    safe_user_dir=$(echo "$user_data_dir" | sed 's/\\/\\\\/g; s/"/\\"/g')
    vscode_info="${vscode_info},\"user_data_dir\":\"$safe_user_dir\""
    
    safe_ext_dir=$(echo "$extensions_dir" | sed 's/\\/\\\\/g; s/"/\\"/g')
    vscode_info="${vscode_info},\"extensions_dir\":\"$safe_ext_dir\""
    
    # Add to installations array
    if [ "$array_first" = "0" ]; then
        installations_array="${installations_array},"
    fi
    installations_array="${installations_array}{${vscode_info}}"
    array_first=0
}

# Process server installation
process_server_installation() {
    server_path="$1"
    product_json_path="$2"
    server_user="$3"
    
    # Parse product.json for server details
    server_version=$(grep -m1 '"version"' "$product_json_path" 2>/dev/null | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    server_commit=$(grep -m1 '"commit"' "$product_json_path" 2>/dev/null | sed 's/.*"commit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    server_quality=$(grep -m1 '"quality"' "$product_json_path" 2>/dev/null | sed 's/.*"quality"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    server_update_url=$(grep -m1 '"updateUrl"' "$product_json_path" 2>/dev/null | sed 's/.*"updateUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    
    # Build server installation item
    server_info=""
    server_first=1
    
    if [ -n "$server_version" ]; then
        server_info="${server_info}\"version\":\"$server_version\""
        server_first=0
    fi
    
    if [ -n "$server_commit" ]; then
        if [ "$server_first" = "0" ]; then
            server_info="${server_info},"
        fi
        server_info="${server_info}\"commit_id\":\"$server_commit\""
        server_first=0
    fi
    
    # Add target field
    if [ "$server_first" = "0" ]; then
        server_info="${server_info},"
    fi
    server_info="${server_info}\"target\":\"server\""
    server_first=0
    
    # Add install path
    if [ "$server_first" = "0" ]; then
        server_info="${server_info},"
    fi
    safe_server_path=$(echo "$server_path" | sed 's/\\/\\\\/g; s/"/\\"/g')
    server_info="${server_info}\"install_path\":\"$safe_server_path\""
    
    # Add server executable path
    server_executable=""
    if [ -f "$server_path/server/bin/code-server" ]; then
        server_executable="$server_path/server/bin/code-server"
    elif [ -f "$server_path/bin/code-server" ]; then
        server_executable="$server_path/bin/code-server"
    fi
    
    if [ -n "$server_executable" ]; then
        safe_server_executable=$(echo "$server_executable" | sed 's/\\/\\\\/g; s/"/\\"/g')
        server_info="${server_info},\"executable_path\":\"$safe_server_executable\""
    fi
    
    # Determine product name (uses client name; target field indicates server)
    server_product="Visual Studio Code"
    
    if [ "$server_quality" = "insider" ]; then
        server_product="Visual Studio Code - Insiders"
    fi
    
    case "$server_path" in
        *Insiders*|*insiders*)
            server_product="Visual Studio Code - Insiders"
            ;;
    esac
    
    server_info="${server_info},\"product_name\":\"$server_product\""
    
    # Add install type
    server_info="${server_info},\"install_type\":\"user\""
    
    # Add update_url
    update_url="unknown"
    if [ -n "$server_update_url" ]; then
        update_url="$server_update_url"
    fi
    server_info="${server_info},\"update_url\":\"$update_url\""
    
    # Detect server extensions directory
    server_ext_dir=""
    user_home=$(get_user_home "$server_user")
    if [ -d "$user_home/.vscode-server/extensions" ]; then
        server_ext_dir="$user_home/.vscode-server/extensions"
    elif [ -d "$server_path/extensions" ]; then
        server_ext_dir="$server_path/extensions"
    fi
    
    if [ -n "$server_ext_dir" ]; then
        safe_server_ext_dir=$(echo "$server_ext_dir" | sed 's/\\/\\\\/g; s/"/\\"/g')
        server_info="${server_info},\"extensions_dir\":\"$safe_server_ext_dir\""
    fi
    
    # Add to installations array
    if [ "$array_first" = "0" ]; then
        installations_array="${installations_array},"
    fi
    installations_array="${installations_array}{${server_info}}"
    array_first=0
}

lookup_ssh_info() {
    host="$1"
    target_user="$2"
    
    # Default values
    SSH_USER_RESULT="unknown"
    SSH_AUTH_RESULT="password"
    
    user_home=$(get_user_home "$target_user")
    if [ $? -ne 0 ]; then
        return 0
    fi
    
    user_ssh_config="$user_home/.ssh/config"
    
    # Try to read SSH config
    if [ -f "$user_ssh_config" ] && [ -r "$user_ssh_config" ]; then
        in_matching_block=0
        found_user=""
        found_auth=""
        
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments
            case "$line" in
                ""|\#*) continue ;;
            esac
            
            # Check for Host or Match directive (starts new block)
            if echo "$line" | grep -qE "^(Host|Match) "; then
                # If we were in a matching block and found data, stop (first match wins in SSH)
                if [ "$in_matching_block" = "1" ]; then
                    break
                fi
                
                in_matching_block=0
                
                # Check if this Host line matches our target
                if echo "$line" | grep -q "^Host "; then
                    # Extract host patterns from the line
                    host_patterns=$(echo "$line" | sed 's/^Host[[:space:]]*//')
                    # Check each pattern (space-separated)
                    for pattern in $host_patterns; do
                        if [ "$pattern" = "$host" ]; then
                            in_matching_block=1
                            break
                        fi
                        # Handle wildcard * (matches all)
                        if [ "$pattern" = "*" ]; then
                            in_matching_block=1
                            break
                        fi
                    done
                fi
                continue
            fi
            
            # Only process settings if we're in a matching block
            if [ "$in_matching_block" = "1" ]; then
                # Extract User (only if not already found)
                if [ -z "$found_user" ] && echo "$line" | grep -q "^[[:space:]]*User "; then
                    user_val=$(echo "$line" | sed 's/^[[:space:]]*User[[:space:]]*//' | awk '{print $1}')
                    if [ -n "$user_val" ]; then
                        found_user="$user_val"
                    fi
                fi
                
                # Extract auth method from IdentityFile (only if not already found)
                if [ -z "$found_auth" ] && echo "$line" | grep -q "^[[:space:]]*IdentityFile "; then
                    found_auth="publickey"
                fi
                
                # Extract PreferredAuthentications (overrides IdentityFile)
                if echo "$line" | grep -q "^[[:space:]]*PreferredAuthentications "; then
                    auth_val=$(echo "$line" | sed 's/^[[:space:]]*PreferredAuthentications[[:space:]]*//' | awk '{print $1}')
                    if [ -n "$auth_val" ]; then
                        found_auth="$auth_val"
                    fi
                fi
            fi
        done < "$user_ssh_config"
        
        # Apply found values
        if [ -n "$found_user" ]; then
            SSH_USER_RESULT="$found_user"
        fi
        if [ -n "$found_auth" ]; then
            SSH_AUTH_RESULT="$found_auth"
        fi
    fi
}

url_decode() {
    input="$1"
    # Use printf and sed for URL decoding
    echo "$input" | sed 's/%2B/+/g; s/%20/ /g; s/%2F/\//g; s/%3A/:/g; s/%40/@/g'
}

# Normalize Windows-style paths in SSH remote workspace paths
normalize_windows_path() {
    input_path="$1"
    # Check if path matches Windows pattern: /X:/... where X is a drive letter
    if echo "$input_path" | grep -qE '^/[a-zA-Z]:'; then
        # Remove leading slash, uppercase drive letter, convert / to backslash
        drive_letter=$(printf '%s' "$input_path" | cut -c2 | tr 'a-z' 'A-Z')
        rest_of_path=$(printf '%s' "$input_path" | cut -c3-)
        # Convert forward slashes to backslashes using tr (avoids escape issues with sed)
        rest_of_path=$(printf '%s' "$rest_of_path" | tr '/' '\\')
        printf '%s%s' "$drive_letter" "$rest_of_path"
    else
        # Not a Windows path, return as-is
        printf '%s' "$input_path"
    fi
}

# Decode hex string to ASCII (POSIX compliant)
# Used for dev-container hex-encoded paths
hex_decode() {
    hex_input="$1"
    result=""
    i=0
    len=${#hex_input}
    while [ $i -lt $len ]; do
        # Get two hex characters
        hex_byte=$(echo "$hex_input" | cut -c$((i+1))-$((i+2)))
        if [ -n "$hex_byte" ] && [ ${#hex_byte} -eq 2 ]; then
            # Convert hex to decimal then to character using printf
            # POSIX compliant: printf with octal escape
            decimal=$(printf '%d' "0x$hex_byte" 2>/dev/null)
            if [ -n "$decimal" ] && [ "$decimal" -ge 32 ] && [ "$decimal" -le 126 ]; then
                char=$(printf "\\$(printf '%03o' "$decimal")")
                result="${result}${char}"
            fi
        fi
        i=$((i + 2))
    done
    echo "$result"
}

# Extract container name from dev-container hex data
# Format: dev-container+<hex_encoded_path>
# The hex decodes to the local workspace path (e.g., /Users/user/project)
get_container_info_from_hex() {
    hex_data="$1"
    container_type="$2"  # "attached" or "dev"
    
    # Decode hex to get content
    decoded_content=$(hex_decode "$hex_data")
    
    if [ "$container_type" = "attached" ]; then
        # attached-container format: {"containerName":"/container_name","settings":{...}}
        # Extract containerName value from JSON using sed
        CONTAINER_NAME=$(echo "$decoded_content" | sed -n 's/.*"containerName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        # Remove leading slash if present
        CONTAINER_NAME=$(echo "$CONTAINER_NAME" | sed 's|^/||')
        CONTAINER_LOCAL_PATH=""
    else
        # dev-container formats
        if echo "$decoded_content" | grep -q '"hostPath"'; then
            # JSON format - extract hostPath
            CONTAINER_LOCAL_PATH=$(echo "$decoded_content" | sed -n 's/.*"hostPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            CONTAINER_NAME=$(basename "$CONTAINER_LOCAL_PATH" 2>/dev/null)
        else
            # Plain path format
            CONTAINER_LOCAL_PATH="$decoded_content"
            CONTAINER_NAME=$(basename "$CONTAINER_LOCAL_PATH" 2>/dev/null)
        fi
    fi
    
    if [ -z "$CONTAINER_NAME" ]; then
        CONTAINER_NAME="unknown"
    fi
}

output_session_chunk() {
    chunk_user="$1"
    chunk_number="$2"
    total_count="$3"
    chunk_size="$4"
    
    # Calculate total chunks
    chunk_total=$(calculate_total_chunks "$total_count" "$chunk_size")
    
    # Close sessions array and output chunk
    printf '{"timestamp":"%s","user":"%s","product_name":"%s","chunk_set_id_sessions":"%s","chunk":%d,"chunk_total":%d,"items":[%s]}\n' \
        "$TIMESTAMP" "$chunk_user" "$CURRENT_PRODUCT_NAME" "$CHUNK_SET_ID_SESSIONS" "$chunk_number" "$chunk_total" "$sessions_array"
}

# Process sessions
process_active_session() {
    target_user="$1"
    
    if [ "$COLLECT_ACTIVE_SESSION" = "0" ]; then
        return 0
    fi
    
    storage_file="$VSCODE_USER_DIR/globalStorage/storage.json"
    if [ ! -f "$storage_file" ]; then
        return 0
    fi
    
    # Security check
    check_security_patterns "$storage_file" || return 0
    
    # Check if VS Code is running (detect Code process)
    VSCODE_RUNNING=0
    case "$(uname -s)" in
        Darwin)
            # macOS: Check for Visual Studio Code.app process
            if pgrep -f "Visual Studio Code.app" >/dev/null 2>&1 || pgrep -f "Code Helper" >/dev/null 2>&1; then
                VSCODE_RUNNING=1
            fi
            ;;
        Linux)
            # Linux: Check for code process
            if pgrep -x "code" >/dev/null 2>&1 || pgrep -f "VSCode" >/dev/null 2>&1; then
                VSCODE_RUNNING=1
            fi
            ;;
        *)
            # Other Unix-like systems
            if pgrep -f "code" >/dev/null 2>&1; then
                VSCODE_RUNNING=1
            fi
            ;;
    esac
    
    # Initialize chunking variables
    chunk_size=$CHUNK_SIZE
    current_chunk=0
    sessions_in_chunk=0
    total_sessions_processed=0
    sessions_array=""
    sessions_first=1
    seen_sessions=""
    
    # Helper function to check if session was already seen (deduplication)
    session_seen() {
        session_key="$1"
        if echo "$seen_sessions" | grep -qF "|${session_key}|"; then
            return 0  # Already seen
        else
            seen_sessions="${seen_sessions}|${session_key}|"
            return 1  # Not seen yet
        fi
    }
    
    # Extract lastActiveWindow for focused session
    # Try new format: windowsState.lastActiveWindow
    # Try old format: lastActiveWindow (direct)
    last_active_folder=""
    
    # New format: Extract from windowsState.lastActiveWindow
    if grep -q '"windowsState"' "$storage_file" 2>/dev/null; then
        last_active_folder=$(grep -A 20 '"windowsState"[[:space:]]*:[[:space:]]*{' "$storage_file" 2>/dev/null | \
            grep -A 10 '"lastActiveWindow"[[:space:]]*:[[:space:]]*{' | \
            grep '"folder"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | \
            sed 's/.*"folder"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi
    
    # Fall back to old format if not found
    if [ -z "$last_active_folder" ]; then
        last_active_folder=$(grep -A 10 '"lastActiveWindow"[[:space:]]*:[[:space:]]*{' "$storage_file" 2>/dev/null | \
            grep '"folder"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | \
            sed 's/.*"folder"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi
    
    # Process focused window if found
    if [ -n "$last_active_folder" ]; then
        # URL decode
        decoded_path=$(url_decode "$last_active_folder")
        
        # Parse connection info
        connection_type="local"
        remote_host=""
        auth_method="local"
        session_user="$target_user"
        
        if echo "$decoded_path" | grep -q "vscode-remote://"; then
            if echo "$decoded_path" | grep -q "ssh-remote"; then
                connection_type="ssh-remote"
                remote_host=$(echo "$decoded_path" | sed 's/.*ssh-remote+\([^/]*\).*/\1/')
                auth_method="publickey"
                session_user="unknown"
                # Lookup SSH config
                lookup_ssh_info "$remote_host" "$target_user"
                if [ "$SSH_USER_RESULT" != "unknown" ]; then
                    session_user="$SSH_USER_RESULT"
                    auth_method="$SSH_AUTH_RESULT"
                fi
                # Extract workspace path (everything after hostname/)
                workspace_suffix=$(echo "$decoded_path" | sed 's|.*ssh-remote+[^/]*/||')
                if [ -n "$workspace_suffix" ]; then
                    decoded_path="/$workspace_suffix"
                    # Normalize Windows paths
                    decoded_path=$(normalize_windows_path "$decoded_path")
                else
                    decoded_path=""
                fi
            elif echo "$decoded_path" | grep -q "dev-container"; then
                connection_type="dev-container"
                auth_method="docker"
                session_user="unknown"
                # Extract hex data and workspace path from dev-container+HEX/path format
                hex_data=$(echo "$decoded_path" | sed 's|.*dev-container+\([^/]*\).*|\1|')
                get_container_info_from_hex "$hex_data" "dev"
                remote_host="$CONTAINER_NAME"
                # Extract workspace path (everything after hex/)
                workspace_suffix=$(echo "$decoded_path" | sed 's|.*dev-container+[^/]*/||')
                if [ -n "$workspace_suffix" ]; then
                    decoded_path="/$workspace_suffix"
                else
                    decoded_path="$CONTAINER_LOCAL_PATH"
                fi
            elif echo "$decoded_path" | grep -q "attached-container"; then
                connection_type="attached-container"
                auth_method="docker"
                session_user="unknown"
                # Extract hex data from attached-container+HEX format
                hex_data=$(echo "$decoded_path" | sed 's|.*attached-container+\([^/]*\).*|\1|')
                get_container_info_from_hex "$hex_data" "attached"
                remote_host="$CONTAINER_NAME"
                # Extract workspace path (everything after hex/)
                workspace_suffix=$(echo "$decoded_path" | sed 's|.*attached-container+[^/]*/||')
                if [ -n "$workspace_suffix" ]; then
                    decoded_path="/$workspace_suffix"
                else
                    decoded_path=""
                fi
            elif echo "$decoded_path" | grep -q "wsl"; then
                connection_type="wsl"
                remote_host=$(echo "$decoded_path" | sed 's/.*wsl+\([^/]*\).*/\1/')
                auth_method="local"
                session_user="unknown"
                # Extract workspace path (everything after instance/)
                workspace_suffix=$(echo "$decoded_path" | sed 's|.*wsl+[^/]*/||')
                if [ -n "$workspace_suffix" ]; then
                    decoded_path="/$workspace_suffix"
                else
                    decoded_path=""
                fi
            fi
        else
            # Strip file:// prefix from local paths
            decoded_path=$(printf '%s' "$decoded_path" | sed 's|^file://||')
        fi
        
        # Dedup check
        session_key="${connection_type}:${remote_host}:${decoded_path}"
        if ! session_seen "$session_key"; then
            # Add separator if not first
            if [ "$sessions_first" = "0" ]; then
                sessions_array="${sessions_array},"
            fi
            sessions_first=0
            
            # Escape for JSON
            safe_storage=$(escape_json_string "$storage_file")
            safe_path=$(escape_json_string "$decoded_path")
            safe_host=$(escape_json_string "$remote_host")
            safe_user=$(escape_json_string "$session_user")
            safe_auth=$(escape_json_string "$auth_method")
            safe_conn=$(escape_json_string "$connection_type")
            
            # Override is_active if VS Code is not running
            if [ "$VSCODE_RUNNING" = "1" ]; then
                session_is_active="true"
            else
                session_is_active="false"
            fi
            
            # Add focused session (conditionally include remote_host for non-local connections)
            if [ -n "$remote_host" ]; then
                sessions_array="${sessions_array}{\"storage_file_path\":\"$safe_storage\",\"connection_type\":\"$safe_conn\",\"remote_host\":\"$safe_host\",\"user\":\"$safe_user\",\"auth_method\":\"$safe_auth\",\"window_type\":\"folder\",\"workspace_path\":\"$safe_path\",\"is_active\":$session_is_active}"
            else
                sessions_array="${sessions_array}{\"storage_file_path\":\"$safe_storage\",\"connection_type\":\"$safe_conn\",\"user\":\"$safe_user\",\"auth_method\":\"$safe_auth\",\"window_type\":\"folder\",\"workspace_path\":\"$safe_path\",\"is_active\":$session_is_active}"
            fi
            
            sessions_in_chunk=$((sessions_in_chunk + 1))
            total_sessions_processed=$((total_sessions_processed + 1))
            
            # Output chunk when we reach chunk_size
            if [ "$sessions_in_chunk" -eq "$chunk_size" ]; then
                output_session_chunk "$target_user" "$current_chunk" "$total_sessions_processed" "$chunk_size"
                # Reset for next chunk
                current_chunk=$((current_chunk + 1))
                sessions_in_chunk=0
                sessions_array=""
                sessions_first=1
            fi
        fi
    fi
    
    # Extract openedWindows for active sessions (within windowsState)
    # These are windows currently open but not necessarily focused
    if grep -q '"openedWindows"' "$storage_file" 2>/dev/null; then
        # Extract all folder paths from openedWindows with their remote authorities
        # Use portable approach without advanced awk features
        opened_windows_raw=$(grep -A 5000 '"openedWindows"' "$storage_file" 2>/dev/null | \
            awk '
                BEGIN { in_array=0; in_obj=0; depth=0; remote=""; folder=""; line_num=0 }
                /"openedWindows"[[:space:]]*:[[:space:]]*\[/ { in_array=1; next }
                in_array {
                    # Track object depth
                    if ($0 ~ /{/) { in_obj=1; depth++ }
                    if ($0 ~ /}/) { depth-- }
                    
                    # Collect lines within object
                    if (in_obj) {
                        if ($0 ~ /"remoteAuthority"/) { remote_line = $0 }
                        if ($0 ~ /"folder"/) { folder_line = $0 }
                        
                        # When object closes, output both fields
                        if (depth == 0 && $0 ~ /}/) {
                            # Extract remote authority value
                            if (remote_line ~ /"remoteAuthority"/) {
                                split(remote_line, parts, "\"")
                                for (i in parts) {
                                    if (parts[i] ~ /remoteAuthority/ && parts[i+2] != "") {
                                        remote = parts[i+2]
                                        break
                                    }
                                }
                            }
                            # Extract folder value
                            if (folder_line ~ /"folder"/) {
                                split(folder_line, parts, "\"")
                                for (i in parts) {
                                    if (parts[i] ~ /folder/ && parts[i+2] != "") {
                                        folder = parts[i+2]
                                        break
                                    }
                                }
                            }
                            
                            print remote "|" folder
                            remote = ""
                            folder = ""
                            remote_line = ""
                            folder_line = ""
                            in_obj = 0
                        }
                    }
                    
                    # Exit array when we hit the closing bracket
                    if ($0 ~ /\]/ && depth == 0) exit
                }
            ')
        
        # Process each opened window using for loop to avoid subshell
        if [ -n "$opened_windows_raw" ]; then
            IFS='
'
            for window_line in $opened_windows_raw; do
                [ -z "$window_line" ] && continue
                
                # Split remote_authority|folder_path
                remote_authority=$(echo "$window_line" | cut -d'|' -f1)
                folder_path=$(echo "$window_line" | cut -d'|' -f2)
                
                # Skip only if BOTH are empty (need at least one to process)
                [ -z "$remote_authority" ] && [ -z "$folder_path" ] && continue
                
                # URL decode folder path (may be empty for remote connections without workspace)
                decoded_path=""
                if [ -n "$folder_path" ]; then
                    decoded_path=$(url_decode "$folder_path")
                fi
                
                # Parse connection info - check remoteAuthority FIRST (separate field)
                connection_type="local"
                remote_host=""
                auth_method="local"
                session_user="$target_user"
                
                # Check remoteAuthority field first (modern VS Code format)
                if [ -n "$remote_authority" ]; then
                    if echo "$remote_authority" | grep -q "ssh-remote"; then
                        connection_type="ssh-remote"
                        # Extract host from ssh-remote+HOST format
                        remote_host=$(echo "$remote_authority" | sed 's/ssh-remote+//')
                        auth_method="publickey"
                        session_user="unknown"
                        # Lookup SSH config
                        lookup_ssh_info "$remote_host" "$target_user"
                        if [ "$SSH_USER_RESULT" != "unknown" ]; then
                            session_user="$SSH_USER_RESULT"
                            auth_method="$SSH_AUTH_RESULT"
                        fi
                        # Extract workspace path from folder URI (vscode-remote://ssh-remote+HOST/path)
                        if [ -n "$decoded_path" ] && echo "$decoded_path" | grep -q "vscode-remote://"; then
                            workspace_suffix=$(echo "$decoded_path" | sed 's|.*ssh-remote+[^/]*/||')
                            if [ -n "$workspace_suffix" ]; then
                                decoded_path="/$workspace_suffix"
                                # Normalize Windows paths 
                                decoded_path=$(normalize_windows_path "$decoded_path")
                            else
                                decoded_path=""
                            fi
                        fi
                    elif echo "$remote_authority" | grep -q "dev-container"; then
                        connection_type="dev-container"
                        auth_method="docker"
                        session_user="unknown"
                        # Extract hex data from dev-container+HEX format
                        hex_data=$(echo "$remote_authority" | sed 's/dev-container+//')
                        get_container_info_from_hex "$hex_data" "dev"
                        remote_host="$CONTAINER_NAME"
                        # Extract workspace path from folder URI (vscode-remote://dev-container+HEX/path)
                        # The folder field contains the full URI, so extract path after hex/
                        if [ -n "$decoded_path" ] && echo "$decoded_path" | grep -q "vscode-remote://"; then
                            workspace_suffix=$(echo "$decoded_path" | sed 's|.*dev-container+[^/]*/||')
                            if [ -n "$workspace_suffix" ]; then
                                decoded_path="/$workspace_suffix"
                            else
                                decoded_path="$CONTAINER_LOCAL_PATH"
                            fi
                        elif [ -z "$decoded_path" ]; then
                            decoded_path="$CONTAINER_LOCAL_PATH"
                        fi
                    elif echo "$remote_authority" | grep -q "attached-container"; then
                        connection_type="attached-container"
                        auth_method="docker"
                        session_user="unknown"
                        # Extract hex data from attached-container+HEX format
                        hex_data=$(echo "$remote_authority" | sed 's/attached-container+//')
                        get_container_info_from_hex "$hex_data" "attached"
                        remote_host="$CONTAINER_NAME"
                        # Extract workspace path from folder URI (vscode-remote://attached-container+HEX/path)
                        if [ -n "$decoded_path" ] && echo "$decoded_path" | grep -q "vscode-remote://"; then
                            workspace_suffix=$(echo "$decoded_path" | sed 's|.*attached-container+[^/]*/||')
                            if [ -n "$workspace_suffix" ]; then
                                decoded_path="/$workspace_suffix"
                            else
                                decoded_path=""
                            fi
                        elif [ -z "$decoded_path" ]; then
                            decoded_path=""
                        fi
                    elif echo "$remote_authority" | grep -q "wsl"; then
                        connection_type="wsl"
                        # Extract instance from wsl+INSTANCE format
                        remote_host=$(echo "$remote_authority" | sed 's/wsl+//')
                        auth_method="local"
                        session_user="unknown"
                    fi
                    # Strip file:// prefix from local path if present (folder field is local path for remote connections)
                    if [ -n "$decoded_path" ]; then
                        decoded_path=$(printf '%s' "$decoded_path" | sed 's|^file://||')
                    fi
                # Fallback: check if folder path itself contains vscode-remote:// (old format)
                elif [ -n "$decoded_path" ] && echo "$decoded_path" | grep -q "vscode-remote://"; then
                    if echo "$decoded_path" | grep -q "ssh-remote"; then
                        connection_type="ssh-remote"
                        # Extract remote host from vscode-remote://ssh-remote+HOST/path format
                        remote_host=$(printf '%s' "$decoded_path" | sed 's|vscode-remote://ssh-remote+||' | cut -d'/' -f1)
                        # Extract path after the hostname (everything after first /)
                        decoded_path=$(printf '%s' "$decoded_path" | sed 's|vscode-remote://ssh-remote+[^/]*/|/|')
                        # Normalize Windows paths 
                        decoded_path=$(normalize_windows_path "$decoded_path")
                        auth_method="publickey"
                        session_user="unknown"
                        # Lookup SSH config
                        lookup_ssh_info "$remote_host" "$target_user"
                        if [ "$SSH_USER_RESULT" != "unknown" ]; then
                            session_user="$SSH_USER_RESULT"
                            auth_method="$SSH_AUTH_RESULT"
                        fi
                    elif echo "$decoded_path" | grep -q "dev-container"; then
                        connection_type="dev-container"
                        auth_method="docker"
                        session_user="unknown"
                        # Extract hex data from vscode-remote://dev-container+HEX/path format
                        hex_data=$(echo "$decoded_path" | sed 's|vscode-remote://dev-container+||' | cut -d'/' -f1)
                        get_container_info_from_hex "$hex_data" "dev"
                        remote_host="$CONTAINER_NAME"
                        # Extract workspace path (everything after hex/)
                        workspace_suffix=$(echo "$decoded_path" | sed 's|vscode-remote://dev-container+[^/]*/||')
                        if [ -n "$workspace_suffix" ]; then
                            decoded_path="/$workspace_suffix"
                        else
                            decoded_path="$CONTAINER_LOCAL_PATH"
                        fi
                    elif echo "$decoded_path" | grep -q "attached-container"; then
                        connection_type="attached-container"
                        auth_method="docker"
                        session_user="unknown"
                        # Extract hex data from vscode-remote://attached-container+HEX/path format
                        hex_data=$(echo "$decoded_path" | sed 's|vscode-remote://attached-container+||' | cut -d'/' -f1)
                        get_container_info_from_hex "$hex_data" "attached"
                        remote_host="$CONTAINER_NAME"
                        # Extract workspace path (everything after hex/)
                        workspace_suffix=$(echo "$decoded_path" | sed 's|vscode-remote://attached-container+[^/]*/||')
                        if [ -n "$workspace_suffix" ]; then
                            decoded_path="/$workspace_suffix"
                        else
                            decoded_path=""
                        fi
                    elif echo "$decoded_path" | grep -q "wsl"; then
                        connection_type="wsl"
                        # Extract WSL instance name from vscode-remote://wsl+INSTANCE/path format
                        remote_host=$(printf '%s' "$decoded_path" | sed 's|vscode-remote://wsl+||' | cut -d'/' -f1)
                        # Extract path after the instance name
                        decoded_path=$(printf '%s' "$decoded_path" | sed 's|vscode-remote://wsl+[^/]*/|/|')
                        auth_method="local"
                        session_user="unknown"
                    fi
                else
                    # Strip file:// prefix from local paths if present
                    if [ -n "$decoded_path" ]; then
                        decoded_path=$(printf '%s' "$decoded_path" | sed 's|^file://||')
                    fi
                fi
                
                # Create session key for deduplication
                session_key="${connection_type}:${remote_host}:${decoded_path}"
                
                # Dedup check - skip if already seen (focused window was already added)
                if session_seen "$session_key"; then
                    continue
                fi
                
                # Add separator if not first
                if [ "$sessions_first" = "0" ]; then
                    sessions_array="${sessions_array},"
                fi
                sessions_first=0
                
                # Escape for JSON
                safe_storage=$(escape_json_string "$storage_file")
                safe_path=$(escape_json_string "$decoded_path")
                safe_host=$(escape_json_string "$remote_host")
                safe_user=$(escape_json_string "$session_user")
                safe_auth=$(escape_json_string "$auth_method")
                safe_conn=$(escape_json_string "$connection_type")
                
                # Override is_active if VS Code is not running
                if [ "$VSCODE_RUNNING" = "1" ]; then
                    session_is_active="true"
                else
                    session_is_active="false"
                fi
                
                # Add active session (conditionally include remote_host for non-local connections)
                if [ -n "$remote_host" ]; then
                    sessions_array="${sessions_array}{\"storage_file_path\":\"$safe_storage\",\"connection_type\":\"$safe_conn\",\"remote_host\":\"$safe_host\",\"user\":\"$safe_user\",\"auth_method\":\"$safe_auth\",\"window_type\":\"folder\",\"workspace_path\":\"$safe_path\",\"is_active\":$session_is_active}"
                else
                    sessions_array="${sessions_array}{\"storage_file_path\":\"$safe_storage\",\"connection_type\":\"$safe_conn\",\"user\":\"$safe_user\",\"auth_method\":\"$safe_auth\",\"window_type\":\"folder\",\"workspace_path\":\"$safe_path\",\"is_active\":$session_is_active}"
                fi
                
                sessions_in_chunk=$((sessions_in_chunk + 1))
                total_sessions_processed=$((total_sessions_processed + 1))
                
                # Output chunk when we reach chunk_size
                if [ "$sessions_in_chunk" -eq "$chunk_size" ]; then
                    output_session_chunk "$target_user" "$current_chunk" "$total_sessions_processed" "$chunk_size"
                    # Reset for next chunk
                    current_chunk=$((current_chunk + 1))
                    sessions_in_chunk=0
                    sessions_array=""
                    sessions_first=1
                fi
            done
        fi
    fi
    
    # Extract historical folders from backupWorkspaces
    # New format: backupWorkspaces.folders[].folderUri
    # Use command substitution to avoid subshell issue with while-read
    if grep -q '"backupWorkspaces"' "$storage_file" 2>/dev/null; then
        backup_folders=$(grep -A 1000 '"folders"[[:space:]]*:[[:space:]]*\[' "$storage_file" 2>/dev/null | \
            grep -o '"folderUri"[[:space:]]*:[[:space:]]*"[^"]*"' | \
            sed 's/.*"folderUri"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        
        # Process each backup folder using for loop (not while read to avoid subshell)
        IFS='
'
        for folder_path in $backup_folders; do
            [ -z "$folder_path" ] && continue
            
            # URL decode
            decoded_path=$(url_decode "$folder_path")
            
            # Parse connection info
            connection_type="local"
            remote_host=""
            auth_method="local"
            session_user="$target_user"
            
            if echo "$decoded_path" | grep -q "vscode-remote://"; then
                if echo "$decoded_path" | grep -q "ssh-remote"; then
                    connection_type="ssh-remote"
                    # Extract remote host
                    remote_host=$(printf '%s' "$decoded_path" | sed 's|vscode-remote://ssh-remote+||' | cut -d'/' -f1)
                    # Extract path after the hostname
                    decoded_path=$(printf '%s' "$decoded_path" | sed 's|vscode-remote://ssh-remote+[^/]*/|/|')
                    # Normalize Windows paths 
                    decoded_path=$(normalize_windows_path "$decoded_path")
                    auth_method="publickey"
                    session_user="unknown"
                elif echo "$decoded_path" | grep -q "dev-container"; then
                    connection_type="dev-container"
                    auth_method="docker"
                    session_user="unknown"
                    # Extract hex data from vscode-remote://dev-container+HEX/path format
                    hex_data=$(echo "$decoded_path" | sed 's|vscode-remote://dev-container+||' | cut -d'/' -f1)
                    get_container_info_from_hex "$hex_data" "dev"
                    remote_host="$CONTAINER_NAME"
                    # Extract workspace path (everything after hex/)
                    workspace_suffix=$(echo "$decoded_path" | sed 's|vscode-remote://dev-container+[^/]*/||')
                    if [ -n "$workspace_suffix" ]; then
                        decoded_path="/$workspace_suffix"
                    else
                        decoded_path="$CONTAINER_LOCAL_PATH"
                    fi
                elif echo "$decoded_path" | grep -q "attached-container"; then
                    connection_type="attached-container"
                    auth_method="docker"
                    hex_data=$(echo "$decoded_path" | sed 's|vscode-remote://attached-container+||' | cut -d'/' -f1)
                    get_container_info_from_hex "$hex_data" "attached"
                    remote_host="$CONTAINER_NAME"
                    # Extract workspace path (everything after hex/)
                    workspace_suffix=$(echo "$decoded_path" | sed 's|vscode-remote://attached-container+[^/]*/||')
                    if [ -n "$workspace_suffix" ]; then
                        decoded_path="/$workspace_suffix"
                    else
                        decoded_path=""
                    fi
                elif echo "$decoded_path" | grep -q "wsl"; then
                    connection_type="wsl"
                    # Extract WSL instance name
                    remote_host=$(printf '%s' "$decoded_path" | sed 's|vscode-remote://wsl+||' | cut -d'/' -f1)
                    # Extract path after the instance name
                    decoded_path=$(printf '%s' "$decoded_path" | sed 's|vscode-remote://wsl+[^/]*/|/|')
                    auth_method="local"
                    session_user="unknown"
                fi
            else
                # Strip file:// prefix from local paths
                decoded_path=$(printf '%s' "$decoded_path" | sed 's|^file://||')
            fi
            
            # Dedup check
            session_key="${connection_type}:${remote_host}:${decoded_path}"
            if ! session_seen "$session_key"; then
                # Add separator if not first
                if [ "$sessions_first" = "0" ]; then
                    sessions_array="${sessions_array},"
                fi
                sessions_first=0
                
                # Escape for JSON
                safe_storage=$(escape_json_string "$storage_file")
                safe_path=$(escape_json_string "$decoded_path")
                safe_host=$(escape_json_string "$remote_host")
                safe_user=$(escape_json_string "$session_user")
                safe_auth=$(escape_json_string "$auth_method")
                safe_conn=$(escape_json_string "$connection_type")
                
                # Add recent session from backupWorkspaces (conditionally include remote_host for non-local connections)
                # These are recent sessions: is_active=false
                if [ -n "$remote_host" ]; then
                    sessions_array="${sessions_array}{\"storage_file_path\":\"$safe_storage\",\"connection_type\":\"$safe_conn\",\"remote_host\":\"$safe_host\",\"user\":\"$safe_user\",\"auth_method\":\"$safe_auth\",\"window_type\":\"folder\",\"workspace_path\":\"$safe_path\",\"is_active\":false}"
                else
                    sessions_array="${sessions_array}{\"storage_file_path\":\"$safe_storage\",\"connection_type\":\"$safe_conn\",\"user\":\"$safe_user\",\"auth_method\":\"$safe_auth\",\"window_type\":\"folder\",\"workspace_path\":\"$safe_path\",\"is_active\":false}"
                fi
                
                sessions_in_chunk=$((sessions_in_chunk + 1))
                total_sessions_processed=$((total_sessions_processed + 1))
                
                # Output chunk when we reach chunk_size
                if [ "$sessions_in_chunk" -eq "$chunk_size" ]; then
                    output_session_chunk "$target_user" "$current_chunk" "$total_sessions_processed" "$chunk_size"
                    # Reset for next chunk
                    current_chunk=$((current_chunk + 1))
                    sessions_in_chunk=0
                    sessions_array=""
                    sessions_first=1
                fi
            fi
        done
        IFS=' 	
'
    fi
    
    # Old format fallback: openedPathsList.folders2[].folderUri
    if grep -q '"openedPathsList"' "$storage_file" 2>/dev/null; then
        opened_folders=$(grep -A 1000 '"folders2"[[:space:]]*:[[:space:]]*\[' "$storage_file" 2>/dev/null | \
            grep -o '"folderUri"[[:space:]]*:[[:space:]]*"[^"]*"' | \
            sed 's/.*"folderUri"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        
        IFS='
'
        for folder_path in $opened_folders; do
            [ -z "$folder_path" ] && continue
            
            # URL decode
            decoded_path=$(url_decode "$folder_path")
            
            # Parse connection info
            connection_type="local"
            remote_host=""
            auth_method="local"
            session_user="$target_user"
            
            if echo "$decoded_path" | grep -q "vscode-remote://"; then
                if echo "$decoded_path" | grep -q "ssh-remote"; then
                    connection_type="ssh-remote"
                    remote_host=$(echo "$decoded_path" | sed 's/.*ssh-remote+\([^/]*\).*/\1/')
                    # Extract workspace path from URI
                    workspace_suffix=$(echo "$decoded_path" | sed 's|.*ssh-remote+[^/]*/||')
                    if [ -n "$workspace_suffix" ]; then
                        decoded_path="/$workspace_suffix"
                        # Normalize Windows paths 
                        decoded_path=$(normalize_windows_path "$decoded_path")
                    else
                        decoded_path=""
                    fi
                    auth_method="publickey"
                    session_user="unknown"
                elif echo "$decoded_path" | grep -q "dev-container"; then
                    connection_type="dev-container"
                    auth_method="docker"
                    session_user="unknown"
                    # Extract hex data from vscode-remote://dev-container+HEX/path format
                    hex_data=$(echo "$decoded_path" | sed 's|vscode-remote://dev-container+||' | cut -d'/' -f1)
                    get_container_info_from_hex "$hex_data" "dev"
                    remote_host="$CONTAINER_NAME"
                    # Extract workspace path (everything after hex/)
                    workspace_suffix=$(echo "$decoded_path" | sed 's|vscode-remote://dev-container+[^/]*/||')
                    if [ -n "$workspace_suffix" ]; then
                        decoded_path="/$workspace_suffix"
                    else
                        decoded_path="$CONTAINER_LOCAL_PATH"
                    fi
                elif echo "$decoded_path" | grep -q "attached-container"; then
                    connection_type="attached-container"
                    auth_method="docker"
                    session_user="unknown"
                    hex_data=$(echo "$decoded_path" | sed 's|vscode-remote://attached-container+||' | cut -d'/' -f1)
                    get_container_info_from_hex "$hex_data" "attached"
                    remote_host="$CONTAINER_NAME"
                    # Extract workspace path (everything after hex/)
                    workspace_suffix=$(echo "$decoded_path" | sed 's|vscode-remote://attached-container+[^/]*/||')
                    if [ -n "$workspace_suffix" ]; then
                        decoded_path="/$workspace_suffix"
                    else
                        decoded_path=""
                    fi
                elif echo "$decoded_path" | grep -q "wsl"; then
                    connection_type="wsl"
                    remote_host=$(echo "$decoded_path" | sed 's/.*wsl+\([^/]*\).*/\1/')
                    auth_method="local"
                    session_user="unknown"
                fi
            else
                # Strip file:// prefix from local paths
                decoded_path=$(printf '%s' "$decoded_path" | sed 's|^file://||')
            fi
            
            # Dedup check
            session_key="${connection_type}:${remote_host}:${decoded_path}"
            if ! session_seen "$session_key"; then
                # Add separator if not first
                if [ "$sessions_first" = "0" ]; then
                    sessions_array="${sessions_array},"
                fi
                sessions_first=0
                
                # Escape for JSON
                safe_storage=$(escape_json_string "$storage_file")
                safe_path=$(escape_json_string "$decoded_path")
                safe_host=$(escape_json_string "$remote_host")
                safe_user=$(escape_json_string "$session_user")
                safe_auth=$(escape_json_string "$auth_method")
                safe_conn=$(escape_json_string "$connection_type")
                
                # Add historical session (conditionally include remote_host for non-local connections)
                if [ -n "$remote_host" ]; then
                    sessions_array="${sessions_array}{\"storage_file_path\":\"$safe_storage\",\"connection_type\":\"$safe_conn\",\"remote_host\":\"$safe_host\",\"user\":\"$safe_user\",\"auth_method\":\"$safe_auth\",\"window_type\":\"folder\",\"workspace_path\":\"$safe_path\",\"is_active\":false}"
                else
                    sessions_array="${sessions_array}{\"storage_file_path\":\"$safe_storage\",\"connection_type\":\"$safe_conn\",\"user\":\"$safe_user\",\"auth_method\":\"$safe_auth\",\"window_type\":\"folder\",\"workspace_path\":\"$safe_path\",\"is_active\":false}"
                fi
                
                sessions_in_chunk=$((sessions_in_chunk + 1))
                total_sessions_processed=$((total_sessions_processed + 1))
                
                # Output chunk when we reach chunk_size
                if [ "$sessions_in_chunk" -eq "$chunk_size" ]; then
                    output_session_chunk "$target_user" "$current_chunk" "$total_sessions_processed" "$chunk_size"
                    # Reset for next chunk
                    current_chunk=$((current_chunk + 1))
                    sessions_in_chunk=0
                    sessions_array=""
                    sessions_first=1
                fi
            fi
        done
        IFS=' 	
'
    fi
    
    # Extract all unique SSH hosts from profileAssociations keys
    # Searches for vscode-remote://ssh-remote URIs in storage.json
    if grep -q "vscode-remote://ssh-remote" "$storage_file" 2>/dev/null; then
        ssh_hosts=$(grep -o "vscode-remote://ssh-remote[^\"]*" "$storage_file" 2>/dev/null | \
            sed 's/vscode-remote:\/\/ssh-remote%2B//g; s/vscode-remote:\/\/ssh-remote+//g' | \
            sed 's/\/.*//g' | \
            sed 's/:.*//g' | \
            sort -u)
        
        IFS='
'
        for remote_host in $ssh_hosts; do
            [ -z "$remote_host" ] && continue
            
            # Check if we've already seen this host with ANY workspace path
            # Pattern: |ssh-remote:hostname: appears in seen_sessions list
            host_pattern="|ssh-remote:${remote_host}:"
            if echo "$seen_sessions" | grep -q -F "$host_pattern"; then
                # This host already appears in active/recent sessions with workspace data, skip
                continue
            fi
            
            # This is a connection from profileAssociations - historical SSH host without workspace
            
            # Lookup SSH configuration using the proper function
            lookup_ssh_info "$remote_host" "$target_user"
            
            # Mark this host as seen (add to seen_sessions with empty workspace for profileAssociations)
            seen_sessions="${seen_sessions}|ssh-remote:${remote_host}:|"
            
            # Add separator if not first
            if [ "$sessions_first" = "0" ]; then
                    sessions_array="${sessions_array},"
                fi
                sessions_first=0
                
                # Escape for JSON
                safe_storage=$(escape_json_string "$storage_file")
                safe_host=$(escape_json_string "$remote_host")
                safe_user=$(escape_json_string "$SSH_USER_RESULT")
                safe_auth=$(escape_json_string "$SSH_AUTH_RESULT")
            
            # Add profileAssociations session (empty workspace_path, window_type=empty)
            sessions_array="${sessions_array}{\"storage_file_path\":\"$safe_storage\",\"connection_type\":\"ssh-remote\",\"remote_host\":\"$safe_host\",\"user\":\"$safe_user\",\"auth_method\":\"$safe_auth\",\"window_type\":\"empty\",\"workspace_path\":\"\",\"is_active\":false}"
            
            sessions_in_chunk=$((sessions_in_chunk + 1))
            total_sessions_processed=$((total_sessions_processed + 1))
            
            # Output chunk when we reach chunk_size
            if [ "$sessions_in_chunk" -eq "$chunk_size" ]; then
                output_session_chunk "$target_user" "$current_chunk" "$total_sessions_processed" "$chunk_size"
                # Reset for next chunk
                current_chunk=$((current_chunk + 1))
                sessions_in_chunk=0
                sessions_array=""
                sessions_first=1
            fi
        done
        IFS=' 	
'
    fi
    
    # Output remaining sessions if any
    if [ "$sessions_in_chunk" -gt 0 ]; then
        output_session_chunk "$target_user" "$current_chunk" "$total_sessions_processed" "$chunk_size"
    fi
}

# Main
main() {
    # Parse command line arguments
    parse_args "$@"
    
    # Get list of users to process
    users_list=$(get_users_to_process)
    
    # Define all supported variants
    VARIANT_LIST="stable insiders vscodium cursor code-oss windsurf"
    
    # Process each user
    for target_user in $users_list; do
        user_home=$(get_user_home "$target_user")
        [ -z "$user_home" ] && continue
        
        # Process each VS Code variant
        for variant in $VARIANT_LIST; do
            # Detect paths for this variant
            detect_variant_paths "$target_user" "$variant"
            [ $? -ne 0 ] && continue
            
            # Always collect installation info for all variants (doesn't require user dir)
            process_installation "$target_user"
            
            # Skip remaining collections if user directory doesn't exist
            [ ! -d "$VSCODE_USER_DIR" ] && continue
            
            # Skip if full data collection disabled for this variant
            if [ "$COLLECT_FULL_DATA" = "0" ]; then
                continue
            fi
            
            # Full data collection (currently only VS Code Stable)
            process_settings "$target_user"
            process_argv "$target_user"
            process_workspace_files "$target_user" "$user_home"
            process_extensions "$target_user"
            process_active_session "$target_user"
        done
    done
}

# Run
main "$@"
