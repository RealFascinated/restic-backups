#!/bin/bash

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Constants
readonly REQUIRED_COMMANDS=("restic" "jq" "curl")
readonly RETENTION_DAYS=14
declare -A DISCORD_COLORS=(
    ["success"]="3066993"  # Green
    ["warning"]="16098851" # Yellow
    ["error"]="15158332"   # Red
)
readonly DISCORD_COLORS

# Configuration variables
declare -A CONFIG=(
    ["RESTIC_PASSWORD"]=""
    ["AWS_ACCESS_KEY_ID"]=""
    ["AWS_SECRET_ACCESS_KEY"]=""
    ["RESTIC_REPOSITORY"]=""
    ["AWS_DEFAULT_REGION"]=""
    ["S3_FORCE_PATH_STYLE"]=""
    ["DISCORD_WEBHOOK"]=""
    ["BACKUP_NAME"]=""
    ["BACKUP_PATH"]=""
    ["ENABLE_PRUNE"]="true"
    ["KEEP_LAST"]="14"
)

# Helper functions
log() {
    local msg="$1"
    local timestamp
    if ! timestamp=$(date '+%Y-%m-%d %H:%M:%S'); then
        timestamp="[ERROR: date command failed]"
    fi
    echo "[$timestamp] $msg" >> "$BACKUP_LOG"
    echo "[$timestamp] $msg"
}

check_requirements() {
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "Error: $cmd is not installed"
            exit 1
        fi
    done
}

validate_config() {
    local missing_vars=()
    for key in "${!CONFIG[@]}"; do
        if [ -z "${CONFIG[$key]}" ]; then
            missing_vars+=("$key")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo "Error: Missing required configuration: ${missing_vars[*]}"
        exit 1
    fi

    if [ ! -d "${CONFIG[BACKUP_PATH]}" ]; then
        echo "Error: Backup path does not exist: ${CONFIG[BACKUP_PATH]}"
        exit 1
    fi
}

parse_arguments() {
    log "Parsing arguments: $*"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restic-password) CONFIG["RESTIC_PASSWORD"]="$2"; shift 2 ;;
            --aws-access-key) CONFIG["AWS_ACCESS_KEY_ID"]="$2"; shift 2 ;;
            --aws-secret-key) CONFIG["AWS_SECRET_ACCESS_KEY"]="$2"; shift 2 ;;
            --repository) CONFIG["RESTIC_REPOSITORY"]="$2"; shift 2 ;;
            --region) CONFIG["AWS_DEFAULT_REGION"]="$2"; shift 2 ;;
            --path-style) CONFIG["S3_FORCE_PATH_STYLE"]="$2"; shift 2 ;;
            --discord-webhook) CONFIG["DISCORD_WEBHOOK"]="$2"; shift 2 ;;
            --backup-name) CONFIG["BACKUP_NAME"]="$2"; shift 2 ;;
            --backup-path) CONFIG["BACKUP_PATH"]="$2"; shift 2 ;;
            --enable-prune) CONFIG["ENABLE_PRUNE"]="$2"; shift 2 ;;
            --keep-last) CONFIG["KEEP_LAST"]="$2"; shift 2 ;;
            *) log "Unknown option: $1"; exit 1 ;;
        esac
    done
    
    # Debug output of parsed configuration
    log "Parsed configuration:"
    for key in "${!CONFIG[@]}"; do
        log "  $key: ${CONFIG[$key]}"
    done
}

export_config() {
    for key in "${!CONFIG[@]}"; do
        if [[ "$key" != "BACKUP_NAME" && "$key" != "BACKUP_PATH" && "$key" != "DISCORD_WEBHOOK" ]]; then
            export "$key=${CONFIG[$key]}"
        fi
    done
}

format_size() {
    local bytes=$1
    local mb
    local gb_whole
    local gb_decimal
    
    # Ensure bytes is a number
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0 MB (0.00 GB)"
        return 1
    fi
    
    # Calculate sizes
    mb=$((bytes / 1024 / 1024))
    gb_whole=$((bytes / 1024 / 1024 / 1024))
    gb_decimal=$(( (bytes * 100 / 1024 / 1024 / 1024) - (gb_whole * 100) ))
    
    # If size is less than 1 MB, show in KB
    if [ "$mb" -eq 0 ]; then
        local kb=$((bytes / 1024))
        printf "%'d KB (%.2f MB)" "$kb" "$(echo "scale=2; $bytes/1024/1024" | bc)"
    else
        printf "%'d MB (%.2f GB)" "$mb" "$(echo "scale=2; $gb_decimal/100 + $gb_whole" | bc)"
    fi
}

get_backup_stats() {
    local snapshot_id=$1
    local stats_json
    local total_size=0
    local total_files=0
    
    # Get size from snapshots command
    if snapshot_json=$(restic -r "${CONFIG[RESTIC_REPOSITORY]}" snapshots --json "$snapshot_id" 2>/dev/null); then
        total_size=$(echo "$snapshot_json" | jq -r '.[0].size // 0')
    fi
    
    # Get file count from stats command
    if stats_json=$(restic -r "${CONFIG[RESTIC_REPOSITORY]}" stats --json "$snapshot_id" 2>/dev/null); then
        total_files=$(echo "$stats_json" | jq -r '.total_file_count // 0')
        
        # If size is 0, try to get it from stats
        if [ "$total_size" -eq 0 ]; then
            total_size=$(echo "$stats_json" | jq -r '.total_size // 0')
        fi
    fi
    
    # Output only the numbers
    printf "%d:%d\n" "$total_size" "$total_files"
    return 0
}

get_changes_stats() {
    local prev_snapshot=$1
    local current_snapshot=$2
    local changes_json
    
    if ! changes_json=$(restic -r "${CONFIG[RESTIC_REPOSITORY]}" diff --json "$prev_snapshot" "$current_snapshot" 2>/dev/null); then
        log "Error getting changes statistics" >&2
        return 1
    fi
    
    # Output the changes in a tab-separated format
    echo "$changes_json" | jq -r '[.new_files, .removed_files, .changed_files] | @tsv'
    return 0
}

create_discord_payload() {
    local status=$1
    local color=$2
    local snapshot_id=$3
    local size_info=$4
    local total_files=$5
    local new_files=$6
    local removed_files=$7
    local changed_files=$8
    local prune_status=$9
    local timestamp=${10}
    
    cat << EOF
{
  "embeds": [
    {
      "title": "${CONFIG[BACKUP_NAME]} Backup $status",
      "description": "Backup completed at $timestamp",
      "color": $color,
      "fields": [
        {
          "name": "Snapshot ID",
          "value": "$snapshot_id",
          "inline": true
        },
        {
          "name": "Total Size",
          "value": "$size_info",
          "inline": true
        },
        {
          "name": "Total Files",
          "value": "$total_files",
          "inline": true
        },
        {
          "name": "New Files",
          "value": "$new_files",
          "inline": true
        },
        {
          "name": "Changed Files",
          "value": "$changed_files",
          "inline": true
        },
        {
          "name": "Removed Files",
          "value": "$removed_files",
          "inline": true
        }
      ],
      "footer": {
        "text": "Retention policy: keeping last $RETENTION_DAYS backups | $prune_status"
      }
    }
  ]
}
EOF
}

# Main execution
main() {
    # Initialize logging
    BACKUP_LOG=$(mktemp)
    log "Starting backup process"
    log "Backup path: ${CONFIG[BACKUP_PATH]}"
    log "Repository: ${CONFIG[RESTIC_REPOSITORY]}"
    
    # Setup and validation
    log "Checking requirements..."
    check_requirements
    log "Parsing arguments..."
    parse_arguments "$@"
    log "Validating configuration..."
    validate_config
    log "Exporting configuration..."
    export_config
    
    # Run backup
    log "Running backup..."
    log "Command: restic -r ${CONFIG[RESTIC_REPOSITORY]} backup ${CONFIG[BACKUP_PATH]}"
    if ! restic -r "${CONFIG[RESTIC_REPOSITORY]}" backup "${CONFIG[BACKUP_PATH]}" >> "$BACKUP_LOG" 2>&1; then
        log "Backup failed with exit code $?"
        backup_exit_code=1
    else
        backup_exit_code=0
        log "Backup completed successfully"
        # Add a small delay to ensure the snapshot is registered
        sleep 2
    fi
    
    # Get snapshot information
    log "Getting snapshot information..."
    local snapshot_id
    if ! snapshot_id=$(restic -r "${CONFIG[RESTIC_REPOSITORY]}" snapshots --json 2>/dev/null | jq -r 'sort_by(.time) | reverse | .[0].id // "unknown"'); then
        log "Error getting snapshot ID"
        snapshot_id="unknown"
    fi
    # Trim the snapshot ID to first 8 characters
    snapshot_id="${snapshot_id:0:8}"
    log "Snapshot ID: $snapshot_id"
    
    # Initialize variables
    local status="❌ Failed"
    local color="${DISCORD_COLORS[error]}"
    local size_info="unknown"
    local total_files="unknown"
    local new_files="0"
    local removed_files="0"
    local changed_files="0"
    local prune_status="Not attempted"
    
    if [ $backup_exit_code -eq 0 ]; then
        status="✅ Successful"
        color="${DISCORD_COLORS[success]}"
        
        # Get backup statistics
        log "Getting backup statistics..."
        local stats_output
        if stats_output=$(get_backup_stats "$snapshot_id" 2>> "$BACKUP_LOG"); then
            log "Raw stats output: $stats_output"
            if IFS=':' read -r total_size total_files <<< "$stats_output"; then
                if [[ "$total_size" =~ ^[0-9]+$ ]] && [[ "$total_files" =~ ^[0-9]+$ ]]; then
                    log "Parsed stats - Size: $total_size, Files: $total_files"
                    size_info=$(format_size "$total_size")
                    total_files=$(printf "%'d" "$total_files")
                else
                    log "Invalid statistics format: size=$total_size, files=$total_files"
                    size_info="unknown"
                    total_files="unknown"
                fi
            else
                log "Failed to parse statistics output"
                size_info="unknown"
                total_files="unknown"
            fi
        else
            log "Failed to get backup statistics"
            size_info="unknown"
            total_files="unknown"
        fi
        
        # Get changes statistics
        log "Getting changes statistics..."
        local prev_snapshot
        if prev_snapshot=$(restic -r "${CONFIG[RESTIC_REPOSITORY]}" snapshots --json 2>/dev/null | jq -r 'sort_by(.time) | reverse | .[1].id // ""'); then
            if [ -n "$prev_snapshot" ]; then
                log "Previous snapshot found: $prev_snapshot"
                log "Comparing snapshots: $prev_snapshot -> $snapshot_id"
                
                # Get detailed diff information
                local diff_json
                if diff_json=$(restic -r "${CONFIG[RESTIC_REPOSITORY]}" diff --json "$prev_snapshot" "$snapshot_id" 2>/dev/null); then
                    log "Raw diff output: $diff_json"
                    
                    # Extract change counts from the statistics message
                    new_files=$(echo "$diff_json" | grep '"message_type":"statistics"' | jq -r '.added.files // 0')
                    removed_files=$(echo "$diff_json" | grep '"message_type":"statistics"' | jq -r '.removed.files // 0')
                    changed_files=$(echo "$diff_json" | grep '"message_type":"statistics"' | jq -r '.changed_files // 0')
                    
                    log "Parsed changes - New: $new_files, Changed: $changed_files, Removed: $removed_files"
                    
                    # Format the numbers
                    new_files=$(printf "%'d" "$new_files")
                    removed_files=$(printf "%'d" "$removed_files")
                    changed_files=$(printf "%'d" "$changed_files")
                else
                    log "Failed to get changes statistics"
                    new_files="0"
                    removed_files="0"
                    changed_files="0"
                fi
            else
                log "No previous snapshot found"
                new_files="0"
                removed_files="0"
                changed_files="0"
            fi
        else
            log "Error getting previous snapshot"
            new_files="0"
            removed_files="0"
            changed_files="0"
        fi
        
        # Apply retention policy if enabled
        if [ "${CONFIG[ENABLE_PRUNE]}" = "true" ]; then
            log "Applying retention policy (keeping last ${CONFIG[KEEP_LAST]} backups globally)..."
            
            # Run the prune
            local prune_output
            if ! prune_output=$(restic -r "${CONFIG[RESTIC_REPOSITORY]}" forget --keep-last "${CONFIG[KEEP_LAST]}" --group-by "" --prune 2>&1); then
                log "Prune operation failed"
                status="⚠️ Backup OK, Prune Failed"
                color="${DISCORD_COLORS[warning]}"
                prune_status="Prune operation failed"
            else
                log "Prune output: $prune_output"
                if echo "$prune_output" | grep -q "no snapshots were removed"; then
                    log "No snapshots to prune"
                    prune_status="No snapshots to prune"
                else
                    log "Successfully pruned old backups"
                    prune_status="Successfully pruned old backups"
                fi
            fi
        else
            log "Pruning disabled"
            prune_status="Pruning disabled"
        fi
    fi
    
    # Send Discord notification
    log "Sending Discord notification..."
    local payload_file
    payload_file=$(mktemp)
    create_discord_payload "$status" "$color" "$snapshot_id" "$size_info" "$total_files" \
        "$new_files" "$removed_files" "$changed_files" "$prune_status" "$(date '+%Y-%m-%d %H:%M:%S')" > "$payload_file"
    
    if ! curl -s -H "Content-Type: application/json" -d @"$payload_file" "${CONFIG[DISCORD_WEBHOOK]}" > /dev/null 2>&1; then
        log "Failed to send Discord notification"
    else
        log "Discord notification sent successfully"
    fi
    
    # Cleanup
    log "Cleaning up temporary files..."
    rm -f "$BACKUP_LOG" "$payload_file"
    
    log "Backup process completed with exit code $backup_exit_code"
    exit $backup_exit_code
}

# Execute main function with all arguments
main "$@"