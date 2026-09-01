# Roadmap

This roadmap describes the intended evolution of Modular Backup Center. Priorities may change as restore testing exposes real-world requirements.

## Phase 1 — Foundation

- Define repository structure and public/private data boundaries.
- Implement host SYSTEM module.
- Implement Docker/Compose discovery.
- Group Compose containers into one logical recovery module.
- Display module state, last backup, size and integrity status.
- Provide card-based Cockpit dashboard.
- Add Backup and Verify actions.
- Add clear progress and logs for long-running operations.

## Phase 2 — Recovery

- Add Restore action per module.
- Require explicit confirmation before destructive restore operations.
- Validate checksums before restore.
- Support exact Docker image loading for offline recovery.
- Restore named volumes and bind-mounted application state.
- Restore Compose deployment metadata.
- Add module-specific restore adapters.
- Build isolated restore-test mode so recovery can be validated without touching production data.
- Document bare-metal SYSTEM recovery from a live/rescue environment.

## Phase 3 — Export / Import

- Export backups without deleting the local copy.
- Support mounted USB storage.
- Support mounted NAS/network destinations.
- Support browser download where practical.
- Add Import flow for previously exported module backups.
- Detect and validate imported backup format/version.

## Phase 4 — Automation

- Per-module scheduled backups.
- Retention policies.
- Automatic integrity verification.
- Storage-space warnings.
- Backup failure notifications.
- Optional pre/post hooks and application quiesce logic.

## Phase 5 — Extensible module system

- Generic Docker backup adapter.
- SQLite-aware adapter.
- PostgreSQL-aware adapter.
- MySQL/MariaDB-aware adapter.
- Application-specific community adapters.
- Simple adapter manifest/API so new modules do not require UI changes.

## Future Pro UI

The initial product intentionally uses compact, easy-to-read cards. A future Pro/advanced interface can use the same backup engine while exposing considerably more information through module tabs and detailed views.

Potential Pro features:

- Tabbed module interface.
- Full backup history and timeline.
- Detailed container/image/volume/bind-mount inventory.
- Scheduling editor.
- Retention policy editor.
- Storage analytics and growth trends.
- Detailed logs and audit history.
- Multiple backup destinations and destination policies.
- Per-module health checks.
- Backup comparison and change summaries.
- Notifications and alert integrations.
- Advanced restore options and staged recovery workflows.

The base and advanced interfaces should share the same engine and backup format. The advanced UI must not require a separate backup implementation.
