# Sonatype Nexus IQ - Export Tool

## Basis of the connection

The Nexus IQ API is a straightforward REST API returning JSON. For that `curl` + `jq` is the standard
Bash combo for this - `jq` is the de-facto JSON processor in shell scripts and is widely
available.

---

## Scoping - Export only!

This tool covers read/export operations only:

- ✅ Fetch and export organizations (full hierarchy)
- ✅ Fetch and export applications (with org ancestry)
- ✅ Tree `.txt` and flat `.csv` output
- ❌ Write operations (create / update / delete)
- ❌ Policy violations / scan reports
- ❌ Firewall / repository manager data
- ❌ Waivers, licenses, vulnerability details


---

## How Nexus IQ structure works 

| Nexus IQ                                     | API endpoint                      |
|----------------------------------------------|-----------------------------------|
| Organizations (hierarchical)                 | `GET /api/v2/organizations`       |
| Applications                                 | `GET /api/v2/applications`        |
| Application-Id                               | Application `publicId` / tags     |

Organization objects carry a `parentOrganizationId` field, so the tree can be reconstructed
client-side.

### Tree setup

```
Root Org
  └── Area
        └── Department
              └── Team
                    └── Sub-Team          ← depth 5
                          └── Pod         ← depth 6
                                └── App   ← depth7
```

The CSV will capture all of it: 
1) `Organization`
2) `Area`
3) `Department`
4) `Team` get the first
5) Remaining ancestors, and everything deeper collapses into `PathAfterTeam` (e.g. `/sub-team/pod/`)

---

## Files to create

- nexus_iq_client.sh 
   - shared config loader + curl wrapper
- nexus_iq_export.sh
   - main export script 
- nexus-iq.cfg.example 
   - config template

---

## `nexus-iq.cfg.example`

Stores the server URL and credentials - never committed with real values:

```ini
NEXUS_IQ_URL=https://your-nexusiq-host.example.com
NEXUS_IQ_USER=admin
NEXUS_IQ_TOKEN=your-token-here
```

Cloud tenant example (adds `/platform` prefix automatically):
```ini
NEXUS_IQ_URL=https://your-tenant.sonatype.app
NEXUS_IQ_USER=admin
NEXUS_IQ_TOKEN=your-token-here
```

---

## `nexus_iq_client.sh` - shared functions

- Sources config from `nexus-iq.cfg` (local, next to the script) or `~/.nexus-iq.cfg`
- Detects Sonatype Cloud URL (`*.sonatype.app`) and prepends `/platform` to all API paths
- Provides a `iq_get <path>` function that wraps `curl` with:
  - Basic auth (`-u user:token`)
  - JSON `Accept` header
  - HTTP error detection (non-2xx exits with message)
  - Connectivity check via `GET /ping` on load

---

## `nexus_iq_export.sh` - what it does

### Steps

1. **Source `nexus_iq_client.sh`** - loads config and shared `iq_get` helper
2. **Confirm with user** - prints instance URL and waits for Enter
3. **Fetch all organizations** (`GET /api/v2/organizations`)
   - Builds lookup: `orgId -> name, parentOrganizationId`
   - Builds `children_map`: `parentId -> [childId, ...]`
   - Identifies root orgs (no `parentOrganizationId`)
4. **Fetch all applications** (`GET /api/v2/applications`)
   - Maps each application to its `organizationId`
5. **Compute statistics**
   - Count orgs by depth (Orgs/Areas/Departments)
   - Count total applications
6. **Generate `.txt` tree export** - unicode tree for visual comparison:
   ```
   ───Root Org Name
       ├──(org) Sub-Org A
       │   ├──(org) Team X
       │   │   └──Apps:
       │   │       my-application [my-app-public-id]
       └──(org) Sub-Org B
   ```
7. **Generate `.csv` export** - one row per application:

   | Column              | Source                                           |
   |---------------------|--------------------------------------------------|
   | `Organization`      | Depth-1 ancestor name                            |
   | `Area`              | Depth-2 ancestor name                            |
   | `Department`        | Depth-3 ancestor name                            |
   | `Team`              | Depth-4 ancestor name                            |
   | `PathAfterTeam`     | `/`-joined org names for depth 5+ + app name     |
   | `ApplicationName`   | `name` field from API                            |
   | `ApplicationPublicId` | `publicId` field from API                      |

8. **Print summary** - groups, applications, CSV row count

### Output files

Timestamped in the current working directory:
```
export_nexusiq_YYYYMMDD_HHMMSS.txt
export_nexusiq_YYYYMMDD_HHMMSS.csv
```

---

## Prerequisites

| Tool   | Purpose                        | Check command   |
|--------|--------------------------------|-----------------|
| `curl` | HTTP requests to the API       | `which curl`    |
| `jq`   | JSON parsing and transformation | `which jq`     |

The script will check both at startup and exit with a clear message if either is missing.
