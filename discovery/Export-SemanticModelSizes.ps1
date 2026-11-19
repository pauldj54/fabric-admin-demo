#Requires -Version 7.0
<#
.SYNOPSIS
Exports one CSV row per semantic model in the workspace list.
.DESCRIPTION
Run in PowerShell 7 (pwsh) on Windows with MicrosoftPowerBIMgmt and SqlServer 22+
installed. Keep Invoke-DiscoveryRequest.ps1 next to this script. Sign in with
a Fabric admin account. Run PowerBI_Discovery_P_SKU.ps1 first to create
XXXXWorkspacesT1.csv next to this script. Only workspaces in that CSV are
queried. Sizing uses read-only XMLA queries
and additionally requires an XMLA-enabled workspace and model Write permission.

EstimatedVertiPaqBytes is dictionary plus segment size for Import-only models,
not offline file size or peak memory. Other models remain in the CSV without a
size. Run large inventories off-peak because XMLA can cause models to load.
.PARAMETER WorkspaceId
Optional workspace GUID from XXXXWorkspacesT1.csv for a pilot run.
.PARAMETER OutputPath
CSV path. Defaults to PowerBI-Discovery-SemanticModelSizes.csv next to this script.
.PARAMETER Delimiter
CSV separator. Defaults to semicolon for Excel; use -Delimiter ',' for comma CSV.
.EXAMPLE
.\PowerBI_Discovery_P_SKU.ps1 -IncludeSharedCapacity
.\Export-SemanticModelSizes.ps1
.EXAMPLE
.\Export-SemanticModelSizes.ps1 -WorkspaceId '<workspace GUID>'
#>
[CmdletBinding()]
param(
    [guid] $WorkspaceId,
    [string] $OutputPath = (Join-Path $PSScriptRoot 'PowerBI-Discovery-SemanticModelSizes.csv'),
    [char] $Delimiter = ';'
)

$workspaceListPath = Join-Path $PSScriptRoot 'XXXXWorkspacesT1.csv'
if (-not (Test-Path -LiteralPath $workspaceListPath -PathType Leaf)) {
    throw "Workspace list not found at '$workspaceListPath'. Run PowerBI_Discovery_P_SKU.ps1 first."
}
$workspaceIds = @(foreach ($entry in (Import-Csv -LiteralPath $workspaceListPath -ErrorAction Stop)) {
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse($entry.WorkspaceId, [ref]$parsedId) -or $parsedId -eq [guid]::Empty) {
        throw "Expected a valid GUID in the WorkspaceId column of '$workspaceListPath'."
    }
    $parsedId
})
$workspaceIds = @($workspaceIds | Select-Object -Unique)
if ($workspaceIds.Count -eq 0) {
    throw "No workspace IDs found in '$workspaceListPath'. Run PowerBI_Discovery_P_SKU.ps1 first."
}
if ($PSBoundParameters.ContainsKey('WorkspaceId')) {
    if ($WorkspaceId -notin $workspaceIds) { throw "Workspace $WorkspaceId is not listed in '$workspaceListPath'." }
    $workspaceIds = @($WorkspaceId)
}

. "$PSScriptRoot\Invoke-DiscoveryRequest.ps1"
Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop
Import-Module SqlServer -MinimumVersion 22.0 -ErrorAction Stop

function Invoke-ModelQuery {
    param([string] $Server, [string] $Catalog, [string] $Query)

    $connection = [System.Data.Common.DbConnectionStringBuilder]::new()
    $connection['Data Source'] = $Server
    $connection['Initial Catalog'] = $Catalog
    # Invoke-ASCmd has no AccessToken parameter. MSOLAP accepts a bearer token
    # without the scheme in Password when User ID is omitted.
    $token = (Get-PowerBIAccessToken -AsString -ErrorAction Stop) -replace '^Bearer\s+', ''
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'No Power BI access token was returned.' }
    $connection['Password'] = $token

    try {
        [xml] $result = Invoke-ASCmd -ConnectionString $connection.ConnectionString `
            -Query $Query -QueryTimeout 120 -ConnectionTimeout 30 -ErrorAction Stop
        $errorNode = $result.SelectSingleNode("//*[local-name()='Error']")
        if ($errorNode) { throw $errorNode.GetAttribute('Description') }
        foreach ($row in $result.SelectNodes("//*[local-name()='row']")) {
            $cell = $row.SelectSingleNode('./*')
            if ($cell) { $cell.InnerText }
        }
    } catch {
        throw $_.Exception.Message.Replace($token, '[redacted]')
    }
}

$modeQuery = @'
EVALUATE
VAR DefaultMode = MAXX ( INFO.MODEL(), [DefaultMode] )
RETURN
    DISTINCT (
        SELECTCOLUMNS (
            INFO.PARTITIONS(),
            "PartitionMode", IF ( [Mode] == 2, DefaultMode, [Mode] )
        )
    )
'@
$sizeQuery = @'
EVALUATE
ROW (
    "EstimatedBytes",
    SUMX ( INFO.STORAGETABLECOLUMNS(), [DICTIONARY_SIZE] )
        + SUMX ( INFO.STORAGETABLECOLUMNSEGMENTS(), [USED_SIZE] )
)
'@
$modeNames = @{ '0' = 'Import'; '1' = 'DirectQuery'; '2' = 'Default'; '3' = 'Push'; '4' = 'Dual'; '5' = 'DirectLake' }

$null = Connect-PowerBIServiceAccount -ErrorAction Stop
$workspaces = @(foreach ($id in $workspaceIds) {
    $workspace = Invoke-DiscoveryRequest -Description "Listing semantic models in workspace $id" -Operation {
        Get-PowerBIWorkspace -Scope Organization -Id $id -Include Datasets -ErrorAction Stop
    } | Where-Object { $_.Id -eq $id -and $_.Type -eq 'Workspace' -and $_.State -eq 'Active' }
    if (-not $workspace) { throw "Active non-personal workspace $id was not found. Regenerate the workspace list." }
    $workspace
})

$rows = foreach ($workspace in $workspaces) {
    $workspaceName = $workspace.Name
    if (@($workspaces | Where-Object Name -eq $workspaceName).Count -gt 1) {
        $workspaceName = "$workspaceName - $($workspace.Id)"
    }
    $server = "powerbi://api.powerbi.com/v1.0/myorg/$([uri]::EscapeDataString($workspaceName))"
    foreach ($dataset in $workspace.Datasets) {
        Write-Host "Sizing '$($dataset.Name)' in '$($workspace.Name)'..."
        $catalog = $dataset.Name
        if (@($workspace.Datasets | Where-Object Name -eq $catalog).Count -gt 1) {
            $catalog = "$catalog - $($dataset.Id)"
        }
        $row = [ordered]@{
            WorkspaceId             = $workspace.Id
            WorkspaceName           = $workspace.Name
            SemanticModelId         = $dataset.Id
            SemanticModelName       = $dataset.Name
            PartitionModes          = $null
            EstimatedVertiPaqBytes  = $null
            SizeStatus              = $null
        }
        try {
            $modes = @(Invoke-ModelQuery -Server $server -Catalog $catalog -Query $modeQuery | ForEach-Object {
                if ($modeNames.ContainsKey($_)) { $modeNames[$_] } else { 'Unknown' }
            } | Sort-Object -Unique)
            $row.PartitionModes = $modes -join '; '
            if ($modes.Count -eq 1 -and $modes[0] -eq 'Import') {
                $value = Invoke-ModelQuery -Server $server -Catalog $catalog -Query $sizeQuery
                $bytes = 0L
                if ([long]::TryParse([string]$value, [ref]$bytes) -and $bytes -gt 0) {
                    $row.EstimatedVertiPaqBytes = $bytes
                    $row.SizeStatus = 'Estimated'
                } else {
                    $row.SizeStatus = 'No size returned'
                }
            } else {
                $row.SizeStatus = 'Not measured'
            }
        } catch {
            $row.SizeStatus = 'Unavailable'
            Write-Warning "Could not size model $($dataset.Id) in workspace $($workspace.Id): $($_.Exception.Message)"
        }
        [pscustomobject] $row
    }
}

$columns = 'WorkspaceId', 'WorkspaceName', 'SemanticModelId', 'SemanticModelName',
    'PartitionModes', 'EstimatedVertiPaqBytes', 'SizeStatus'
if ($null -eq $rows) {
    ($columns -join $Delimiter) | Set-Content -LiteralPath $OutputPath -Encoding utf8BOM -ErrorAction Stop
} else {
    $rows | Select-Object -Property $columns |
        Export-Csv -LiteralPath $OutputPath -Delimiter $Delimiter -NoTypeInformation -Encoding utf8BOM -ErrorAction Stop
}
Write-Host "Wrote $(@($rows | Where-Object { $null -ne $_ }).Count) semantic models to $OutputPath"
$measuredCount = @($rows | Where-Object SizeStatus -eq 'Estimated').Count
Write-Host "Sizes measured: $measuredCount. Blank sizes are unknown or not measured, not zero."
