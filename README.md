# Matrix Cleaner

A collection of Bash scripts designed to help administrators clean and maintain large [Matrix](https://matrix.org/) (Synapse) databases by removing old message history and deleting empty rooms.

## Overview

Matrix Cleaner provides two powerful scripts for database maintenance:

1. **clean_top_event_room.sh** - Purges message history older than 30 days from the busiest rooms
2. **delete_empty_room.sh** - Identifies and removes rooms with 0 or 1 joined members

These scripts are particularly useful for Matrix homeserver administrators dealing with database growth issues and wanting to reclaim storage space.

## ⚠️ Important Warnings

- **USE AT YOUR OWN RISK** - These scripts come with no warranties
- **Data Loss** - Purging history and deleting rooms is irreversible
- **Always backup your database** before running these scripts
- **Test in a staging environment** first if possible
- These scripts directly interact with your Synapse database and use synadm commands

## Prerequisites

- **Operating System**: Linux/Unix-based system with Bash
- **Matrix Synapse**: A running Synapse homeserver
- **PostgreSQL**: Database backend for Synapse (scripts query the database directly)
- **synadm**: Synapse admin CLI tool ([installation guide](https://github.com/JOJ0/synadm))
- **Root/sudo access**: Required for PostgreSQL database queries
- **Standard Unix utilities**: awk, sed, grep, xargs

### Installing synadm

```bash
# Install synadm using pip
pip install synadm

# Configure synadm with your homeserver details
synadm config
```

## Scripts Documentation

### 1. clean_top_event_room.sh

Purges message history older than 30 days from the top 1000 rooms (by message count) in your Matrix database.

#### Features

- Automatically generates a room list by querying the Synapse database
- Identifies the top 1000 rooms by message/event count
- Purges history older than 30 days for each room
- Excludes rooms ending with a specific domain (default: `fdn.fr`)
- Automatic confirmation for synadm prompts
- Comprehensive error handling and logging

#### Usage

```bash
# Display help
./clean_top_event_room.sh --help

# Run the script (will purge history from top 1000 rooms)
./clean_top_event_room.sh
```

#### Configuration

You can modify these variables at the top of the script:

- `DAYS_TO_KEEP`: Number of days of history to retain (default: 30)
- `EXCLUDE_DOMAIN`: Domain to exclude from processing (default: "fdn.fr")
- `ROOM_LIST_FILE`: File containing room list (default: "room.list")

#### How It Works

1. Queries the Synapse database to identify top 1000 rooms by event count
2. Generates a `room.list` file with room IDs and message counts
3. Validates each room ID format
4. Skips rooms matching the exclusion domain
5. Calls `synadm history purge` for each qualifying room
6. Reports statistics on completion

### 2. delete_empty_room.sh

Identifies and deletes Matrix rooms with 0 or 1 joined members, helping to clean up abandoned or unused rooms.

#### Features

- Three operating modes: automatic, dry-run, and manual
- Automatically generates a room list from the database
- Filters rooms with minimal members
- Detailed room information display
- Safe deletion with confirmation options

#### Usage

```bash
# Display help
./delete_empty_room.sh --help

# Dry-run mode - see what would be deleted without making changes
./delete_empty_room.sh --dry-run

# Automatic mode - delete all qualifying rooms automatically
./delete_empty_room.sh

# Manual mode - review each room and confirm before deletion
./delete_empty_room.sh --manual

# Set custom threshold for empty rooms (e.g., rooms with 2 or fewer members)
./delete_empty_room.sh --threshold 2
```

#### Operating Modes

- **Automatic Mode** (default): Deletes all rooms with ≤1 members automatically
- **Dry-Run Mode** (`-d`, `--dry-run`): Shows what would be done without making changes
- **Manual Mode** (`-m`, `--manual`): Displays detailed room info and prompts for confirmation

#### Configuration

You can modify these settings via command-line arguments:

- `--threshold <number>`: Set the minimum joined members threshold (default: 1)
- `--force`: Force regeneration of the input file from the database

The default threshold is 1, meaning rooms with 0 or 1 joined members are considered empty.

#### How It Works

1. Queries the Synapse database for room statistics
2. Generates an `empty.list` file with room data
3. Filters rooms with joined_members ≤ threshold
4. Displays room information (ID, name, local users, joined members)
5. Deletes qualifying rooms based on selected mode
6. Reports summary statistics

## Quick Start

1. **Ensure Prerequisites**: Install synadm and configure it with your homeserver
   ```bash
   pip install synadm
   synadm config
   ```

2. **Clone/Download Scripts**: Make them executable
   ```bash
   chmod +x clean_top_event_room.sh delete_empty_room.sh
   ```

3. **Backup Your Database**: Always backup before running
   ```bash
   sudo -u postgres pg_dump synapse > synapse_backup_$(date +%Y%m%d).sql
   ```

4. **Test with Dry Run**: Test the delete script first
   ```bash
   ./delete_empty_room.sh --dry-run
   ```

5. **Run Scripts**: Execute based on your needs
   ```bash
   # Clean empty rooms
   ./delete_empty_room.sh

   # Clean old history from busy rooms
   ./clean_top_event_room.sh
   ```

## Safety Tips

- **Start Small**: Use the dry-run mode first to see what would be affected
- **Test Incrementally**: Consider modifying scripts to process fewer rooms initially
- **Monitor Logs**: Watch the output carefully for any errors
- **Database Backups**: Always maintain recent backups
- **Disk Space**: Ensure adequate free space for database operations
- **Off-Peak Hours**: Run during low-traffic periods to minimize impact
- **Review Exclusions**: Check the exclude domain setting matches your needs

## Troubleshooting

### Script fails with "synadm command not found"
- Install synadm: `pip install synadm`
- Configure synadm: `synadm config`

### Database connection errors
- Verify PostgreSQL is running
- Check database name is "synapse" or update scripts accordingly
- Ensure the script user has sudo access to run postgres commands

### Permission denied errors
- Ensure scripts are executable: `chmod +x *.sh`
- Verify sudo access for PostgreSQL operations

### No rooms found / Empty list
- Verify the database query is working: Check `room.list` or `empty.list` files
- Adjust threshold values if needed

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

This project is provided as-is with no warranties. Use at your own risk.

## Credits

Written by: vlp and botbot 🤖

## Additional Resources

- [Matrix.org](https://matrix.org/) - Matrix protocol homepage
- [Synapse Documentation](https://matrix-org.github.io/synapse/) - Synapse homeserver docs
- [synadm GitHub](https://github.com/JOJ0/synadm) - Synapse admin CLI tool
- [Matrix Admin Guide](https://matrix.org/docs/guides/administration) - General Matrix admin resources
