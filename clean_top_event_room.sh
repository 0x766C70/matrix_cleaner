#!/usr/bin/env bash

################################################################################
# This script reads a room.list file containing Matrix room IDs and their      #
# message counts, then purges history older than 30 days for each room (except #
# those ending with 'fdn.fr'). Automatically confirms "Y" to synadm prompts.    #
#                                                                              #
# DISCLAIMER: This script comes with no warranties. Use at your own risk.     #
#                                                                              #
# 2023-11-15 [YYYY-MM-DD]                                                     #
# Written by: vlp and botbot 🤖                                               #
#                                                                              #
# Variable names are uppercased if the variable is read-only or if it is an    #
# external variable.                                                          #
################################################################################

######################################
# Global Variables
######################################

# File containing room information (room_id and count)
readonly ROOM_LIST_FILE="room.list"

# Days of history to keep (30 days)
readonly DAYS_TO_KEEP=30

# Domain to exclude from processing
readonly EXCLUDE_DOMAIN="fdn.fr"

################################################################################
# Function: display_usage
# Description: Shows script usage information
# Input: None
# Output: Prints usage information to stdout
# Called by: main, when invalid arguments are provided or -h/--help is used
################################################################################
function display_usage {
    cat <<EOF
Usage: $(basename "$0") [options]

This script purges Matrix room history older than ${DAYS_TO_KEEP} days for all rooms
listed in ${ROOM_LIST_FILE}, except those ending with ${EXCLUDE_DOMAIN}.
Automatically confirms "Y" to synadm prompts.

Options:
  -h, --help    Show this help message and exit

The input file should be formatted as an ASCII table with two columns:
  1. room_id
  2. count (ignored by this script)

Example input line:
 !OGEhHVWSdvArJzumhm:matrix.org               | 159072707
EOF
}

################################################################################
# Function: is_valid_room_id
# Description: Validates a Matrix room ID format
# Input: $1 - room_id to validate
# Output: Returns 0 if valid, 1 if invalid
# Called by: process_room_list
################################################################################
function is_valid_room_id {
    local room_id="$1"

    # Basic pattern for Matrix room ID: ! followed by letters/numbers, then : then domain
    if [[ "$room_id" =~ ^![a-zA-Z0-9_=/-]+:[a-zA-Z0-9.-]+$ ]]; then
        return 0
    else
        return 1
    fi
}

################################################################################
# Function: should_process_room
# Description: Determines if a room should be processed based on exclusion rules
# Input: $1 - room_id to check
# Output: Returns 0 if should process, 1 if should skip
# Called by: process_room_list
################################################################################
function should_process_room {
    local room_id="$1"

    # Skip if room ends with excluded domain
    if [[ "$room_id" == *"${EXCLUDE_DOMAIN}"* ]]; then
        return 1
    fi

    return 0
}

################################################################################
# Function: purge_room_history
# Description: Purges history for a specific room with automatic confirmation
# Input: $1 - room_id to purge
# Output: Returns 0 on success, 1 on failure
# Called by: process_room_list
################################################################################
function purge_room_history {
    local room_id="$1"

    # Use yes to automatically answer "Y" to any prompts
    # Redirect stderr to stdout to capture all output
    if yes | synadm history purge "$room_id" -d "${DAYS_TO_KEEP}" 2>&1; then
        return 0
    else
        return 1
    fi
}

################################################################################
# Function: generate_room_list
# Description: Generates the room.list file by querying the Synapse database
# Input: None (uses global ROOM_LIST_FILE)
# Output: Creates/overwrites ROOM_LIST_FILE with query results
#         Returns 0 on success, 1 on failure
# Called by: main, before processing the room list
################################################################################
function generate_room_list {
    local temp_file
    temp_file=$(mktemp)

    echo "Generating room list from database..."

    # Execute the SQL query and capture output
    if ! sudo -u postgres bash -c \
        'psql --dbname=synapse --command="SELECT room_id, count(*) AS count FROM state_groups_state GROUP BY room_id ORDER BY count DESC LIMIT 1000;"' \
        > "$temp_file" 2>&1; then
        echo "Error: Failed to generate room list from database" >&2
        echo "PostgreSQL output:" >&2
        cat "$temp_file" >&2
        rm -f "$temp_file"
        return 1
    fi

    # Check if we got valid output (at least a header line and some data)
    if ! grep -q "room_id.*|.*count" "$temp_file" || ! grep -q "!.*|" "$temp_file"; then
        echo "Error: Unexpected output format from database query" >&2
        echo "Output was:" >&2
        cat "$temp_file" >&2
        rm -f "$temp_file"
        return 1
    fi

    # Move the temp file to our target location
    if ! mv "$temp_file" "${ROOM_LIST_FILE}"; then
        echo "Error: Failed to save room list to ${ROOM_LIST_FILE}" >&2
        rm -f "$temp_file"
        return 1
    fi

    echo "Successfully generated room list with top 1000 rooms by message count"
    return 0
}

################################################################################
# Function: process_room_list
# Description: Processes the room list file and purges history for each room
# Input: None (uses global ROOM_LIST_FILE)
# Output: Prints status messages to stdout
# Called by: main
################################################################################
function process_room_list {
    local line_number=0
    local rooms_processed=0
    local rooms_skipped=0
    local rooms_failed=0

    # Check if file exists and is readable
    if [[ ! -f "${ROOM_LIST_FILE}" || ! -r "${ROOM_LIST_FILE}" ]]; then
        echo "Error: Cannot read file ${ROOM_LIST_FILE}" >&2
        return 1
    fi

    echo "Starting room history purge process..."
    echo "----------------------------------------"

    # Process each line in the file
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_number++))

        # Skip empty lines and header lines
        if [[ -z "$line" || "$line" =~ ^[-+|]+$ || "$line" =~ ^[[:space:]]*[Rr][Oo][Oo][Mm]_?[Ii][Dd] ]]; then
            continue
        fi

        # Extract room_id (first column, before the |)
        local room_id
        room_id=$(echo "$line" | awk -F'|' '{print $1}' | xargs)

        # Validate room_id
        if ! is_valid_room_id "$room_id"; then
            echo "Line ${line_number}: Invalid room ID format: '${room_id}' - skipping" >&2
            ((rooms_skipped++))
            continue
        fi

        # Check if we should process this room
        if ! should_process_room "$room_id"; then
            echo "Line ${line_number}: Skipping room ${room_id} (matches exclusion rules)"
            ((rooms_skipped++))
            continue
        fi

        # Process the room
        echo "Line ${line_number}: Purging history for room ${room_id}..."
        if purge_room_history "$room_id"; then
            echo "Successfully purged history for ${room_id}"
            ((rooms_processed++))
        else
            echo "Error: Failed to purge history for ${room_id}" >&2
            ((rooms_failed++))
        fi
    done < "${ROOM_LIST_FILE}"

    echo "----------------------------------------"
    echo "Processing complete."
    echo "Rooms processed successfully: ${rooms_processed}"
    echo "Rooms skipped: ${rooms_skipped}"
    echo "Rooms failed: ${rooms_failed}"

    if [[ ${rooms_failed} -gt 0 ]]; then
        return 1
    fi

    return 0
}

################################################################################
# Function: main
# Description: Main entry point for the script
# Input: Command line arguments
# Output: Depends on operations performed
# Called by: Script execution starts here
################################################################################
function main {
    # Process command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                display_usage
                exit 0
                ;;
            *)
                echo "Error: Unknown option '$1'" >&2
                display_usage
                exit 1
                ;;
        esac
        shift
    done

    # Generate the room list first
    if ! generate_room_list; then
        exit 1
    fi

    # Then process it
    if ! process_room_list; then
        echo "Completed with errors. See above for details." >&2
        exit 1
    fi

    echo "Completed successfully."
    exit 0
}
