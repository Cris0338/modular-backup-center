# Architecture

## Design principle

Modular Backup Center separates **discovery**, **backup format**, **module-specific behavior**, and **user interface**.

The UI should never need hard-coded cards for individual Docker applications. It asks the backend for discovered logical modules and renders them dynamically.

## Logical modules

### SYSTEM

SYSTEM is always present and represents the Linux host independently from application modules.

Typical SYSTEM scope includes:

- root filesystem configuration and installed system components
- boot files and EFI data
- package inventory
- service metadata
- filesystem and partition metadata
- host-level configuration required to recreate the machine

Application data that belongs to separately recoverable modules should be excluded from SYSTEM when practical.

### Docker modules

Docker modules are discovered automatically.

Discovery rules should prefer this order:

1. Containers with the same Docker Compose project label are grouped into one module.
2. Standalone containers become individual modules.
3. A module inventory records its containers, images, volumes, bind mounts, ports, labels, restart policies and relevant deployment metadata.

The discovery engine must not assume one container equals one application.

## Adapters

Every discovered module can use a generic adapter. Specific adapters can override or extend generic behavior.

A module adapter may define:

- detection rules
- pre-backup action
- consistent database snapshot method
- paths/volumes to preserve
- Docker images to export
- post-backup action
- verification rules
- restore sequence
- post-restore health check

Examples include SQLite, PostgreSQL, MySQL/MariaDB and application-specific adapters.

## Backup lifecycle

A normal module operation should follow a predictable lifecycle:

```text
DISCOVER
  -> PRECHECK
  -> QUIESCE (when required)
  -> SNAPSHOT/COPY
  -> SAVE IMAGES
  -> WRITE MANIFEST
  -> CHECKSUM
  -> RESUME
  -> VERIFY
```

If an operation fails after a service was stopped, cleanup logic must attempt to return that service to its previous running state.

## Restore lifecycle

Restore is intentionally more conservative:

```text
SELECT BACKUP
  -> VERIFY CHECKSUMS
  -> VALIDATE COMPATIBILITY
  -> SHOW IMPACT
  -> EXPLICIT CONFIRMATION
  -> SAFETY SNAPSHOT (where possible)
  -> STOP AFFECTED MODULE
  -> RESTORE DATA/IMAGES/CONFIG
  -> START MODULE
  -> HEALTH CHECK
  -> REPORT RESULT
```

Destructive restore actions must never run from a casual single click without a confirmation step.

## Backup metadata

Each backup should contain enough metadata to be understandable without the original host database. A manifest should include at minimum:

- backup format version
- creation timestamp
- module identifier and display name
- module type
- host identifier/name
- source paths and volumes
- container/image identifiers when applicable
- adapter used
- backup contents
- required SYSTEM dependencies
- integrity checksum list

The backup archive itself remains outside the source-code repository.

## UI contract

The backend should return a normalized module model that the base UI can render as cards.

Conceptual fields:

```json
{
  "id": "docker:my-compose-project",
  "name": "My Project",
  "type": "compose",
  "status": "running",
  "containers": 2,
  "last_backup": "2026-09-01T20:55:14+02:00",
  "last_backup_size": 224395264,
  "integrity": "verified",
  "capabilities": ["backup", "verify", "restore", "export"]
}
```

The future advanced/Pro UI should consume the same backend model and endpoints, adding detailed views rather than creating a separate backup engine.

## Security boundary

This is a public source repository. Source control must not contain real system snapshots, databases, tokens, authentication state, private keys or exported Docker images.

Runtime backups should be stored with restrictive filesystem permissions and should be considered sensitive because they may contain credentials even when the application source code does not.
