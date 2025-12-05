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
CURRENT_VERSION=$(sqlite3 "$DB_PATH" "SELECT version FROM settings WHERE key='system_version' LIMIT 1;" 2>/dev/null)

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

# Function to check all service versions and build update list
check_all_updates() {
    UPDATES_AVAILABLE=()
    
    # Check UI version
    if version_greater "$REPO_VERSION" "$CURRENT_VERSION"; then
        UPDATES_AVAILABLE+=("UI: $CURRENT_VERSION → $REPO_VERSION")
    fi
    
    # Check Router version
    local ROUTER_CURRENT=$(sqlite3 "$DB_PATH" "SELECT version FROM settings WHERE key='router_version' LIMIT 1;" 2>/dev/null)
    local ROUTER_REPO=$(curl -s -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/lyncsolutionsph/router0/main/version.txt?$(date +%s)" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$ROUTER_CURRENT" ] && [ -n "$ROUTER_REPO" ]; then
        if version_greater "$ROUTER_REPO" "$ROUTER_CURRENT"; then
            UPDATES_AVAILABLE+=("Router: $ROUTER_CURRENT → $ROUTER_REPO")
        fi
    fi
    
    # Check Firewall version
    local FIREWALL_CURRENT=$(sqlite3 "$DB_PATH" "SELECT version FROM settings WHERE key='firewall_version' LIMIT 1;" 2>/dev/null)
    local FIREWALL_REPO=$(curl -s -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/lyncsolutionsph/firewall/main/version.txt?$(date +%s)" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$FIREWALL_CURRENT" ] && [ -n "$FIREWALL_REPO" ]; then
        if version_greater "$FIREWALL_REPO" "$FIREWALL_CURRENT"; then
            UPDATES_AVAILABLE+=("Firewall: $FIREWALL_CURRENT → $FIREWALL_REPO")
        fi
    fi
    
    # Check Startup version
    local STARTUP_CURRENT=$(sqlite3 "$DB_PATH" "SELECT version FROM settings WHERE key='startup_version' LIMIT 1;" 2>/dev/null)
    local STARTUP_REPO=$(curl -s -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/lyncsolutionsph/startup/main/version.txt?$(date +%s)" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$STARTUP_CURRENT" ] && [ -n "$STARTUP_REPO" ]; then
        if version_greater "$STARTUP_REPO" "$STARTUP_CURRENT"; then
            UPDATES_AVAILABLE+=("Startup: $STARTUP_CURRENT → $STARTUP_REPO")
        fi
    fi
}

# Check all updates
check_all_updates

# If any updates are available, show them and prompt
if [ ${#UPDATES_AVAILABLE[@]} -gt 0 ]; then
    log_message "Updates available: ${UPDATES_AVAILABLE[*]}"
    
    # Prompt for confirmation if running interactively
    if [ -t 0 ]; then
        echo ""
        echo "=========================================="
        echo "  SEER System Update Available"
        echo "=========================================="
        echo "The following services will be updated:"
        echo ""
        for update in "${UPDATES_AVAILABLE[@]}"; do
            echo "  • $update"
        done
        echo ""
        read -p "Do you want to install these updates? (y/n): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_message "Update cancelled by user"
            exit 0
        fi
    fi
fi

# Check if UI update is needed
if version_greater "$REPO_VERSION" "$CURRENT_VERSION"; then
    log_message "New version available: $REPO_VERSION (current: $CURRENT_VERSION)"
    
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
    
    # Update database path after restoration
    DB_PATH="$TARGET_DIR/.node-red/seer_database/seer.db"
    
    # Update database with new version
    log_message "Updating database version to $REPO_VERSION..."
    
    # Log current database state for debugging
    CURRENT_DB_STATE=$(sqlite3 "$DB_PATH" "SELECT key, value, version FROM settings;" 2>&1)
    log_message "Current database state: $CURRENT_DB_STATE"
    
    # Update both value and version columns where key='system_version'
    ROWS_AFFECTED=$(sqlite3 "$DB_PATH" "UPDATE settings SET value = 'SEER Version $REPO_VERSION', version = $REPO_VERSION WHERE key='system_version'; SELECT changes();" 2>&1 | tail -n 1)
    log_message "Rows affected by version update: $ROWS_AFFECTED"
    
    # If no rows were affected, something is wrong
    if [ "$ROWS_AFFECTED" = "0" ] || [ -z "$ROWS_AFFECTED" ]; then
        log_message "ERROR: Failed to update database version (no rows affected). Check if key='system_version' exists."
        sudo systemctl start nodered
        exit 1
    fi
    
    # Verify the update
    NEW_VERSION=$(sqlite3 "$DB_PATH" "SELECT version FROM settings WHERE key='system_version' LIMIT 1;" 2>/dev/null)
    if [ -z "$NEW_VERSION" ]; then
        NEW_VERSION=$(sqlite3 "$DB_PATH" "SELECT version FROM settings LIMIT 1;" 2>/dev/null)
    fi
    
    # Verify the version matches what we tried to set
    if [ "$NEW_VERSION" != "$REPO_VERSION" ]; then
        log_message "ERROR: Database version mismatch. Expected: $REPO_VERSION, Got: $NEW_VERSION"
        sudo systemctl start nodered
        exit 1
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

# ============================================
# Check and update Router Service
# ============================================
log_message "Checking Router Service version..."

ROUTER_CURRENT_VERSION=$(sqlite3 "$DB_PATH" "SELECT version FROM settings WHERE key='router_version' LIMIT 1;" 2>/dev/null)

if [ -n "$ROUTER_CURRENT_VERSION" ]; then
    log_message "Current Router version: $ROUTER_CURRENT_VERSION"
    
    # Fetch Router version from GitHub
    ROUTER_REPO_VERSION=$(curl -s -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/lyncsolutionsph/router0/main/version.txt?$(date +%s)" | tr -d '[:space:]')
    
    if [ -n "$ROUTER_REPO_VERSION" ]; then
        log_message "Repository Router version: $ROUTER_REPO_VERSION"
        
        if version_greater "$ROUTER_REPO_VERSION" "$ROUTER_CURRENT_VERSION"; then
            log_message "Updating Router Service to version $ROUTER_REPO_VERSION..."
            
            cd "$TEMP_DIR" || mkdir -p "$TEMP_DIR" && cd "$TEMP_DIR"
            git clone --depth 1 https://github.com/lyncsolutionsph/router0 router 2>&1 >> "$LOG_FILE"
            
            if [ $? -eq 0 ] && [ -d "$TEMP_DIR/router" ]; then
                cd "$TEMP_DIR/router"
                sudo bash install.sh 2>&1 >> "$LOG_FILE"
                
                if [ $? -eq 0 ]; then
                    # Update database with new router version
                    sqlite3 "$DB_PATH" "UPDATE settings SET value = 'Router Version $ROUTER_REPO_VERSION', version = $ROUTER_REPO_VERSION WHERE key='router_version';" 2>&1 >> "$LOG_FILE"
                    log_message "Router Service updated successfully to version $ROUTER_REPO_VERSION"
                else
                    log_message "WARNING: Router Service installation failed"
                fi
            else
                log_message "WARNING: Failed to clone Router repository"
            fi
        else
            log_message "Router Service is up to date (version: $ROUTER_CURRENT_VERSION)"
        fi
    else
        log_message "WARNING: Could not fetch Router version from repository"
    fi
else
    log_message "Router version not found in database, skipping Router update check"
fi

# ============================================
# Check and update Firewall Service
# ============================================
log_message "Checking Firewall Service version..."

FIREWALL_CURRENT_VERSION=$(sqlite3 "$DB_PATH" "SELECT version FROM settings WHERE key='firewall_version' LIMIT 1;" 2>/dev/null)

if [ -n "$FIREWALL_CURRENT_VERSION" ]; then
    log_message "Current Firewall version: $FIREWALL_CURRENT_VERSION"
    
    # Fetch Firewall version from GitHub
    FIREWALL_REPO_VERSION=$(curl -s -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/lyncsolutionsph/firewall/main/version.txt?$(date +%s)" | tr -d '[:space:]')
    
    if [ -n "$FIREWALL_REPO_VERSION" ]; then
        log_message "Repository Firewall version: $FIREWALL_REPO_VERSION"
        
        if version_greater "$FIREWALL_REPO_VERSION" "$FIREWALL_CURRENT_VERSION"; then
            log_message "Updating Firewall Service to version $FIREWALL_REPO_VERSION..."
            
            cd "$TEMP_DIR" || mkdir -p "$TEMP_DIR" && cd "$TEMP_DIR"
            git clone --depth 1 https://github.com/lyncsolutionsph/firewall firewall 2>&1 >> "$LOG_FILE"
            
            if [ $? -eq 0 ] && [ -d "$TEMP_DIR/firewall" ]; then
                cd "$TEMP_DIR/firewall"
                sudo bash install.sh 2>&1 >> "$LOG_FILE"
                
                if [ $? -eq 0 ]; then
                    # Update database with new firewall version
                    sqlite3 "$DB_PATH" "UPDATE settings SET value = 'Firewall Version $FIREWALL_REPO_VERSION', version = $FIREWALL_REPO_VERSION WHERE key='firewall_version';" 2>&1 >> "$LOG_FILE"
                    log_message "Firewall Service updated successfully to version $FIREWALL_REPO_VERSION"
                else
                    log_message "WARNING: Firewall Service installation failed"
                fi
            else
                log_message "WARNING: Failed to clone Firewall repository"
            fi
        else
            log_message "Firewall Service is up to date (version: $FIREWALL_CURRENT_VERSION)"
        fi
    else
        log_message "WARNING: Could not fetch Firewall version from repository"
    fi
else
    log_message "Firewall version not found in database, skipping Firewall update check"
fi

# ============================================
# Check and update Startup Service
# ============================================
log_message "Checking Startup Service version..."

STARTUP_CURRENT_VERSION=$(sqlite3 "$DB_PATH" "SELECT version FROM settings WHERE key='startup_version' LIMIT 1;" 2>/dev/null)

if [ -n "$STARTUP_CURRENT_VERSION" ]; then
    log_message "Current Startup version: $STARTUP_CURRENT_VERSION"
    
    # Fetch Startup version from GitHub
    STARTUP_REPO_VERSION=$(curl -s -H "Cache-Control: no-cache" "https://raw.githubusercontent.com/lyncsolutionsph/startup/main/version.txt?$(date +%s)" | tr -d '[:space:]')
    
    if [ -n "$STARTUP_REPO_VERSION" ]; then
        log_message "Repository Startup version: $STARTUP_REPO_VERSION"
        
        if version_greater "$STARTUP_REPO_VERSION" "$STARTUP_CURRENT_VERSION"; then
            log_message "Updating Startup Service to version $STARTUP_REPO_VERSION..."
            
            cd "$TEMP_DIR" || mkdir -p "$TEMP_DIR" && cd "$TEMP_DIR"
            git clone --depth 1 https://github.com/lyncsolutionsph/startup startup 2>&1 >> "$LOG_FILE"
            
            if [ $? -eq 0 ] && [ -d "$TEMP_DIR/startup" ]; then
                cd "$TEMP_DIR/startup"
                sudo bash install.sh 2>&1 >> "$LOG_FILE"
                
                if [ $? -eq 0 ]; then
                    # Update database with new startup version
                    sqlite3 "$DB_PATH" "UPDATE settings SET value = 'Startup Version $STARTUP_REPO_VERSION', version = $STARTUP_REPO_VERSION WHERE key='startup_version';" 2>&1 >> "$LOG_FILE"
                    log_message "Startup Service updated successfully to version $STARTUP_REPO_VERSION"
                else
                    log_message "WARNING: Startup Service installation failed"
                fi
            else
                log_message "WARNING: Failed to clone Startup repository"
            fi
        else
            log_message "Startup Service is up to date (version: $STARTUP_CURRENT_VERSION)"
        fi
    else
        log_message "WARNING: Could not fetch Startup version from repository"
    fi
else
    log_message "Startup version not found in database, skipping Startup update check"
fi

log_message "Version check completed."
