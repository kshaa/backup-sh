# Backup.sh

It's like a tiny backup utility for some minor backup management.

## Usage
```bash
$ ./backup.sh help
Usage: BACKUP_CONFIG="./path/to/backup.json" ./backup.sh ACTION [OPTIONS]...
Create and restore backups

Params:
  ACTION              Action to be taken by this script
  FILTER              Filter to specify a subset of backup(s)

Actions:
  get                 List existing backup(s) in storage
  describe            List existing backup(s) in storage with extra info
  create              Create a backup
  restore             Restore a backup
  delete              Delete a backup
  dump                Pretty print JSON config file
  help                Print this help
  help-config         Print help about config file

Options:
  name NAME           Filter a specific backup in storage by name (for filtering)
  groups GROUPS...    Filter backups by groups or set additional groups for
                      newly created archive (for filtering and creation)

Environment variables:
  BACKUP_CONFIG       Environment variable with path to backup
                      configuration file in JSON format, note that
                      if yq is installed, then YAML format is also supported
  DEBUG               If variable is non-zero, then print more
                      information for debugging
  VERBOSE             If variable is non-zero, then print more
                      information regarding task execution
```

```bash
$ ./backup.sh help-config
./backup.sh configuration file documentation
Configuration parameters described in JSON path format

.                         <object>    Backup configuration
.type                     <string>    Backup storage type (local or ssh)
.name                     <string>    Backup name, purely informative
.description              <string>    Backup description, purely informative
.resource_type            <string>    Backup resource type (file or directory)
.resource_path            <string>    Path to backup resource
.storage_path             <string>    Filesystem path to directory where backups can be stored
.storage_host             <string>    [For SSH] Storage server hostname
.storage_port             <string>    [For SSH] Storage server por
.storage_username         <string>    [For SSH] Storage server username
.storage_private_key_path <string>    [For SSH] Filesystem path to storage server private key
.storage_password_path    <string>    [For SSH] Filesystem path to storage server password
```

## Example
```bash
$ ./backup.sh get
{
  "name": "folder-2020-06-13-18-58-31",
  "created_at": "2020-06-13-18-58-31",
  "groups": [
    "folder",
    "2020-06-13-18-58-31"
  ]
}
{
  "name": "folder-2020-06-13-18-58-44",
  "created_at": "2020-06-13-18-58-44",
  "groups": [
    "folder",
    "2020-06-13-18-58-44"
  ]
}
```

```bash
$ ./backup.sh restore name folder-2020-06-13-18-58-44
receiving incremental file list
ping
              3 100%    2.93kB/s    0:00:00 (xfr#1, to-chk=0/2)

sent 49 bytes  received 104 bytes  102.00 bytes/sec
total size is 3  speedup is 0.02
```
