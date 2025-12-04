#!/bin/bash

# updater.sh - System version checker and updater for SEER
# Location: /usr/local/sbin/updater.sh
# This script checks the repository for version updates and updates the system if needed

REPO_URL="https://github.com/lyncsolutionsph/seer_v1.0"
RAW_URL="https://raw.githubusercontent.com/lyncsolutionsph/seer_v1.0/main"
TARGET_DIR="/home/admin"
DB_PATH="$TARGET_DIR/.node-red/seer_database/seer.db"
LOG_FILE="/var/log/seer_updater.log"
LOCK_FILE="/tmp/seer_updater.lock"
TEMP_DIR="/tmp/seer_update_$$"

# Function to log messages
log_message() {
    local message="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "$message" >> "$LOG_FILE"
    # Also print to terminal if running interactively
    if [ -t 1 ]; then
        echo "$message"
    fi
}

# Function to cleanup temp directory
cleanup() {
    rm -f "$LOCK_FILE"
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Check if script is already running
if [ -f "$LOCK_FILE" ]; then
    log_message "Updater already running, exiting..."
    exit 0
fi

# Create lock file
touch "$LOCK_FILE"

# Trap to ensure lock file and temp dir are removed on exit
trap cleanup EXIT

log_message "Starting version check..."

# Get current version from database
CURRENT_VERSION=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='version' LIMIT 1;" 2>/dev/null)

# If the above query fails, try alternative column name
if [ -z "$CURRENT_VERSION" ]; then
    CURRENT_VERSION=$(sqlite3 "$DB_PATH" "SELECT version FROM settings LIMIT 1;" 2>/dev/null)
fi

if [ -z "$CURRENT_VERSION" ]; then
    log_message "ERROR: Could not read current version from database at $DB_PATH"
    exit 1
fi

log_message "Current version: $CURRENT_VERSION"

# Fetch version.txt from GitHub (with cache busting)
log_message "Fetching version from repository..."
REPO_VERSION=$(curl -s -H "Cache-Control: no-cache" "$RAW_URL/version.txt?$(date +%s)" | tr -d '[:space:]')

if [ -z "$REPO_VERSION" ]; then
    log_message "ERROR: Could not read version from repository"
    exit 1
fi

log_message "Repository version: $REPO_VERSION"

# Compare versions (using version comparison)
version_greater() {
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

# Check if repository version is higher than current version
if version_greater "$REPO_VERSION" "$CURRENT_VERSION"; then
    log_message "New version available: $REPO_VERSION (current: $CURRENT_VERSION)"
    
    # Prompt for confirmation if running interactively
    if [ -t 0 ]; then
        echo ""
        echo "=========================================="
        echo "  SEER System Update Available"
        echo "=========================================="
        echo "Current version: $CURRENT_VERSION"
        echo "New version:     $REPO_VERSION"
        echo ""
        read -p "Do you want to install this update? (y/n): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_message "Update cancelled by user"
            exit 0
        fi
    fi
    
    log_message "Starting update process..."
    
    # Stop Node-RED service
    log_message "Stopping Node-RED service..."
    sudo systemctl stop nodered
    
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to stop Node-RED service"
        exit 1
    fi
    
    sleep 2
    
    # Backup current .node-red directory
    log_message "Backing up current .node-red directory..."
    BACKUP_DIR="$TARGET_DIR/.node-red.backup.$(date +%Y%m%d_%H%M%S)"
    cp -r "$TARGET_DIR/.node-red" "$BACKUP_DIR" 2>&1 >> "$LOG_FILE"
    
    if [ $? -eq 0 ]; then
        log_message "Backup created at $BACKUP_DIR"
    else
        log_message "WARNING: Backup failed, continuing anyway..."
    fi
    
    # Create temp directory for clone
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR" || {
        log_message "ERROR: Could not create temp directory"
        sudo systemctl start nodered
        exit 1
    }
    
    # Clone the repository
    log_message "Cloning repository from GitHub..."
    git clone --depth 1 --branch main "$REPO_URL" repo 2>&1 >> "$LOG_FILE"
    
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to clone repository"
        sudo systemctl start nodered
        exit 1
    fi
    
    # Check if .node-red exists in the cloned repo
    if [ ! -d "$TEMP_DIR/repo/.node-red" ]; then
        log_message "ERROR: .node-red directory not found in repository"
        sudo systemctl start nodered
        exit 1
    fi
    
    # Preserve the database directory if it exists
    if [ -d "$TARGET_DIR/.node-red/seer_database" ]; then
        log_message "Preserving database directory..."
        cp -r "$TARGET_DIR/.node-red/seer_database" /tmp/seer_database.tmp 2>/dev/null
    fi
    
    # Remove old .node-red
    if [ -d "$TARGET_DIR/.node-red" ]; then
        rm -rf "$TARGET_DIR/.node-red"
        log_message "Removed old .node-red directory"
    fi
    
    # Move new .node-red from cloned repo to target
    mv "$TEMP_DIR/repo/.node-red" "$TARGET_DIR/" 2>&1 >> "$LOG_FILE"
    
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to move .node-red directory"
        sudo systemctl start nodered
        exit 1
    fi
    
    log_message ".node-red moved successfully"
    
    # Restore the database directory
    if [ -d /tmp/seer_database.tmp ]; then
        rm -rf "$TARGET_DIR/.node-red/seer_database"
        mv /tmp/seer_database.tmp "$TARGET_DIR/.node-red/seer_database"
        log_message "Database directory restored"
    fi
    
    # Set proper permissions
    chown -R admin:admin "$TARGET_DIR/.node-red"
    log_message "Permissions set for .node-red"
    
    # Update database with new version
    log_message "Updating database version to $REPO_VERSION..."
    
    # Try updating with key-value structure first
    sqlite3 "$DB_PATH" "UPDATE settings SET value = '$REPO_VERSION' WHERE key='version';" 2>&1 >> "$LOG_FILE"
    
    # If that fails, try simple column structure
    if [ $? -ne 0 ]; then
        sqlite3 "$DB_PATH" "UPDATE settings SET version = '$REPO_VERSION';" 2>&1 >> "$LOG_FILE"
        if [ $? -ne 0 ]; then
            log_message "ERROR: Failed to update database version"
            sudo systemctl start nodered
            exit 1
        fi
    fi
    
    # Verify the update
    NEW_VERSION=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='version' LIMIT 1;" 2>/dev/null)
    if [ -z "$NEW_VERSION" ]; then
        NEW_VERSION=$(sqlite3 "$DB_PATH" "SELECT version FROM settings LIMIT 1;" 2>/dev/null)
    fi
    log_message "Database version updated to: $NEW_VERSION"
    
    # Start Node-RED service
    log_message "Starting Node-RED service..."
    sudo systemctl start nodered
    
    if [ $? -eq 0 ]; then
        log_message "Node-RED service started successfully"
    else
        log_message "ERROR: Failed to start Node-RED service"
        exit 1
    fi
    
    log_message "Update completed successfully to version $REPO_VERSION"
else
    log_message "System is up to date (version: $CURRENT_VERSION)"
    
    # Check if Node-RED is running, if not start it
    if ! systemctl is-active --quiet nodered; then
        log_message "Node-RED is not running, starting service..."
        sudo systemctl start nodered
    fi
fi

log_message "Version check completed."
