# backuprefresh

Ansible playbooks that make a newly created VMware VM show up in **Rubrik Security Cloud (RSC)** right away and get its **first backup immediately**, instead of waiting for RSC's normal vCenter discovery cycle and the SLA schedule.

This was built and tested in a non-production lab. The lab has since been torn down, so names such as `vcenter1.rubrik.lab`, `LAB_TYPE_VM` and `Prod` are examples. Change them to fit your environment.

For the full walkthrough, see the [Playbook Guide (PDF)](docs/RSC_Refresh_and_Backup_Playbook_Guide.pdf).

## The problem

After you create a VM in vCenter:

1. RSC can take **up to about 2 hours** to discover it, because the vCenter inventory refreshes on its own schedule.
2. Once the VM is discovered, tag-based SLA assignment (for example, vSphere tag `LAB_TYPE_VM > Prod`) gives it an SLA. However, the **first backup waits for the SLA's schedule or backup window**. With an hourly SLA that can be close to an hour.

When a provisioning pipeline needs a new VM protected *now*, both waits are too long.

## What the playbook does

`rsc_refresh_vcenter.yml` handles both waits:

| # | Step | Why |
|---|------|-----|
| 1 | Sign in with an RSC service account (`/api/client_token`) | API access; the token is never logged (`no_log`) |
| 2 | List vCenters and pick them by `vcenter_name_regex` | Refresh only the vCenter(s) you need |
| 3 | **Force a vCenter refresh** (`refreshVsphereVcenter`) | Makes RSC pick up the new VM now instead of in about 2 hours |
| 4 | Wait for `lastRefreshTime` to change (`wait_for_refresh=true`) | Confirms the refresh actually finished |
| 5 | **Wait for each VM in `vm_names`** to appear, tagged, *with an SLA* | RSC lags after the refresh in listing the VM, attaching tags and deriving the SLA (see below) |
| 6 | Find VMs with the Prod tag and split them into *needs backup* / *already backed up* / *no real SLA* | Only VMs that have never been backed up get an on-demand backup |
| 7 | **Take an on-demand backup with the VM's own SLA** (`vsphereOnDemandSnapshot`) | The first backup starts now, and its retention follows the SLA |
| 8 | Poll each backup job until SUCCEEDED / FAILED / CANCELED | So the caller knows the result |
| 9 | Print a `BACKUP RESULT` line, optionally post to a webhook, and set the exit code | Notifies the person or pipeline that ran it |
| 10 | Sign out (`DELETE /api/session`) in an `always:` block | Runs even if an earlier step failed |

### Why the playbook waits after the refresh

In the lab, the first version checked for the new VM immediately after the refresh finished. The VM (`SQLREFRESH`) **was not listed yet**. A moment later it appeared with no SLA, and only after that did the tag-derived SLA attach. RSC finishes the refresh first and then processes the new VM in stages:

```
refresh finished  ->  VM listed  ->  vSphere tags attached  ->  effective SLA derived
```

So with `vm_names` set, the playbook polls each named VM (by default every 20 s for up to 10 min) until it is **found, tagged, and has a real SLA**. Only then does it take the backup. A VM that never gets there is reported as `NOT FOUND in RSC`, `NOT TAGGED`, or `HAS NO SLA`.

In the end-to-end lab test (`YAMLREFRESHBAK`), it took **about 1 min 15 s** from the start of the run to a completed on-demand backup.

## Requirements

- `ansible-core` 2.14 or later. The playbooks use only `ansible.builtin` modules (`uri`, `set_fact`, `debug`, `fail`), so no collections are needed.
- An RSC **service account** (Settings > Users and Access > Service Accounts) whose role can refresh vSphere vCenters, read VMs, and take on-demand snapshots.
- Network access from the Ansible control node to `https://<tenant>.my.rubrik.com`.

## Setup

```bash
git clone https://github.com/agentic-brian/backuprefresh.git
cd backuprefresh
cp group_vars/all/vault.example.yml group_vars/all/vault.yml
# edit vault.yml: rsc_url, rsc_client_id, rsc_client_secret
ansible-vault encrypt group_vars/all/vault.yml
```

`group_vars/all/vault.yml` is in `.gitignore`, so your real credentials are never committed.

## Usage

```bash
# New VM: refresh, wait for it, back it up, report
ansible-playbook rsc_refresh_vcenter.yml --ask-vault-pass -e wait_for_refresh=true -e vm_names=MYNEWVM

# Several new VMs (no spaces in the comma list, or pass JSON)
ansible-playbook rsc_refresh_vcenter.yml --ask-vault-pass -e wait_for_refresh=true -e vm_names=VM1,VM2
ansible-playbook rsc_refresh_vcenter.yml --ask-vault-pass -e wait_for_refresh=true -e '{"vm_names":["VM1","VM2"]}'

# List vCenters and tagged VMs only; change nothing
ansible-playbook rsc_refresh_vcenter.yml --ask-vault-pass -e list_only=true

# Refresh only (no backups)
ansible-playbook rsc_refresh_vcenter.yml --ask-vault-pass -e prod_backup_enabled=false

# Also post the result to a Teams/Slack incoming webhook
ansible-playbook rsc_refresh_vcenter.yml --ask-vault-pass -e vm_names=MYNEWVM -e notify_webhook_url=https://...
```

> With `-e`, `vm_names=a, b` (with a space) breaks the key=value parsing. Use `a,b` or JSON.

To call it from a provisioning playbook, run it after the VM is created and tagged. You can also put it in an AWX/Tower workflow node, with the vault credential attached.

## Settings

| Variable | Default | Meaning |
|----------|---------|---------|
| `vcenter_name_regex` | `.*` | Which vCenters to refresh (regex on the name) |
| `list_only` | `false` | Only list; don't refresh or back up |
| `wait_for_refresh` | `false` | Poll until `lastRefreshTime` changes. **Use `true` for new VMs** |
| `wait_retries` / `wait_delay` | `45` / `20` | Refresh wait: 15 min |
| `prod_backup_enabled` | `true` | Take on-demand backups of tagged VMs that have never been backed up |
| `prod_tag_category` / `prod_tag_name` | `LAB_TYPE_VM` / `Prod` | The vSphere tag path that marks VMs to protect |
| `vm_names` | `[]` | New VM name(s) to wait for and back up. A list or a comma-separated string |
| `vm_ready_retries` / `vm_ready_delay` | `30` / `20` | VM readiness wait: 10 min |
| `wait_for_backup` | `true` | Wait for the backup jobs to finish |
| `backup_wait_retries` / `backup_wait_delay` | `120` / `30` | Backup wait: 60 min |
| `notify_webhook_url` | `""` | Optional incoming webhook; receives `{"text": "..."}` |

## Results and exit code

Each VM gets a `BACKUP RESULT` line, for example:

| Result | Meaning |
|--------|---------|
| `backup COMPLETED at <time>` | The on-demand backup succeeded |
| `already protected - SLA snapshot taken at <time>` | The VM already had a snapshot, so no on-demand backup was needed |
| `FAILED - <error>` / `CANCELED` | The backup job ended badly |
| `NOT FINISHED (still RUNNING after waiting Ns - check RSC)` | The wait timed out. The job may still finish |
| `NOT FOUND in RSC` / `NOT TAGGED` / `HAS NO SLA` | The named VM never became ready |

If **any** named VM is not OK, the play fails with a **non-zero exit code**, so a calling pipeline or AWX job shows the failure.

## Burst refresh testing and protections

**Concern:** in production, many VMs created at the same time could each trigger a vCenter refresh and overload vCenter or Rubrik.

**Test:** `rsc_refresh_burst_test.yml` fires `burst_count` (default 5) `refreshVsphereVcenter` requests in parallel, records each response, then waits for the refresh to finish.

**Lab result:**

| Requests sent | Accepted | Rejected | Refreshes that actually ran |
|---|---|---|---|
| 5 | 1 | 4 | 1 |

Rejected requests come back as a generic GraphQL error, *"An unexpected internal error occurred."* Rubrik allows **one on-demand refresh per vCenter at a time**, so a burst does not turn into a burst of vCenter inventory scans. In the lab, a refresh of a vCenter with 19 VMs took about 14 s.

**What the test exposed:** before the fix, a second overlapping playbook run failed at the refresh step because of that rejection. The playbook now **treats a rejected refresh as "a refresh is already queued or running"**. It reports that, keeps going, and still waits for `lastRefreshTime` and for its own VM. Overlapping runs for different VMs both succeed.

**Protections, in layers:**

| Layer | Protection | Status |
|---|---|---|
| Rubrik cluster | One on-demand refresh per vCenter at a time; extra requests rejected | Built in (confirmed in the lab) |
| Playbook | A rejected refresh is treated as already in progress, not as a failure | In place |
| Playbook | Waits for its own VM, not just for its own refresh | In place |
| Playbook | Only VMs with no snapshot get an on-demand backup; already-protected VMs are skipped | In place |
| AWX/Tower | Turn off "Allow simultaneous jobs" on the job template to queue runs | Recommended |
| Pipeline | Batch: create several VMs, then run once with `vm_names=VM1,VM2,...` | Recommended |
| Playbook | Skip the refresh if `lastRefreshTime` is very recent; query only the named VMs | Possible enhancement |

**Single-VM refresh:** the CDM cluster has an internal API (`POST /api/internal/vmware/vcenter/{id}/refresh_vm` with a VM MOID) that refreshes one VM. It is **internal and unsupported**, and it goes to the cluster directly rather than through RSC, so it is not used here.

## Files

| File | Purpose |
|------|---------|
| `rsc_refresh_vcenter.yml` | Main playbook: refresh, wait, back up, report |
| `rsc_refresh_burst_test.yml` | Lab test: parallel refresh requests |
| `Refresh-RscVcenter.ps1` | Original PowerShell refresh-only script (service-account JSON, `-ListOnly`, `-Wait`, `-WhatIf`) |
| `group_vars/all/vault.example.yml` | Template for the encrypted credentials file |
| `docs/RSC_Refresh_and_Backup_Playbook_Guide.pdf` | Detailed guide |

### PowerShell script

```powershell
.\Refresh-RscVcenter.ps1 -ServiceAccountJson .\sa.json -ListOnly
.\Refresh-RscVcenter.ps1 -ServiceAccountJson .\sa.json -VCenterName "vcsa01*" -Wait
```

`sa.json` is the service account file downloaded from RSC. Keep it out of git; `*.json` is in `.gitignore`.

## Known limits

- **It is unconfirmed whether RSC's refresh is "full" or "lite".** The API exposes one refresh mutation, and in the lab it picked up new VMs and their tags.
- The VM list query fetches up to 1000 VMs. The playbook warns if there are more.
- RSC API rate limits were not measured.
- Verified against the RSC GraphQL API as of November 2026. Field names may change in later releases.
