<#
.SYNOPSIS
    Exports all Microsoft Entra ID Conditional Access policies to a timestamped JSON backup file.

.DESCRIPTION
    This script connects to Microsoft Graph using the Policy.Read.All and
    Policy.ReadWrite.ConditionalAccess scopes, retrieves all Conditional Access
    policies defined in the tenant, and exports them as a formatted JSON file.

    The output file is named with a UTC timestamp to support versioned, point-in-time
    backups. This script is intended to be used as a scheduled backup mechanism or
    as a secondary validation layer alongside Microsoft Entra's native Backup and
    Recovery feature.

    Use cases include:
      - Pre-change snapshots before modifying Conditional Access policies
      - Scheduled nightly backups stored in source control (e.g., Git)
      - Audit evidence for ISO 27001, SOC 2, or NIST CSF compliance reviews
      - Recovery baseline when manual policy reconstruction is required

    Requirements:
      - PowerShell 7.x or Windows PowerShell 5.1
      - Microsoft.Graph.Identity.SignIns module installed
      - Entra ID P2, E5, or Entra Suite license (for full CA policy access)
      - Sufficient permissions: Policy.Read.All (minimum); Policy.ReadWrite.ConditionalAccess if restores are planned

.NOTES
    Author:      Souhaiel Morhag
    Company:     MSEndpoint.com
    Blog:        https://msendpoint.com
    Academy:     https://app.msendpoint.com/academy
    LinkedIn:    https://linkedin.com/in/souhaiel-morhag
    GitHub:      https://github.com/Msendpoint
    License:     MIT

.EXAMPLE
    # Run interactively with default output directory (script root)
    .\Backup-EntraConditionalAccessPolicies.ps1

.EXAMPLE
    # Specify a custom output directory
    .\Backup-EntraConditionalAccessPolicies.ps1 -OutputPath 'C:\Backups\EntraCA'

.EXAMPLE
    # Run non-interactively using a Managed Identity or pre-authenticated session
    Connect-MgGraph -Identity
    .\Backup-EntraConditionalAccessPolicies.ps1 -OutputPath 'D:\CABackups' -SkipConnect
#>

[CmdletBinding()]
param (
    # Directory where the JSON backup file will be saved. Defaults to the script's own directory.
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = $PSScriptRoot,

    # Skip the Connect-MgGraph call if a session is already established (e.g., in automation pipelines).
    [Parameter(Mandatory = $false)]
    [switch]$SkipConnect
)

#region --- Prerequisites Check ---

# Ensure the required Graph module is available
if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Identity.SignIns')) {
    Write-Error "Required module 'Microsoft.Graph.Identity.SignIns' is not installed. Run: Install-Module Microsoft.Graph.Identity.SignIns -Scope CurrentUser"
    exit 1
}

# Import the module (suppress verbose output)
Import-Module Microsoft.Graph.Identity.SignIns -ErrorAction Stop

#endregion

#region --- Authentication ---

if (-not $SkipConnect) {
    try {
        Write-Verbose "Connecting to Microsoft Graph..."
        # Request minimum required scopes for reading CA policies
        Connect-MgGraph -Scopes "Policy.Read.All", "Policy.ReadWrite.ConditionalAccess" -ErrorAction Stop
        Write-Verbose "Successfully connected to Microsoft Graph."
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph. Error: $_"
        exit 1
    }
}
else {
    Write-Verbose "Skipping Connect-MgGraph as -SkipConnect was specified."

    # Validate that an active Graph session already exists
    $context = Get-MgContext
    if (-not $context) {
        Write-Error "No active Microsoft Graph session found. Either remove -SkipConnect or authenticate first using Connect-MgGraph."
        exit 1
    }
    Write-Verbose "Using existing Graph session for tenant: $($context.TenantId)"
}

#endregion

#region --- Output Directory Validation ---

try {
    if (-not (Test-Path -Path $OutputPath)) {
        Write-Verbose "Output directory does not exist. Creating: $OutputPath"
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
}
catch {
    Write-Error "Failed to create or access output directory '$OutputPath'. Error: $_"
    exit 1
}

#endregion

#region --- Export Conditional Access Policies ---

try {
    Write-Verbose "Retrieving all Conditional Access policies from Microsoft Graph..."

    # Retrieve all CA policies; -All ensures pagination is handled automatically
    $policies = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop

    if (-not $policies -or $policies.Count -eq 0) {
        Write-Warning "No Conditional Access policies found in the tenant. The backup file will be empty."
    }
    else {
        Write-Verbose "Retrieved $($policies.Count) Conditional Access policy/policies."
    }
}
catch {
    Write-Error "Failed to retrieve Conditional Access policies. Error: $_"
    exit 1
}

#endregion

#region --- Serialize and Write to File ---

try {
    # Build a timestamped filename for versioned backups (UTC to avoid timezone ambiguity)
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
    $outputFile = Join-Path -Path $OutputPath -ChildPath "ConditionalAccessPolicies_$timestamp`_UTC.json"

    Write-Verbose "Serializing policies to JSON..."

    # Convert to JSON with sufficient depth to capture nested conditions (e.g., grantControls, sessionControls)
    $jsonContent = $policies | ConvertTo-Json -Depth 20 -ErrorAction Stop

    # Write UTF-8 encoded file without BOM for compatibility with Git and downstream tools
    [System.IO.File]::WriteAllText($outputFile, $jsonContent, [System.Text.UTF8Encoding]::new($false))

    Write-Host "Backup complete." -ForegroundColor Green
    Write-Host "  Policies exported : $($policies.Count)" -ForegroundColor Cyan
    Write-Host "  Output file       : $outputFile" -ForegroundColor Cyan
    Write-Host "  Timestamp (UTC)   : $timestamp" -ForegroundColor Cyan
}
catch {
    Write-Error "Failed to serialize or write the backup file. Error: $_"
    exit 1
}

#endregion

#region --- Disconnect (optional, skip in automation contexts) ---

if (-not $SkipConnect) {
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        Write-Verbose "Disconnected from Microsoft Graph."
    }
    catch {
        Write-Warning "Could not cleanly disconnect from Microsoft Graph: $_"
    }
}

#endregion
