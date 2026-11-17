<#
.SYNOPSIS
    Refreshes vCenter inventory (metadata) in Rubrik Security Cloud (RSC).

.DESCRIPTION
    1. Authenticates to RSC with a service account (client_id / client_secret).
    2. Lists registered vCenters (vSphereVCenterConnection query).
    3. Starts a refresh job for each selected vCenter (refreshVsphereVcenter mutation).
    4. Optionally waits until each vCenter's lastRefreshTime moves forward.
    5. Signs the service-account session out.

    Create the service account in RSC: Settings > Users and Access > Service Accounts.
    Give it a role that can refresh vSphere objects, then download its JSON file.

.PARAMETER ServiceAccountJson
    Path to the service account JSON file downloaded from RSC
    (contains client_id, client_secret and access_token_uri).

.PARAMETER VCenterName
    One or more vCenter names to refresh. Wildcards allowed (e.g. "vc-lab*").
    If omitted, every registered vCenter is refreshed.

.PARAMETER Wait
    Wait for each refresh to finish (lastRefreshTime changes) before exiting.

.PARAMETER TimeoutMinutes
    How long -Wait keeps polling before giving up. Default 15.

.PARAMETER ListOnly
    Only list vCenters and their last refresh time; don't refresh anything.

.EXAMPLE
    .\Refresh-RscVcenter.ps1 -ServiceAccountJson .\lab-sa.json -ListOnly

.EXAMPLE
    .\Refresh-RscVcenter.ps1 -ServiceAccountJson .\lab-sa.json -VCenterName "vcsa01*" -Wait
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ServiceAccountJson,

    [string[]]$VCenterName,

    [switch]$Wait,

    [int]$TimeoutMinutes = 15,

    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Auth -------------------------------------------------------------------
$sa = Get-Content -Raw -Path $ServiceAccountJson | ConvertFrom-Json
if (-not $sa.client_id -or -not $sa.client_secret -or -not $sa.access_token_uri) {
    throw "Service account file must contain client_id, client_secret and access_token_uri."
}

$tokenUri = $sa.access_token_uri                       # https://<tenant>.my.rubrik.com/api/client_token
$baseUri  = $tokenUri -replace '/api/client_token/?$', ''
$gqlUri   = "$baseUri/api/graphql"

Write-Host "Connecting to $baseUri ..."
$tokenResp = Invoke-RestMethod -Method Post -Uri $tokenUri -ContentType 'application/json' -Body (@{
    client_id     = $sa.client_id
    client_secret = $sa.client_secret
} | ConvertTo-Json)
$headers = @{ Authorization = "Bearer $($tokenResp.access_token)" }

function Invoke-RscGql {
    param([string]$Query, [hashtable]$Variables = @{})
    $body = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 10
    $resp = Invoke-RestMethod -Method Post -Uri $gqlUri -Headers $headers -ContentType 'application/json' -Body $body
    if ($resp.errors) { throw "GraphQL error: $(($resp.errors | ForEach-Object message) -join '; ')" }
    $resp.data
}

function Get-RscVcenters {
    $q = @'
query ListVcenters($after: String) {
  vSphereVCenterConnection(first: 50, after: $after) {
    nodes { id name lastRefreshTime isStandaloneHost }
    pageInfo { hasNextPage endCursor }
  }
}
'@
    $all = @(); $after = $null
    do {
        $page = (Invoke-RscGql -Query $q -Variables @{ after = $after }).vSphereVCenterConnection
        $all += $page.nodes
        $after = $page.pageInfo.endCursor
    } while ($page.pageInfo.hasNextPage)
    $all
}

try {
    # --- Find vCenters ------------------------------------------------------
    $vcenters = Get-RscVcenters
    if ($VCenterName) {
        $vcenters = $vcenters | Where-Object { $n = $_.name; $VCenterName | Where-Object { $n -like $_ } }
    }
    if (-not $vcenters) { throw "No matching vCenters found." }

    $vcenters | Select-Object name, lastRefreshTime, isStandaloneHost, id | Format-Table -AutoSize

    if ($ListOnly) { return }

    # --- Refresh ------------------------------------------------------------
    $refresh = @'
mutation RefreshVcenter($input: RefreshVsphereVcenterInput!) {
  refreshVsphereVcenter(input: $input) { id status progress startTime error { message } }
}
'@
    $started = @()
    foreach ($vc in $vcenters) {
        if (-not $PSCmdlet.ShouldProcess($vc.name, 'Refresh vCenter inventory')) { continue }
        $job = (Invoke-RscGql -Query $refresh -Variables @{ input = @{ fid = $vc.id } }).refreshVsphereVcenter
        if ($job.error.message) {
            Write-Warning "$($vc.name): $($job.error.message)"
        } else {
            Write-Host "$($vc.name): refresh started (job $($job.id), status $($job.status))" -ForegroundColor Green
            $started += [pscustomobject]@{ Name = $vc.name; Id = $vc.id; Before = $vc.lastRefreshTime }
        }
    }

    # --- Wait (optional) ----------------------------------------------------
    if ($Wait -and $started) {
        Write-Host "Waiting up to $TimeoutMinutes min for refreshes to finish..."
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $pending = [System.Collections.ArrayList]@($started)
        while ($pending.Count -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 20
            $now = Get-RscVcenters
            foreach ($p in @($pending)) {
                $cur = $now | Where-Object id -eq $p.Id
                if ($cur -and $cur.lastRefreshTime -and $cur.lastRefreshTime -ne $p.Before) {
                    Write-Host "$($p.Name): refreshed at $($cur.lastRefreshTime)" -ForegroundColor Green
                    $pending.Remove($p)
                }
            }
        }
        foreach ($p in $pending) { Write-Warning "$($p.Name): still not refreshed after $TimeoutMinutes min." }
    }
}
finally {
    # --- Sign out the service-account session --------------------------------
    try { Invoke-RestMethod -Method Delete -Uri "$baseUri/api/session" -Headers $headers | Out-Null } catch { }
}
