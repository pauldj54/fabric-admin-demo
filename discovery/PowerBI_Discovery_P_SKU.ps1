<#
.SYNOPSIS
Discovers active Power BI workspaces and exports workspace details.
.DESCRIPTION
Writes XXXXWorkspacesT1.csv next to this script for Export-SemanticModelSizes.ps1.
.PARAMETER IncludeSharedCapacity
Includes active non-personal workspaces on both shared and dedicated capacity.
Without this switch, discovery is limited to active dedicated-capacity workspaces.
.EXAMPLE
.\PowerBI_Discovery_P_SKU.ps1 -IncludeSharedCapacity
#>
param(
    [switch] $IncludeSharedCapacity
)

# Install required modules if not already installed and verify permissions
# Install-Module -Name MicrosoftPowerBIMgmt

. "$PSScriptRoot\Invoke-DiscoveryRequest.ps1"

# Connect to Power BI service using admin credentials
Connect-PowerBIServiceAccount

# Define the output CSV file path and output object
$csvFilePath = ".\PowerBI-Discovery-Report-Active.csv"
$workspaceDetails = New-Object System.Collections.Generic.List[object]

# Get active workspaces for the selected capacity scope.
try {
    $workspaceFilter = "tolower(state) eq 'active'"
    if (-not $IncludeSharedCapacity) {
        $workspaceFilter = "isOnDedicatedCapacity eq true and $workspaceFilter"
    }

    $workspaces = @(Invoke-DiscoveryRequest -Description 'Listing workspaces' -Operation {
        Get-PowerBIWorkspace -Scope Organization -All -Filter $workspaceFilter -ErrorAction Stop
    })
    if ($IncludeSharedCapacity) {
        $workspaces = @($workspaces | Where-Object { $_.Type -eq 'Workspace' })
    }
    Write-Host "Workspaces count: $($workspaces.count)"
} catch {
    Write-Host "Error getting workspaces: $_"
    return
}

$workspaceListPath = Join-Path $PSScriptRoot 'XXXXWorkspacesT1.csv'
Set-Content -LiteralPath $workspaceListPath -Value @('WorkspaceId'; $workspaces.Id) -ErrorAction Stop
Write-Host "Workspace IDs exported to $workspaceListPath"

# Get access token for Fabric items API
try {
    $connection = Get-PowerBIAccessToken -ErrorAction Stop
    $token = $connection.values
    # Write-Host "Access token: $token"
} catch {
    Write-Host "Error getting access token: $_"
    return
}


# get workspace details
foreach ($workspace in $workspaces){
    try {
        Write-Host "Fetching details for workspace $($workspace.ID) $($workspace.Name)"
        # Get dashboard, reports, dataflows and datasets for the current workspace
        $dasboards = @(Invoke-DiscoveryRequest -Description "Dashboards in $($workspace.ID)" -Operation {
            Get-PowerBIDashboard -WorkspaceId $workspace.ID -ErrorAction Stop
        })
        $reports = @(Invoke-DiscoveryRequest -Description "Reports in $($workspace.ID)" -Operation {
            Get-PowerBIReport -WorkspaceId $workspace.ID -ErrorAction Stop
        })
        $datasets = @(Invoke-DiscoveryRequest -Description "Datasets in $($workspace.ID)" -Operation {
            Get-PowerBIDataset -WorkspaceId $workspace.ID -ErrorAction Stop
        })
        $dataflows = @(Invoke-DiscoveryRequest -Description "Dataflows in $($workspace.ID)" -Operation {
            Get-PowerBIDataflow -WorkspaceId $workspace.ID -ErrorAction Stop
        })
        # $migrationStatus = Get-PowerBIWorkspaceMigrationStatus -Id $workspace.ID

        # Define a threshold for large semantic models (e.g., 1 GB)
        $large_model_threshold_bytes = 1 * 1024 * 1024 * 1024  # 1 GB

        # Initialize a counter for large semantic models
        $large_model_count = 0

        # Check each dataset for size
        foreach ($dataset in $datasets) {
            if ($dataset.SizeInBytes -ge $large_model_threshold_bytes) {
                $large_model_count++
            }
        }

        # Get the owners of the workspace
        $owners = $workspace.Users | Where-Object { $_.AccessRight -eq 'Admin' } | ForEach-Object { $_.UserPrincipalName }

        # Fabric items rest API call
        $fabricItemsCount = 0
        
        # List of Fabric items - check and update from: https://learn.microsoft.com/en-us/rest/api/fabric/admin/items/list-items?tabs=HTTP#itemtype
        # $fabricItemsTypes = @('Lakehouse', 'Warehouse', 'KQLDatabase', 'Notebook', 'DataPipeline', 'Eventstream','KQLQueryset', 'KQLDataConnection', 'MLExperiment', 'MLModel', 'MirroredWarehouse', 'SQLEndpoint', 'SparkJobDefinition')
        $fabricItemsTypes = @('Lakehouse', 'Warehouse', 'KQLDatabase', 'Notebook', 'DataPipeline', 'Eventstream','KQLQueryset', 'KQLDataConnection', 'MLExperiment', 'MLModel', 'MirroredWarehouse', 'SQLEndpoint', 'SparkJobDefinition', 'Environment', 'Eventhouse', 'GraphQLApi', 'KQLDashboard', 'MirroredDatabase', 'Reflex')
        try {
            $endpoint = "https://api.fabric.microsoft.com/v1/admin/items?workspaceId=$($workspace.ID)"
            $headers = @{"Authorization" = "$token"}
            $response = Invoke-DiscoveryRequest -Description "Fabric items in $($workspace.ID)" -Operation {
                Invoke-RestMethod -Uri $endpoint -Headers $headers -Method Get -ErrorAction Stop
            }
            # Write-Host "Response: $response"

            foreach ($item in $response){
                foreach ($entity in $item.itemEntities){
                    $itemType = $entity.type
                    if ($fabricItemsTypes -contains $itemType){
                        $fabricItemsCount++
                    }
                }
            }
        } catch {
            $fabricItemsCount = $null
            Write-Host "Error verifying Fabric Items for workspace $($workspace.ID): $_"
        }


        # create custom object
        $item = [PSCustomObject] @{
            WorkspaceId = $workspace.ID
            WorkspaceName = $workspace.Name
            Type = $workspace.Type
            State = $workspace.State
            IsReadOnly = $workspace.IsReadOnly
            IsOrphaned = $workspace.IsOrphaned
            IsOnDedicatedCapacity = $workspace.IsOnDedicatedCapacity
            CapacityId = $workspace.CapacityId
            Owners = $owners -join ","
            DashboardsCount = $dasboards.Count
            ReportsCount = $reports.Count
            DatasetsCount = $datasets.Count
            LargeModelCount = $large_model_count
            DataflowsCount = $dataflows.Count
            FabricItemsCount = $fabricItemsCount
            # MigrationStatus = $migrationStatus.Status
            }
          

         $workspaceDetails.Add($item)
        } catch {
            Write-Host "Error processing workspace $($workspace.ID): $_"
        }

}


# Export the data to CSV
try {
    $workspaceDetails | Export-Csv -Path $csvFilePath -NoTypeInformation
    Write-Host "Workspace details exported to $csvFilePath"
} catch {
    Write-Host "Error exporting to CSV: $_"
}
