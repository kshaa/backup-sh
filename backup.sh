#!/usr/bin/env bash

# If any statement in this script fails
# Then the whole script should fail
# TL;DR Fail hard! Strict mode!
set -eu

# Environment variables
DEBUG="${DEBUG:-}"
VERBOSE="${VERBOSE:-}"
CONFIG="${BACKUP_CONFIG:-backup.json}"
if [ -n "$DEBUG" ]
then
    # In debug mode, just print as much as possible
    set -x
fi

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
    echo ".                         <object>    Backup configuration"
    echo ".type                     <string>    Backup storage type (local or ssh)"
    echo ".name                     <string>    Backup name, purely informative"
    echo ".acl                      <bool>      Whether access control list i.e. permissions should be backed up"
    echo ".description              <string>    Backup description, purely informative"
    echo ".resource_type            <string>    Backup resource type (file or directory)"
    echo ".resource_path            <string>    Path to backup resource"
    echo ".storage_path             <string>    Filesystem path to directory where backups can be stored"
    echo ".storage_host             <string>    [For SSH] Storage server hostname"
    echo ".storage_port             <string>    [For SSH] Storage server por"
    echo ".storage_username         <string>    [For SSH] Storage server username"
    echo ".storage_private_key_path <string>    [For SSH] Filesystem path to storage server private key"
    echo ".storage_password_path    <string>    [For SSH] Filesystem path to storage server password"
}

# Validation: Check if jq exists
if ! [ -x "$(command -v jq)" ]
then
  echo 'Error: jq is not installed.' >&2
  exit 1
fi

# Validation: Check if yq exists
if ! [ -x "$(command -v yq)" ] && [ -n "$VERBOSE" ]
then
  echo 'Warn: yq is not installed, therefore YAML is not supported' >&2
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

# Utility: Make null keyword actually an empty string
json_nullable() {
    read VALUE
    if [ "$VALUE" == "null" ]
    then
        echo ""
    else
        echo "$VALUE"
    fi
}

# Extracted backup configurations
BACKUP_TYPE="$(echo $CONFIG_JSON | jq -r .type)"
BACKUP_NAME="$(echo $CONFIG_JSON | jq -r .name)"
BACKUP_ACL="$(echo $CONFIG_JSON | jq -r .acl)"
BACKUP_DESCRIPTION="$(echo $CONFIG_JSON | jq -r .description | json_nullable)"
RESOURCE_PATH_RAW="$(echo $CONFIG_JSON | jq -r .resource_path)"
RESOURCE_PATH="${RESOURCE_PATH_RAW%/}"
RESOURCE_TYPE="$(echo $CONFIG_JSON | jq -r .resource_type)"
STORAGE_PATH_RAW="$(echo $CONFIG_JSON | jq -r .storage_path)"
STORAGE_PATH="${STORAGE_PATH_RAW%/}"
STORAGE_PASSWORD_PATH="$(echo $CONFIG_JSON | jq -r .storage_password_path | json_nullable)"
STORAGE_PRIVATE_KEY_PATH="$(echo $CONFIG_JSON | jq -r .storage_private_key_path | json_nullable)"
STORAGE_HOST="$(echo $CONFIG_JSON | jq -r .storage_host)"
STORAGE_PORT="$(echo $CONFIG_JSON | jq -r .storage_port | json_nullable)"
STORAGE_USERNAME="$(echo $CONFIG_JSON | jq -r .storage_username | json_nullable)"

# SSH type configuration: Password
if [ -z "$STORAGE_PASSWORD_PATH" ]
then
    OPTIONAL_SSH_PASS=""
else
    OPTIONAL_SSH_PASS="sshpass -f $(realpath $STORAGE_PASSWORD_PATH)"
fi

# SSH type configuration: Private key
if [ -z "$STORAGE_PRIVATE_KEY_PATH" ]
then
    OPTIONAL_SSH_KEY_FLAG=""
else
    OPTIONAL_SSH_KEY_FLAG="-i $(realpath $STORAGE_PRIVATE_KEY_PATH)"
fi

# SSH type configuration: Port
if [ -z "$STORAGE_PORT" ]
then
    OPTIONAL_SSH_PORT_FLAG=""
else
    OPTIONAL_SSH_PORT_FLAG="-p $STORAGE_PORT"
fi

# SSH type configuration: Username component
if [ -z "$STORAGE_USERNAME" ]
then
    OPTIONAL_SSH_USER_COMPONENT=""
else
    OPTIONAL_SSH_USER_COMPONENT="$STORAGE_USERNAME@"
fi

# Validation: Hostname is required for SSH
if [ "$BACKUP_TYPE" == "ssh" ] && [ -z "$STORAGE_HOST" ]
then
    echo "Error: Hostname is required for an SSH connection" >&2
    exit 1
fi

# SSH type configuration: Host component
if [ -z "$STORAGE_HOST" ]
then
    OPTIONAL_SSH_HOST_COMPONENT=""
else
    OPTIONAL_SSH_HOST_COMPONENT="$STORAGE_HOST"
fi
# SSH type configuration: Context
if [ "$BACKUP_TYPE" == "ssh" ]
then
    OPTIONAL_SSH_USER_HOST="$OPTIONAL_SSH_USER_COMPONENT$OPTIONAL_SSH_HOST_COMPONENT"
    OPTIONAL_STORAGE_SSH_CONTEXT="$OPTIONAL_SSH_PASS ssh -q $OPTIONAL_SSH_KEY_FLAG $OPTIONAL_SSH_PORT_FLAG $OPTIONAL_SSH_USER_HOST"
    OPTIONAL_SSH="$OPTIONAL_STORAGE_SSH_CONTEXT -- "
    OPTIONAL_SSH_RSYNC_FLAG='-e "ssh '$OPTIONAL_SSH_PORT_FLAG' '$OPTIONAL_SSH_KEY_FLAG'"'
    OPTIONAL_SSH_HOST_SEPERATOR=":"
else
    OPTIONAL_SSH_USER_HOST=""
    OPTIONAL_STORAGE_SSH_CONTEXT=""
    OPTIONAL_SSH=""
    OPTIONAL_SSH_RSYNC_FLAG=""
    OPTIONAL_SSH_HOST_SEPERATOR=""
fi

if [ -n "$DEBUG" ]
then
    echo "Debug: SSH execution statement: $OPTIONAL_STORAGE_SSH_CONTEXT" >&2
fi

# Validation: SSH password requires `sshpass`
if ! [ -x "$(command -v sshpass)" ] && [ "$BACKUP_TYPE" == "ssh" ] && [ -n "$STORAGE_PRIVATE_KEY_PATH" ]
then
  echo 'Error: sshpass is not installed, but is required for SSH auth w/ password.' >&2
  exit 1
fi

# Validation: Backup type is correct
if [ "$(echo '[ "local", "ssh" ]' | jq '.[] | select(contains("'$BACKUP_TYPE'"))')" == "" ]
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
    if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "ssh" ]
    then
        for INFO_PATH in $($OPTIONAL_SSH find $STORAGE_PATH -name info.json -type f 2>/dev/null)
        do
            INFO_JSON="$($OPTIONAL_SSH cat $INFO_PATH)"
            INFO_JSON="$(echo "$INFO_JSON" | jq -r . 2>/dev/null)"
            if  [ "$?" != "0" ] || \
                [ -z "$(echo $INFO_JSON | jq '.name' -r | json_nullable)" ]
            then
                if [ -n "$VERBOSE" ]
                then
                    echo "Invalid archive: $INFO_PATH" >&2
                fi
                continue
            fi
            INFO_JSON="$(echo $INFO_JSON | jq -r --arg backup_path "$(dirname $INFO_PATH)" '. * { meta: { backup_path: $backup_path } }')"
            BACKUP_INFOS="$(echo $BACKUP_INFOS | jq -r --argjson info_json "$INFO_JSON" '[ .[], $info_json ]')"
        done
    fi

    echo "$BACKUP_INFOS" | jq '.' -r
}

# Backup utility: Filter backups
# Takes a list of backup infos and filters
# only relevant backups based on parameters
filter_backup_infos() {
    BACKUP_INFOS="${1:-}"
    BACKUP_INFOS="$(echo "$BACKUP_INFOS" | jq -r --arg backup_name "$BACKUP_NAME" '[ .[] | select(.groups[]? | contains($backup_name)) ]')"
    if [ "$FILTER" == "name" ]
    then
        NAME="${FILTER_VALUES[0]:-}"
        BACKUP_INFOS="$(echo "$BACKUP_INFOS" | jq -r --arg name "$NAME" '[ .[] | select(.name == $name) ]')"
    elif [ "$FILTER" == "groups" ]
    then
        for GROUP in "${FILTER_VALUES[@]}"; do
            BACKUP_INFOS="$(echo "$BACKUP_INFOS" | jq -r --arg group "$GROUP" '[ .[] | select(.groups[]? | contains($group)) ]')"
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
            BACKUP_GROUPS="$(echo "$BACKUP_GROUPS" | jq --arg group "$GROUP" '[ .[], $group ]')"
        done
    fi

    # Backup creation
    BACKUP_FULL_NAME="$BACKUP_NAME-$TIMESTAMP"
    STORAGE_FULL_PATH="$($OPTIONAL_SSH realpath $STORAGE_PATH)/$BACKUP_FULL_NAME"
    if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "ssh" ]
    then
        # Create directory for backup in storage
        $OPTIONAL_SSH mkdir "$STORAGE_FULL_PATH"

        # Copy backup resource to storage
        if [ "$RESOURCE_TYPE" == "file" ]; then
            OPTIONAL_DIRECTORY_SUFFIX=""
        elif [ "$RESOURCE_TYPE" == "directory" ]; then
            $OPTIONAL_SSH mkdir "$STORAGE_FULL_PATH/data"
            OPTIONAL_DIRECTORY_SUFFIX="/"
        fi

        SYNC=""
        SYNC+="$OPTIONAL_SSH_PASS rsync $OPTIONAL_SSH_RSYNC_FLAG "
        SYNC+="--progress --delete -rvh "
        SYNC+="\"$RESOURCE_PATH$OPTIONAL_DIRECTORY_SUFFIX\" "
        SYNC+="\"$OPTIONAL_SSH_USER_HOST$OPTIONAL_SSH_HOST_SEPERATOR$STORAGE_FULL_PATH/data$OPTIONAL_DIRECTORY_SUFFIX\""
        eval "$SYNC"

        # Copy backup ACL to storage if required
        if [ "$BACKUP_ACL" == "true" ]
        then
            if [ "$RESOURCE_TYPE" == "file" ]; then
                ACL="$(cd "$(dirname $RESOURCE_PATH)" && getfacl -R $(basename $RESOURCE_PATH) | base64 -w0)"
            elif [ "$RESOURCE_TYPE" == "directory" ]; then
                ACL="$(cd "$RESOURCE_PATH" && getfacl -R . | base64 -w0)"
            fi
            $OPTIONAL_SSH eval "echo \"$ACL\" | base64 -d > $STORAGE_FULL_PATH/acl.txt"
        fi

        # Copy backup meta info to storage
        INFO_STRUCTURE=''
        INFO_STRUCTURE+='{'
        INFO_STRUCTURE+='name: $name,'
        if [ "$BACKUP_ACL" == "true" ]
        then
            INFO_STRUCTURE+='acl: true,'
        else
            INFO_STRUCTURE+='acl: false,'
        fi
        INFO_STRUCTURE+='description: $description,'
        INFO_STRUCTURE+='created_at: $created_at,'
        INFO_STRUCTURE+='groups: $groups'
        INFO_STRUCTURE+='}'
        INFO="$(jq -nr "$INFO_STRUCTURE" \
            --arg name "$BACKUP_FULL_NAME" \
            --arg description "$BACKUP_DESCRIPTION" \
            --arg created_at "$TIMESTAMP" \
            --argjson groups "$BACKUP_GROUPS" | base64 -w0)"

        $OPTIONAL_SSH eval "echo \"$INFO\" | base64 -d > $STORAGE_FULL_PATH/info.json"
    fi
}

# Backup utility: Delete backup
delete_backup() {
    BACKUP_INFO="${1:-}"
    BACKUP_PATH="$(echo "$BACKUP_INFO" | jq '.meta.backup_path' -r)"
    if [ "$BACKUP_TYPE" == "local" ]
    then
        $OPTIONAL_SSH rm -r $BACKUP_PATH
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

    if [ "$BACKUP_TYPE" == "local" ] || [ "$BACKUP_TYPE" == "ssh" ]
    then
        # Get backup path in storage
        BACKUP_PATH="$(echo "$LATEST_BACKUP" | jq '.meta.backup_path' -r)"
        if [ -n "$VERBOSE" ]; then echo "Restoring from: $BACKUP_PATH"; fi

        # Create resource directory if needed
        if [ "$RESOURCE_TYPE" == "file" ]; then
            OPTIONAL_DIRECTORY_SUFFIX=""
        elif [ "$RESOURCE_TYPE" == "directory" ]; then
            if ! ls "$RESOURCE_PATH" 1>/dev/null 2>/dev/null; then
                mkdir "$RESOURCE_PATH"
            fi
            OPTIONAL_DIRECTORY_SUFFIX="/"
        fi

        # Restore backup from storage
        SYNC=""
        SYNC+="$OPTIONAL_SSH_PASS rsync $OPTIONAL_SSH_RSYNC_FLAG "
        SYNC+="--progress --delete -rvh "
        SYNC+="\"$OPTIONAL_SSH_USER_HOST$OPTIONAL_SSH_HOST_SEPERATOR$BACKUP_PATH/data$OPTIONAL_DIRECTORY_SUFFIX\" "
        SYNC+="\"$RESOURCE_PATH$OPTIONAL_DIRECTORY_SUFFIX\""
        eval "$SYNC"

        # Restore ACL if required
        if [ "$BACKUP_ACL" == "true" ]
        then
            ACL="$($OPTIONAL_SSH cat "$BACKUP_PATH/acl.txt")"
            TMPACL="$(mktemp)"
            echo "$ACL" > $TMPACL
            if [ "$RESOURCE_TYPE" == "file" ]; then
                cd "$(dirname $RESOURCE_PATH)"
            elif [ "$RESOURCE_TYPE" == "directory" ]; then
                cd $RESOURCE_PATH
            fi
            setfacl --restore=$TMPACL
            rm $TMPACL
        fi
    fi
}

# Run appropriate command based on parameters
if [ "$ACTION" == "create" ]
then
    create_backup
else
    BACKUP_INFOS="$(fetch_backup_infos)"
    BACKUP_INFOS="$(filter_backup_infos "$BACKUP_INFOS")"
    if [ "$ACTION" == "get" ]
    then
        echo $BACKUP_INFOS | jq -r '.[] | { name, created_at, groups } ' 
    elif [ "$ACTION" == "describe" ]
    then
        echo $BACKUP_INFOS | jq -r
    elif [ "$ACTION" == "restore" ]
    then
        restore_backup "$BACKUP_INFOS"
    elif [ "$ACTION" == "delete" ]
    then
        LENGTH="$(echo "$BACKUP_INFOS" | jq -r length)" && START=0 && END="$(($LENGTH - 1))"
        for (( INDEX = $START; INDEX <= $END; INDEX++ ))
        do
            BACKUP_INFO="$(echo "$BACKUP_INFOS" | jq -r --argjson index "$INDEX" '.[$index]')"
            delete_backup "$BACKUP_INFO"
        done
    fi
fi