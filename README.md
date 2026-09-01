# Modular Backup Center

**Automatic modular backup & recovery dashboard for Linux and Docker.**

Modular Backup Center (MBC) is a Cockpit-oriented backup and recovery project designed around a simple idea: treat the operating system and each Docker workload as independent recovery modules.

Instead of one opaque full-disk backup, MBC aims to provide a clear dashboard where the host system is always present and Docker workloads are discovered automatically.

## Core goals

- One fixed **SYSTEM** recovery module for the Linux host.
- Automatic discovery of Docker containers and Compose projects.
- Automatic grouping of containers that belong to the same Compose stack.
- A simple card-based dashboard for everyday use.
- Per-module actions for **Backup**, **Verify**, **Restore** and **Export**.
- Visible last-backup date, time, size and integrity status directly on each card.
- Offline-friendly recovery by preserving exact Docker images when required.
- Support for module-specific backup logic when generic Docker backup is not enough.
- Safe handling of databases, volumes, bind mounts, permissions and application state.
- No secrets, credentials, user data or real backup archives stored in this repository.

## Interface concept

The default interface is intentionally simple:

```text
[ SYSTEM ]
Last backup: 2026-09-01 19:15
2.2 GB · Verified
Backup | Verify | Restore | Export

[ IA-Agent ]   [ OpenClaw ]   [ Portainer ]   [ ...auto-discovered modules ]
Running        Running         Running
Last: 20:55    Last: 20:37     Last: 20:41
214 MB         570 MB          43 MB
Backup         Backup          Backup
Verify         Verify          Verify
Restore        Restore         Restore
Export         Export          Export
```

Docker workloads are discovered dynamically. A Compose project with several containers should normally appear as one recovery module rather than one card per container.

## Backup model

MBC uses two layers:

1. **Generic discovery and backup engine**
   - container configuration
   - image metadata
   - exact Docker image export when enabled
   - named volumes
   - bind mounts
   - ports and restart policy
   - Compose project metadata

2. **Optional module adapters**
   - consistent SQLite backup
   - PostgreSQL/MySQL dumps
   - application-specific quiesce hooks
   - custom pre/post backup actions
   - application-specific restore validation

This keeps new Docker workloads usable immediately while still allowing reliable application-aware backups where needed.

## Safety model

The public repository contains code and documentation only.

The following must stay outside Git:

- backup archives
- Docker image tarballs
- databases and dumps
- `.env` files containing secrets
- API tokens
- private keys and certificates
- authentication profiles
- user files and application state

## Project status

Early development. The first implementation is being built and tested on a real Ubuntu Server + Docker + Cockpit environment.

See [ROADMAP.md](ROADMAP.md) for planned milestones and the future advanced UI.
