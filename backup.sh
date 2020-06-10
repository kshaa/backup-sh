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
if [[ "$#" -gt 2 ]]
then
    shift && shift
    FILTER_VALUES=("${@:-}")
else
    FILTER_VALUES=()
fi

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
    echo "  describe            List existing backup(s) in storage with extra info"
    echo "  create              Create a backup"
    echo "  restore             Restore a backup"
    echo "  delete              Delete a backup"
    echo "  dump                Pretty print JSON config file"
    echo "  help                Print this help"
    echo "  help-config         Print help about config file"
    echo
    echo "Options:"
    echo "  name NAME           Filter a specific backup in storage by name (for filtering)"
    echo "  groups GROUPS...    Filter backups by groups or set additional groups for"
    echo "                      newly created archive (for filtering and creation)"
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

# Ingress: Read JSON or YAML (if possible)
if [ -x "$(command -v yq)" ]
then
    CONFIG_JSON="$(cat $CONFIG | yq -r .)"
else
    CONFIG_JSON="$(cat $CONFIG | jq -r .)"
fi

# Dump config if needed
if [ "$ACTION" == "dump" ]
then
    echo $CONFIG_JSON | jq -r .
    exit 0
fi

# Backup common configurations
BACKUP_TYPE="$(echo $CONFIG_JSON | jq -r .type)"
BACKUP_NAME="$(echo $CONFIG_JSON | jq -r .name)"
BACKUP_DESCRIPTION="$(echo $CONFIG_JSON | jq -r .description)"
RESOURCE_PATH_RAW="$(echo $CONFIG_JSON | jq -r .resource_path)"
RESOURCE_PATH="${RESOURCE_PATH_RAW%/}"
STORAGE_PATH_RAW="$(echo $CONFIG_JSON | jq -r .storage_path)"
STORAGE_PATH="${STORAGE_PATH_RAW%/}"
RESOURCE_TYPE="$(echo $CONFIG_JSON | jq -r .resource_type)"

# Validation: Backup type is correct
if [ "$(echo '[ "local", "remote" ]' | jq '.[] | select(contains("'$BACKUP_TYPE'"))')" == "" ]
then
    echo "Error: Unknown backup type '$BACKUP_TYPE'" >&2
    echo "Run '$SCRIPT help-config' for help" >&2
    exit 1
fi

# Validation: Backup resource type is correct
if [ "$(echo '[ "file", "directory" ]' | jq '.[] | select(contains("'$RESOURCE_TYPE'"))')" == "" ]
then
    echo "Error: Unknown backup resource type '$BACKUP_TYPE'" >&2
    echo "Run '$SCRIPT help-config' for help" >&2
    exit 1
fi

# Validation: Filter is correct
if [ "$ACTION" == "create" ]
then
    ALLOWED_FILTERS='[ "groups" ]'
else
    ALLOWED_FILTERS='[ "name", "groups" ]'
fi
if [ -n "$FILTER" ] && [ "$(echo "$ALLOWED_FILTERS" | jq '.[] | select(contains("'$FILTER'"))')" == "" ]
then
    echo "Error: Invalid filter '$FILTER'" >&2
    echo "Run '$SCRIPT help' for help" >&2
    exit 1
fi

# Validation: If filtering is used, filter value is required
if [ -n "$FILTER" ] && [ -z "${FILTER_VALUES[0]:-}" ]
then
    echo "Error: Filter '$FILTER' is used, but no filter value provided"
    exit 1
fi

# Validation: Backup resource actually matches expected type if it exists
if ls "$RESOURCE_PATH" 1>/dev/null 2>/dev/null
then
    if  [ "$RESOURCE_TYPE" == "file" ] && [ ! -f "$RESOURCE_PATH" ] || \
        [ "$RESOURCE_TYPE" == "directory" ] && [ ! -d "$RESOURCE_PATH" ]
    then
        echo "Error: Backup resource doesn't match type '$RESOURCE_TYPE'" >&2
        exit 1
    fi
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
                if  [ -z "$(echo $INFO_JSON | jq '.name' -r)" ] && \
                    [ -n "$VERBOSE" ]
                then
                    echo "Invalid archive: $BACKUP_PATH" >&2
                    continue
                fi
                INFO_JSON="$(echo $INFO_JSON | jq '. * { meta: { backup_path: "'$BACKUP_PATH'" } }' -r)"
                BACKUP_INFOS="$(echo $BACKUP_INFOS | jq "[ .[], $INFO_JSON ]" -r)"
            fi
        done

        echo "$BACKUP_INFOS" | jq '.' -r
    fi
}

# Backup utility: Filter backups
# Takes a list of backup infos and filters
# only relevant backups based on parameters
filter_backup_infos() {
    BACKUP_INFOS="${1:-}"
    BACKUP_INFOS="$(echo "$BACKUP_INFOS" | jq '[ .[] | select(.groups[]? | contains("'$BACKUP_NAME'")) ]')"
    if [ "$FILTER" == "name" ]
    then
        NAME="${FILTER_VALUES[0]:-}"
        BACKUP_INFOS="$(echo "$BACKUP_INFOS" | jq '[ .[] | select(.name == "'$NAME'") ]')"
    elif [ "$FILTER" == "groups" ]
    then
        for GROUP in "${FILTER_VALUES[@]}"; do
            BACKUP_INFOS="$(echo "$BACKUP_INFOS" | jq '[ .[] | select(.groups[]? | contains("'$GROUP'")) ]')"
        done
    fi

    echo "$BACKUP_INFOS" | jq -r '. | sort_by(.created_at)'
}

# Backup utility: Create backup
# Generates a JSON list of information about
# backups currently available in storage
create_backup() {
    # Validation backup resource exists
    if ! ls "$RESOURCE_PATH" 1>/dev/null 2>/dev/null
    then
        echo "Error: Backup resource doesn't exist" >&2
        exit 1
    fi

    # Groups
    TIMESTAMP="$(date +"%Y-%m-%d-%H-%M-%S")"
    BACKUP_GROUPS="[ \"$BACKUP_NAME\", \"$TIMESTAMP\" ]"
    if [ "$FILTER" == "groups" ]
    then
        for GROUP in "${FILTER_VALUES[@]}"
        do
            BACKUP_GROUPS="$(echo "$BACKUP_GROUPS" | jq '[ .[], "'"$GROUP"'" ]')"
        done
    fi

    # Backup creation
    BACKUP_FULL_NAME="$BACKUP_NAME-$TIMESTAMP"
    STORAGE_FULL_PATH="$STORAGE_PATH/$BACKUP_FULL_NAME"
    if [ "$BACKUP_TYPE" == "local" ]
    then
        mkdir "$STORAGE_FULL_PATH"
        if [ "$RESOURCE_TYPE" == "file" ]
        then
            rsync --delete -rvh "$RESOURCE_PATH" "$STORAGE_FULL_PATH/data"
        elif [ "$RESOURCE_TYPE" == "directory" ]
        then
            mkdir "$STORAGE_FULL_PATH/data"
            rsync --delete -rvh "$RESOURCE_PATH/" "$STORAGE_FULL_PATH/data/"
        fi
        INFO="$(jq -nr "{ name: \"$BACKUP_FULL_NAME\", description: \"$BACKUP_DESCRIPTION\", created_at: \"$TIMESTAMP\", groups: $BACKUP_GROUPS }")"
        echo "$INFO" | jq '.' -r > $STORAGE_FULL_PATH/info.json
    fi
}

# Backup utility: Delete backup
delete_backup() {
    BACKUP_INFO="${1:-}"
    BACKUP_PATH="$(echo "$BACKUP_INFO" | jq '.meta.backup_path' -r)"
    if [ "$BACKUP_TYPE" == "local" ]
    then
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
        
        if [ "$RESOURCE_TYPE" == "file" ]
        then
            rsync --delete -rvh "$BACKUP_PATH/data" "$RESOURCE_PATH"
        elif [ "$RESOURCE_TYPE" == "directory" ]
        then
            if ! ls "$RESOURCE_PATH" 1>/dev/null 2>/dev/null
            then
                mkdir "$RESOURCE_PATH"
            fi
            rsync --delete -rvh "$BACKUP_PATH/data/" "$RESOURCE_PATH/"
        fi
    fi
}

# Run appropriate command based on parameters
if [ "$ACTION" == "get" ]
then
    BACKUP_INFOS="$(fetch_backup_infos)"
    BACKUP_INFOS="$(filter_backup_infos "$BACKUP_INFOS")"
    echo $BACKUP_INFOS | jq -r '.[] | { name, created_at, groups } ' 
elif [ "$ACTION" == "describe" ]
then
    BACKUP_INFOS="$(fetch_backup_infos)"
    BACKUP_INFOS="$(filter_backup_infos "$BACKUP_INFOS")"
    echo $BACKUP_INFOS | jq -r
elif [ "$ACTION" == "create" ]
then
    create_backup
elif [ "$ACTION" == "restore" ]
then
    BACKUP_INFOS="$(fetch_backup_infos)"
    BACKUP_INFOS="$(filter_backup_infos "$BACKUP_INFOS")"
    restore_backup "$BACKUP_INFOS"
elif [ "$ACTION" == "delete" ]
then
    BACKUP_INFOS="$(fetch_backup_infos)"
    BACKUP_INFOS="$(filter_backup_infos "$BACKUP_INFOS")"
    echo "$BACKUP_INFOS" | jq -rc '.[]' | while IFS='' read BACKUP_INFO
    do
        delete_backup "$BACKUP_INFO"
    done
fi