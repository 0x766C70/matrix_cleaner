#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# This script processes a list of Matrix rooms and deletes rooms with 0 or 1
# joined members. It supports three modes:
# 1. Automatic mode (default) - deletes all qualifying rooms with auto-confirm
# 2. Dry-run mode - shows what would be done without making changes
# 3. Manual mode - shows detailed room info and prompts for deletion confirmation
#
# NO WARRANTY EXPRESSED OR IMPLIED. USE AT YOUR OWN RISK.
# 2023-11-16 [YYYY-MM-DD]
#
# Written for: Linux/Unix systems with bash, synadm, awk, and standard utils
# Written by: vlp and botbot 🤖
#
# Variable names are uppercased if the variable is read-only or if it is an
# external variable.
# -----------------------------------------------------------------------------

# ------------------------- Global Variables -------------------------
readonly INPUT_FILE="empty.list"          # Input file containing room data
readonly DEFAULT_MIN_JOINED_MEMBERS=1    # Default threshold for considering a room empty
readonly SYNADM_CMD="synadm"              # Command to interact with Synapse admin
readonly AUTO_CONFIRM="y"                 # Automatic confirmation response
readonly MANUAL_MODE=false               # Default manual mode (changed by args)
readonly DRY_RUN_FLAG=false              # Default dry-run mode (changed by args)
readonly FORCE_REGENERATE=false          # Default force regenerate (changed by args)
readonly DIVIDER_LINE="--------------------------------------------------"
# -----------------------------------------------------------------------------

# ------------------------- Function Definitions -------------------------

# -----------------------------------------------------------------------------
# function: usage
#
# Displays script usage information.
#
# Input: None
# Output: Prints usage information to stdout
# Called by: main (when invalid args or -h/--help)
# -----------------------------------------------------------------------------
function usage {
    cat <<EOF
Matrix Room Cleanup Script
---------------------------
This script processes a list of Matrix rooms and deletes rooms with 0 or 1
joined members. It supports three operating modes.

Usage: $(basename "$0") [OPTIONS]

Options:
  -d, --dry-run              Show what would be done without making changes
  -m, --manual               Manual mode - show room details and prompt before deleting
  -f, --force                Force regeneration of the input file from database
  -t, --threshold <number>   Set minimum joined members threshold (default: ${DEFAULT_MIN_JOINED_MEMBERS})
  -h, --help                 Show this help message and exit

Input File Format:
  The script expects an ASCII table in ${INPUT_FILE} with columns:
  room_id | name | local_users_in_room | joined_members

Examples:
  # Automatic mode (default) - deletes all qualifying rooms
  $(basename "$0")

  # Dry run - show what would be deleted
  $(basename "$0") --dry-run

  # Manual mode - show details and prompt before each deletion
  $(basename "$0") --manual
  
  # Force regeneration of input file
  $(basename "$0") --force

  # Set custom threshold for empty rooms (e.g., rooms with 2 or fewer members)
  $(basename "$0") --threshold 2

Notes:
  - The input file is automatically generated from the Synapse database
  - Existing input files will be reused unless --force is specified
  - Requires PostgreSQL access and synadm to be installed and configured
EOF
}


# -----------------------------------------------------------------------------
# function: create_input_file
#
# Creates the input file by querying the Synapse database for room statistics.
#
# Input: 
#   $1 - Force flag (true/false) - whether to regenerate even if file exists
# Output: Creates INPUT_FILE with room statistics
#         Prints status messages to stdout
#         Exits with error code 1 if creation fails
# Called by: main
# -----------------------------------------------------------------------------

function create_input_file {
    local force="$1"
    
    # Check if file exists and we're not forcing regeneration
    if [[ -f "${INPUT_FILE}" && "${force}" != true ]]; then
        echo "Using existing input file: ${INPUT_FILE}"
        echo "(Use --force to regenerate from database)"
        return 0
    fi
    
    echo "Generating input file from database..."
    
    # Execute the SQL query and save to INPUT_FILE
    if ! su postgres -c 'psql --dbname=synapse --command="SELECT
        room_stats_current.room_id, room_stats_state.name,
        room_stats_current.local_users_in_room, room_stats_current.joined_members
FROM room_stats_current
        LEFT JOIN room_stats_state ON room_stats_current.room_id = room_stats_state.room_id
ORDER BY joined_members DESC, local_users_in_room DESC;"' > "${INPUT_FILE}" 2>&1; then
        echo "ERROR: Failed to generate input file from database." >&2
        echo "       Make sure PostgreSQL is running and you have the necessary permissions." >&2
        exit 1
    fi
    
    # Validate that we got some data
    if [[ ! -s "${INPUT_FILE}" ]]; then
        echo "ERROR: Generated input file is empty." >&2
        exit 1
    fi
    
    echo "Successfully generated input file: ${INPUT_FILE}"
}

# -----------------------------------------------------------------------------
# function: validate_input_file
#
# Validates that the input file exists and is readable.
#
# Input: None (uses global INPUT_FILE)
# Output: None (exits with error if validation fails)
# Called by: main
# -----------------------------------------------------------------------------
function validate_input_file {
    if [[ ! -f "${INPUT_FILE}" ]]; then
        echo "ERROR: Input file '${INPUT_FILE}' not found." >&2
        exit 1
    fi

    if [[ ! -r "${INPUT_FILE}" ]]; then
        echo "ERROR: Cannot read input file '${INPUT_FILE}'." >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# function: check_synadm_available
#
# Verifies that the synadm command is available in PATH.
#
# Input: None (uses global SYNADM_CMD)
# Output: None (exits with error if command not found)
# Called by: main
# -----------------------------------------------------------------------------
function check_synadm_available {
    if ! command -v "${SYNADM_CMD}" >/dev/null 2>&1; then
        echo "ERROR: '${SYNADM_CMD}' command not found. Please install synadm." >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# function: parse_room_data
#
# Parses the input file and extracts room data with validation.
#
# Input:
#   $1 - Input file path
#   $2 - Minimum joined members threshold
# Output:
#   Prints room data in format: room_id|joined_members|name|local_users
#   Only prints rooms meeting the criteria
# Called by: process_rooms
# -----------------------------------------------------------------------------
function parse_room_data {
    local input_file="$1"
    local min_joined_members="$2"

    # Skip header and empty lines, extract relevant columns
    awk -F'|' -v threshold="${min_joined_members}" '
        NR > 3 && NF >= 4 {
            # Clean up fields (trim whitespace)
            room_id = $1;
            gsub(/^[ \t]+|[ \t]+$/, "", room_id);

            name = $2;
            gsub(/^[ \t]+|[ \t]+$/, "", name);

            local_users = $3;
            gsub(/^[ \t]+|[ \t]+$/, "", local_users);

            joined = $4;
            gsub(/^[ \t]+|[ \t]+$/, "", joined);

            # Validate that joined and local_users are numeric
            if (joined !~ /^[0-9]+$/) next;
            if (local_users !~ /^[0-9]+$/) next;

            # Only print rooms with joined_members <= threshold
            # Exclude rooms starting with # (comments) or - (dividers)
            if (joined <= threshold && room_id != "" && room_id !~ /^#/ && room_id !~ /^-/) {
                print room_id "|" joined "|" name "|" local_users;
            }
        }
    ' "${input_file}"
}

# -----------------------------------------------------------------------------
# function: display_room_details
#
# Displays detailed information about a room.
#
# Input:
#   $1 - Room ID
#   $2 - Joined members count
#   $3 - Room name
#   $4 - Local users count
# Output: Prints formatted room details to stdout
# Called by: process_room_deletion_manual
# -----------------------------------------------------------------------------
function display_room_details {
    local room_id="$1"
    local joined_members="$2"
    local room_name="$3"
    local local_users="$4"

    # Clean room_id (remove any leading/trailing whitespace or ! if present)
    local clean_room_id
    clean_room_id=$(echo "${room_id}" | sed 's/^[! \t]*//;s/[ \t]*$//')

    echo "Room Details:"
    echo "${DIVIDER_LINE}"
    echo "Room ID:       ${clean_room_id}"
    echo "Name:          ${room_name}"
    echo "Local Users:   ${local_users}"
    echo "Joined Members: ${joined_members}"
    echo "${DIVIDER_LINE}"
}

# -----------------------------------------------------------------------------
# function: get_user_confirmation
#
# Prompts the user for confirmation before proceeding.
#
# Input:
#   $1 - Prompt message
#   $2 - Default answer (y/n)
# Output:
#   Returns 0 if user confirmed (y), 1 if not confirmed (n)
# Called by: process_room_deletion_manual
# -----------------------------------------------------------------------------
function get_user_confirmation {
    local prompt="$1"
    local default="$2"
    local response

    while true; do
        read -r -p "${prompt} [${default}]: " response
        response=${response:-${default}}

        case "${response,,}" in  # Convert to lowercase
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo "Please answer yes or no (y/n)." ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# function: process_room_deletion_auto
#
# Processes deletion of a single room in automatic mode.
#
# Input:
#   $1 - Room ID
#   $2 - Joined members count
#   $3 - Room name (for display)
#   $4 - Local users count
#   $5 - Dry run flag (true/false)
# Output:
#   Prints actions taken to stdout
# Called by: process_rooms
# -----------------------------------------------------------------------------
function process_room_deletion_auto {
    local room_id="$1"
    local joined_members="$2"
    local room_name="$3"
    local local_users="$4"
    local dry_run="$5"

    # Clean room_id (remove any leading/trailing whitespace or ! if present)
    local clean_room_id
    clean_room_id=$(echo "${room_id}" | sed 's/^[# \t]*//;s/[ \t]*$//')

    if [[ "${dry_run}" == true ]]; then
        echo "[DRY RUN] Would delete room: ${clean_room_id}"
        echo "         Name: ${room_name}"
        echo "         Local Users: ${local_users}"
        echo "         Joined Members: ${joined_members}"
        echo
    else
        echo "Deleting room: ${clean_room_id}"
        echo "Name: ${room_name}"

        # Use printf to send the confirmation (more reliable than echo for some shells)
        if printf '%s\n' "${AUTO_CONFIRM}" | "${SYNADM_CMD}" room delete "${clean_room_id}" >/dev/null 2>&1; then
            echo "Successfully deleted room: ${clean_room_id}"
        else
            echo "ERROR: Failed to delete room: ${clean_room_id}" >&2
        fi
        echo
    fi
}

# -----------------------------------------------------------------------------
# function: process_room_deletion_manual
#
# Processes deletion of a single room in manual mode with user confirmation.
#
# Input:
#   $1 - Room ID
#   $2 - Joined members count
#   $3 - Room name (for display)
#   $4 - Local users count
#   $5 - Dry run flag (true/false)
# Output:
#   Prints actions taken to stdout
# Called by: process_rooms
# -----------------------------------------------------------------------------
function process_room_deletion_manual {
    local room_id="$1"
    local joined_members="$2"
    local room_name="$3"
    local local_users="$4"
    local dry_run="$5"

    # Clean room_id (remove any leading/trailing whitespace or ! if present)
    local clean_room_id
    clean_room_id=$(echo "${room_id}" | sed 's/^[! \t]*//;s/[ \t]*$//')

    # Display detailed room information
    display_room_details "${clean_room_id}" "${joined_members}" "${room_name}" "${local_users}"

    if [[ "${dry_run}" == true ]]; then
        echo "[DRY RUN] Would delete this room"
        echo
        return 0
    fi

    if get_user_confirmation "Delete this room" "n"; then
        echo "Deleting room..."

        if printf '%s\n' "${AUTO_CONFIRM}" | "${SYNADM_CMD}" room delete "${clean_room_id}" >/dev/null 2>&1; then
            echo "Successfully deleted room: ${clean_room_id}"
            echo
            return 0
        else
            echo "ERROR: Failed to delete room: ${clean_room_id}" >&2
            echo
            return 1
        fi
    else
        echo "Skipping this room."
        echo
        return 1
    fi
}

# -----------------------------------------------------------------------------
# function: process_rooms
#
# Main processing function that handles room deletion.
#
# Input:
#   $1 - Dry run flag (true/false)
#   $2 - Manual mode flag (true/false)
#   $3 - Minimum joined members threshold
# Output: None
# Called by: main
# -----------------------------------------------------------------------------
function process_rooms {
    local dry_run="$1"
    local manual_mode="$2"
    local min_joined_members="$3"
    local rooms_to_process
    local room_count=0
    local deleted_count=0

    # Get rooms that meet our criteria
    rooms_to_process=$(parse_room_data "${INPUT_FILE}" "${min_joined_members}")
    if [[ -z "${rooms_to_process}" ]]; then
        echo "No rooms found with ${min_joined_members} or fewer joined members."
        return 0
    fi

    echo "Found the following rooms with ${min_joined_members} or fewer joined members:"
    echo

    # Process each room
    while IFS='|' read -r room_id joined_members room_name local_users; do
        ((room_count++))

        if [[ "${manual_mode}" == true ]]; then
            if process_room_deletion_manual "${room_id}" "${joined_members}" "${room_name}" "${local_users}" "${dry_run}"; then
                ((deleted_count++))
            fi
        else
            process_room_deletion_auto "${room_id}" "${joined_members}" "${room_name}" "${local_users}" "${dry_run}"
            if [[ "${dry_run}" == false ]]; then
                ((deleted_count++))
            fi
        fi
    done <<< "${rooms_to_process}"

    # Summary
    echo "Summary:"
    echo "- Total rooms processed: ${room_count}"
    if [[ "${dry_run}" == false ]]; then
        echo "- Rooms deleted: ${deleted_count}"
    else
        echo "- This was a dry run. No rooms were actually deleted."
    fi
}

# -----------------------------------------------------------------------------
# function: main
#
# Main function that orchestrates the script execution.
#
# Input: Command line arguments
# Output: None
# Called by: None (entry point)
# -----------------------------------------------------------------------------
function main {
    local dry_run="${DRY_RUN_FLAG}"
    local manual_mode="${MANUAL_MODE}"
    local force_regenerate="${FORCE_REGENERATE}"
    local min_joined_members="${DEFAULT_MIN_JOINED_MEMBERS}"

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run)
                dry_run=true
                shift
                ;;
            -m|--manual)
                manual_mode=true
                shift
                ;;
            -f|--force)
                force_regenerate=true
                shift
                ;;
            -t|--threshold)
                if [[ -z "$2" || "$2" =~ ^- ]]; then
                    echo "ERROR: --threshold requires a numeric argument" >&2
                    usage
                    exit 1
                fi
                if [[ ! "$2" =~ ^[0-9]+$ ]]; then
                    echo "ERROR: --threshold must be a non-negative integer" >&2
                    usage
                    exit 1
                fi
                min_joined_members="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done

    # Validate prerequisites
    check_synadm_available
    create_input_file "${force_regenerate}"
    validate_input_file

    # Show mode status
    echo "Matrix Room Cleanup Script"
    echo "${DIVIDER_LINE}"
    if [[ "${dry_run}" == true ]]; then
        echo "Mode: DRY-RUN (no changes will be made)"
    elif [[ "${manual_mode}" == true ]]; then
        echo "Mode: MANUAL (you will be prompted before each deletion)"
    else
        echo "Mode: AUTOMATIC (all qualifying rooms will be deleted)"
    fi
    echo "Threshold: Rooms with ≤ ${min_joined_members} joined members"
    echo "${DIVIDER_LINE}"
    echo
    
    # Process rooms with the parsed arguments
    process_rooms "${dry_run}" "${manual_mode}" "${min_joined_members}"
}

# ------------------------- Script Execution -------------------------
main "$@"

