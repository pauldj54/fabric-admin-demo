#Requires -Version 7.5

$inputPath = Join-Path $PSScriptRoot 'PowerBI-Discovery-Report-Active-XXXX-T1.csv'
$outputPath = Join-Path $PSScriptRoot 'PowerBI-Discovery-DatasetDetails.csv'

$rows = foreach ($workspace in (Import-Csv -LiteralPath $inputPath -ErrorAction Stop)) {
    if ([string]::IsNullOrWhiteSpace($workspace.DatasetsDetails)) { continue }

    $datasets = ConvertFrom-Json -InputObject $workspace.DatasetsDetails -DateKind String -ErrorAction Stop
    foreach ($dataset in $datasets) {
        $row = [ordered]@{
            WorkspaceId = $workspace.WorkspaceId
            WorkspaceName = $workspace.WorkspaceName
        }
        foreach ($property in $dataset.PSObject.Properties) {
            $value = $property.Value
            if ($value -is [array] -or $value -is [pscustomobject]) {
                $value = ConvertTo-Json -InputObject $value -Depth 100 -Compress -ErrorAction Stop
            }
            $row.Add($property.Name, $value)
        }
        [pscustomobject]$row
    }
}

if ($null -eq $rows) {
    'WorkspaceId,WorkspaceName' | Set-Content -LiteralPath $outputPath -Encoding utf8 -ErrorAction Stop
} else {
    # Export-Csv would otherwise use only the first dataset's fields as columns.
    $columns = $rows | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique
    $rows | Select-Object -Property $columns |
        Export-Csv -LiteralPath $outputPath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
}
