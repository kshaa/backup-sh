#!/usr/bin/env bash

# Fail hard
set -eu

# Environment variables
DEBUG="${DEBUG:-}"
VERBOSE="${VERBOSE:-}"
CONFIG="${BACKUP_CONFIG:-backup.json}"

# Named parameters
SCRIPT="${0:-}"
ACTION="${1:-}"
FILTER="${2:-}"

# Script usage documentation
help() {
    echo "Usage: BACKUP_CONFIG=\"./path/to/backup.json\" $SCRIPT ACTION [OPTIONS]..."
    echo "Create and restore backups"
    echo
    echo "Params:"
    echo "  ACTION              Action to be taken by this script"
    echo "  FILTER              Filter to specify a subset of backup(s)"
    echo
    echo "Actions:"
    echo "  get                 List existing backup(s) in storage"
    echo "  create              Create a backup"
    echo "  restore             Restore a backup"
    echo "  delete              Delete a backup"
    echo "  dump                Pretty print JSON config file"
    echo "  help                Print this help"
    echo "  help-config         Print help about config file"
    echo
    echo "Options:"
    echo "  name NAME           Filter a specific backup in storage by name (for get/delete/restore)"
    echo "  groups GROUPS...    Filter backups by groups or set additional groups for"
    echo "                      newly created archive (for get/delete/restore/create)"
    echo
    echo "Environment variables:"
    echo "  BACKUP_CONFIG       Environment variable with path to backup"
    echo "                      configuration file in JSON format, note that"
    echo "                      if yq is installed, then YAML format is also supported"
    echo "  DEBUG               If variable is non-zero, then print more"
    echo "                      information for debugging"
    echo "  VERBOSE             If variable is non-zero, then print more"
    echo "                      information regarding task execution"
}

# Script configuration documentation
help_config() {
    echo "$SCRIPT configuration file documentation"
    echo "Configuration parameters described in JSON path format"
    echo
    echo ".                     <object>    Backup configuration"
}

# Validation: Check if jq exists
# Source: https://stackoverflow.com/a/26759734
if ! [ -x "$(command -v jq)" ]
then
  echo 'Error: jq is not installed.' >&2
  exit 1
fi

# Validation: Check if yq exists
# Source: https://stackoverflow.com/a/26759734
if ! [ -x "$(command -v yq)" ] && [ -n "$VERBOSE" ]
then
  echo 'Warn: yq is not installed.' >&2
fi

# Validation: Action is required
if [ -z "$ACTION" ]
then
    echo "Error: missing action parameter"
    echo "Run '$SCRIPT help' for help"
    exit 1
fi

# Print help if needed
if [ "$ACTION" == "help" ]
then
    help
    exit 0
elif [ "$ACTION" == "help-config" ]
then
    help_config
    exit 0
fi

# Validation: Config file must exist
if [ ! -f "$CONFIG" ]
then
    echo "Error: task configuration file '$CONFIG' doesn't exist"
    echo "Run '$SCRIPT help' for help"
    exit 1
fi

# Validation: If filtering is used, filter value is required
if [ -n "$FILTER" ] && [ -z "${3:-}" ]
then
    echo "Error: Filter '$FILTER' is used, but no filter value provided"
    exit 1
fi

# Ingress: Read JSON or YAML (if possible)
if [ -x "$(command -v yq)" ]
then
    CONFIG_JSON="$(cat $CONFIG | yq  '.' -r)"
else
    CONFIG_JSON="$(cat $CONFIG | jq '.' -r)"
fi

# Dump config if needed
if [ "$ACTION" == "dump" ]
then
    echo $CONFIG_JSON | jq -r
    exit 0
fi

# Backup common configurations
BACKUP_TYPE="$(echo $CONFIG_JSON | jq '.type' -r)"
BACKUP_NAME="$(echo $CONFIG_JSON | jq '.name' -r)"
BACKUP_DESCRIPTION="$(echo $CONFIG_JSON | jq '.description' -r)"
RESOURCE_PATH_RAW="$(echo $CONFIG_JSON | jq '.resource_path' -r)"
RESOURCE_PATH="${RESOURCE_PATH_RAW%/}"
STORAGE_PATH_RAW="$(echo $CONFIG_JSON | jq '.storage_path' -r)"
STORAGE_PATH="${STORAGE_PATH_RAW%/}"

# Validation: Backup type is correct
TYPE_VALID=""
for KNOWN_TYPE in "local" "remote"
do
    if [ "$BACKUP_TYPE" == "$KNOWN_TYPE" ]
    then
        TYPE_VALID="1"
    fi
done
if [ -z "$TYPE_VALID" ]
then
    echo "Error: Unknown backup type '$BACKUP_TYPE'"
    echo "Run '$SCRIPT help-config' for help"
    exit 1
fi

# Backup utility: Fetch backups
# Generates a JSON list of information about
# backups currently available in storage
fetch_backup_infos() {
    BACKUP_INFOS="[]"
    if [ "$BACKUP_TYPE" == "local" ]
    then
        for BACKUP_PATH in $(find $STORAGE_PATH)
        do
            INFO_PATH="$BACKUP_PATH/info.json"
            if [ -f "$INFO_PATH" ]
            then
                INFO_JSON="$(cat $INFO_PATH)"
                if [ -z "$(echo $INFO_JSON | jq '.name' -r)" ]
                then
                    if [ -n "$VERBOSE" ]; then echo "Invalid archive: $BACKUP_PATH" >&2; fi
                    continue
                fi
                INFO_JSON="$(echo $INFO_JSON | jq '. * { meta: { backup_path: "'$BACKUP_PATH'" } }' -r)"
                BACKUP_INFOS="$(echo $BACKUP_INFOS | jq "[ .[], $INFO_JSON ]" -r)"
            fi
        done

        echo "$BACKUP_INFOS" | jq '.' -r
    else
        echo "Error: fetch_backup_infos not supported" >&2
        exit 1
    fi
}

# Backup utility: Filter backups
# Takes a list of backup infos and filters
# only relevant backups based on parameters
filter_backup_infos() {
    BACKUP_INFOS="${1:-}"
    FILTER="${2:-}"
    if [ "$FILTER" == "name" ]
    then
        shift
        shift
        NAME="${3:-}"
        JQ_QUERY="echo \"\$BACKUP_INFOS\" | jq '[ .[] | select(.name == \"$NAME\") ]'"
        if [ -n "$DEBUG" ]; then echo "Debug: Backup group filter: $JQ_QUERY" >&2; fi
        BACKUP_INFOS="$(eval "$JQ_QUERY")"
    elif [ "$FILTER" == "groups" ]
    then
        shift
        shift
        shift
        shift
        for GROUP in "$@"
        do
            shift
            JQ_QUERY="echo \"\$BACKUP_INFOS\" | jq '[ .[] | select(.groups[]? | contains(\"$GROUP\")) ]'"
            if [ -n "$DEBUG" ]; then echo "Debug: Backup group filter: $JQ_QUERY" >&2; fi
            BACKUP_INFOS="$(eval "$JQ_QUERY")"
        done
    elif [ -n "$FILTER" ]
    then
        echo "Error: Unknown filter '$FILTER'" >&2
        echo "Run '$SCRIPT help' for help" >&2
        exit 1
    fi

    echo "$BACKUP_INFOS" | jq -r '. | sort_by(.created_at)'
}

# Backup utility: Create backup
# Generates a JSON list of information about
# backups currently available in storage
create_backup() {
    # Backup creation info
    TIMESTAMP="$(date +"%Y-%m-%d-%H-%M-%S")"
    BACKUP_FULL_NAME="$BACKUP_NAME-$TIMESTAMP"

    # Groups
    BACKUP_GROUPS="[ \"$BACKUP_NAME\", \"$TIMESTAMP\" ]"
    if [ "$FILTER" == "groups" ]
    then
        shift
        shift
        for GROUP in "$@"
        do
            shift
            BACKUP_GROUPS="$(echo "$BACKUP_GROUPS" | jq '[ .[], "'"$GROUP"'" ]')"
        done
    elif [ -n "$FILTER" ]
    then
        echo "Error: Unknown backup creation option '$FILTER'" >&2
        echo "Run '$SCRIPT help' for help" >&2
        exit 1
    fi

    # Backup creation
    if [ "$BACKUP_TYPE" == "local" ]
    then
        STORAGE_FULL_PATH="$STORAGE_PATH/$BACKUP_FULL_NAME"
        mkdir "$STORAGE_FULL_PATH"
        rsync "$RESOURCE_PATH" "$STORAGE_FULL_PATH/data"
        INFO="$(jq -nr "{ name: \"$BACKUP_FULL_NAME\", description: \"$BACKUP_DESCRIPTION\", created_at: \"$TIMESTAMP\", groups: $BACKUP_GROUPS }")"
        echo "$INFO" | jq '.' -r > $STORAGE_FULL_PATH/info.json
    fi
}

# Backup utility: Delete backup
delete_backup() {
    BACKUP_INFO="${1:-}"
    if [ "$BACKUP_TYPE" == "local" ]
    then
        BACKUP_PATH="$(echo "$BACKUP_INFO" | jq '.meta.backup_path' -r)"
        rm -r $BACKUP_PATH
    fi
}

# Backup utility: Restore backup
restore_backup() {
    BACKUP_INFOS="${1:-}"
    LATEST_BACKUP="$(echo "$BACKUP_INFOS" | jq '.[-1]')"
    if [ "$LATEST_BACKUP" == "null" ]
    then
        echo "Error: No backup to restore from" >&2
        exit 1
    fi

    if [ "$BACKUP_TYPE" == "local" ]
    then
        BACKUP_PATH="$(echo "$LATEST_BACKUP" | jq '.meta.backup_path' -r)"
        if [ -n "$VERBOSE" ]; then echo "Restoring from: $BACKUP_PATH"; fi
        rsync "$BACKUP_PATH/data" "$RESOURCE_PATH"
    fi
}

# Run appropriate command based on parameters
if [ "$ACTION" == "get" ]
then
    BACKUP_INFOS="$(fetch_backup_infos)"
    BACKUP_INFOS="$(filter_backup_infos "$BACKUP_INFOS" "$FILTER" "$@")"
    echo $BACKUP_INFOS | jq '.'
elif [ "$ACTION" == "create" ]
then
    create_backup "$@"
elif [ "$ACTION" == "restore" ]
then
    BACKUP_INFOS="$(fetch_backup_infos)"
    BACKUP_INFOS="$(filter_backup_infos "$BACKUP_INFOS" "$FILTER" "$@")"

    restore_backup "$BACKUP_INFOS"
elif [ "$ACTION" == "delete" ]
then
    BACKUP_INFOS="$(fetch_backup_infos)"
    BACKUP_INFOS="$(filter_backup_infos "$BACKUP_INFOS" "$FILTER" "$@")"
    for BACKUP_INFO in $(echo "$BACKUP_INFOS" | jq -r '.[] | @base64')
    do
        # Source: https://www.starkandwayne.com/blog/bash-for-loop-over-json-array-using-jq/
        _jq() {
            SHORT_JQ_QUERY="$1"
            JQ_QUERY="echo \$BACKUP_INFO | base64 --decode | jq -r \"$SHORT_JQ_QUERY\""
            if [ -n "$DEBUG" ]; then echo "Debug: Backup attribute filter: $JQ_QUERY" >&2; fi
            echo "$(eval $JQ_QUERY)"
        }

        delete_backup "$(_jq '.')"
    done
fi