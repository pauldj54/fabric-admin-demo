$workspaceIds = Import-Csv -LiteralPath "$PSScriptRoot\PowerBI-Discovery-Report-Active.csv" -ErrorAction Stop |
    Select-Object -ExpandProperty WorkspaceId -ErrorAction Stop

@('WorkspaceId'; $workspaceIds) |
    Set-Content -LiteralPath "$PSScriptRoot\XXXXWorkspacesT1.csv" -ErrorAction Stop
