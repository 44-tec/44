$ErrorActionPreference = "Stop"

$RootPath = "C:\temp\Dashboard"
$DataPath = Join-Path $RootPath "Data"
$ProcessedPath = Join-Path $RootPath "Processed"
$LogPath = Join-Path $RootPath "Logs"

$InventoryPath = Join-Path $DataPath "Inventaire.csv"
$PatchingPath = Join-Path $DataPath "Patching.csv"

$OutputPath = Join-Path $ProcessedPath "DevicesConsolidated.csv"
$LogFile = Join-Path $LogPath "Consolidation.log"

New-Item -ItemType Directory -Force -Path $ProcessedPath, $LogPath | Out-Null

function Write-Log {
    param([string]$Message)

    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Add-Content -Path $LogFile -Value $Line -Encoding UTF8
}

function Get-Delimiter {
    param([string]$Path)

    $FirstLine = Get-Content -Path $Path -TotalCount 1

    $CommaCount = ($FirstLine.ToCharArray() | Where-Object { $_ -eq "," }).Count
    $SemicolonCount = ($FirstLine.ToCharArray() | Where-Object { $_ -eq ";" }).Count

    if ($SemicolonCount -gt $CommaCount) {
        return ";"
    }

    return ","
}

function Import-CsvSmart {
    param(
        [string]$Path,
        [string[]]$RequiredColumns
    )

    if (-not (Test-Path $Path)) {
        throw "Fichier introuvable : $Path"
    }

    $Delimiter = Get-Delimiter -Path $Path

    Write-Log "Import du fichier : $Path"
    Write-Log "Délimiteur détecté : $Delimiter"

    $Data = Import-Csv -Path $Path -Delimiter $Delimiter -Encoding UTF8

    if (-not $Data -or $Data.Count -eq 0) {
        throw "Fichier vide ou illisible : $Path"
    }

    $Columns = $Data[0].PSObject.Properties.Name

    foreach ($Column in $RequiredColumns) {
        if ($Column -notin $Columns) {
            throw "Colonne obligatoire manquante dans $Path : $Column"
        }
    }

    Write-Log "Lignes importées : $($Data.Count)"

    return $Data
}

function Normalize-Hostname {
    param([string]$Hostname)

    if ([string]::IsNullOrWhiteSpace($Hostname)) {
        return $null
    }

    $Value = $Hostname.Trim().ToUpper()

    if ($Value.Contains(".")) {
        $Value = $Value.Split(".")[0]
    }

    return $Value
}

function Normalize-Value {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    return $Value.Trim()
}

function Convert-DateSafe {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return [datetime]$Value
    }
    catch {
        return $null
    }
}

function Get-SourceFreshnessStatus {
    param([string]$DateValue)

    $Date = Convert-DateSafe -Value $DateValue

    if (-not $Date) {
        return "Unknown"
    }

    $Days = ((Get-Date) - $Date).Days

    if ($Days -le 2) {
        return "Fresh"
    }

    if ($Days -le 7) {
        return "Warning"
    }

    return "Stale"
}

function Get-DataQualityStatus {
    param(
        [string]$Hostname,
        [string]$OperatingSystem,
        [string]$OSBuild,
        [string]$PrimaryUser,
        [string]$AntivirusLastCheckIn
    )

    $Issues = @()

    if ([string]::IsNullOrWhiteSpace($Hostname)) {
        $Issues += "MissingHostname"
    }

    if ([string]::IsNullOrWhiteSpace($OperatingSystem)) {
        $Issues += "MissingOperatingSystem"
    }

    if ([string]::IsNullOrWhiteSpace($OSBuild)) {
        $Issues += "MissingOSBuild"
    }

    if ([string]::IsNullOrWhiteSpace($PrimaryUser)) {
        $Issues += "MissingPrimaryUser"
    }

    $Freshness = Get-SourceFreshnessStatus -DateValue $AntivirusLastCheckIn

    if ($Freshness -eq "Stale") {
        $Issues += "StaleAntivirusCheckIn"
    }

    if ($Freshness -eq "Unknown") {
        $Issues += "UnknownAntivirusCheckIn"
    }

    if ($Issues.Count -eq 0) {
        return "OK"
    }

    return ($Issues -join "; ")
}

Write-Log "===== Début consolidation ====="

$InventoryRequiredColumns = @(
    "Hostname",
    "OperatingSystem",
    "MANUFACTURER",
    "MODEL",
    "MFU_FULLNAME",
    "Email",
    "BIOSVersion0",
    "SEP group",
    "Last Online time (Check-in)"
)

$PatchingRequiredColumns = @(
    "Hostname",
    "OS_Build"
)

$Inventory = Import-CsvSmart -Path $InventoryPath -RequiredColumns $InventoryRequiredColumns
$Patching = Import-CsvSmart -Path $PatchingPath -RequiredColumns $PatchingRequiredColumns

$PatchingIndex = @{}

foreach ($Row in $Patching) {
    $HostnameKey = Normalize-Hostname -Hostname $Row.Hostname

    if (-not $HostnameKey) {
        continue
    }

    if (-not $PatchingIndex.ContainsKey($HostnameKey)) {
        $PatchingIndex[$HostnameKey] = $Row
    }
    else {
        Write-Log "Doublon détecté dans Patching.csv pour Hostname : $HostnameKey"
    }
}

$InventoryHostnames = New-Object System.Collections.Generic.HashSet[string]
$Consolidated = @()

foreach ($Device in $Inventory) {
    $Hostname = Normalize-Hostname -Hostname $Device.Hostname

    if (-not $Hostname) {
        Write-Log "Ligne ignorée : Hostname vide dans Inventaire.csv"
        continue
    }

    if ($InventoryHostnames.Contains($Hostname)) {
        Write-Log "Doublon détecté dans Inventaire.csv pour Hostname : $Hostname"
        continue
    }

    [void]$InventoryHostnames.Add($Hostname)

    $PatchingRow = $null
    $OSBuild = ""
    $PatchingSourceStatus = "MissingPatching"

    if ($PatchingIndex.ContainsKey($Hostname)) {
        $PatchingRow = $PatchingIndex[$Hostname]
        $OSBuild = Normalize-Value -Value $PatchingRow.OS_Build
        $PatchingSourceStatus = if ($OSBuild) { "OK" } else { "UnknownBuild" }
    }

    $OperatingSystem = Normalize-Value -Value $Device.OperatingSystem
    $Manufacturer = Normalize-Value -Value $Device.MANUFACTURER
    $Model = Normalize-Value -Value $Device.MODEL
    $PrimaryUser = Normalize-Value -Value $Device.MFU_FULLNAME
    $Email = Normalize-Value -Value $Device.Email
    $BIOSVersion = Normalize-Value -Value $Device.BIOSVersion0
    $SEPGroup = Normalize-Value -Value $Device.'SEP group'
    $AntivirusLastCheckIn = Normalize-Value -Value $Device.'Last Online time (Check-in)'

    $AntivirusFreshness = Get-SourceFreshnessStatus -DateValue $AntivirusLastCheckIn

    $DataQualityStatus = Get-DataQualityStatus `
        -Hostname $Hostname `
        -OperatingSystem $OperatingSystem `
        -OSBuild $OSBuild `
        -PrimaryUser $PrimaryUser `
        -AntivirusLastCheckIn $AntivirusLastCheckIn

    $Consolidated += [PSCustomObject]@{
        Hostname                = $Hostname
        OperatingSystem         = $OperatingSystem
        OSBuild                 = $OSBuild
        Manufacturer            = $Manufacturer
        Model                   = $Model
        PrimaryUser             = $PrimaryUser
        Email                   = $Email
        BIOSVersion             = $BIOSVersion
        SEPGroup                = $SEPGroup
        AntivirusLastCheckIn    = $AntivirusLastCheckIn
        AntivirusFreshness      = $AntivirusFreshness
        InventorySourceStatus   = "OK"
        PatchingSourceStatus    = $PatchingSourceStatus
        DataQualityStatus       = $DataQualityStatus
        ConsolidatedAt          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
}

$MissingInventoryRows = 0

foreach ($PatchRow in $Patching) {
    $Hostname = Normalize-Hostname -Hostname $PatchRow.Hostname

    if (-not $Hostname) {
        continue
    }

    if (-not $InventoryHostnames.Contains($Hostname)) {
        $MissingInventoryRows++

        $OSBuild = Normalize-Value -Value $PatchRow.OS_Build

        $Consolidated += [PSCustomObject]@{
            Hostname                = $Hostname
            OperatingSystem         = ""
            OSBuild                 = $OSBuild
            Manufacturer            = ""
            Model                   = ""
            PrimaryUser             = ""
            Email                   = ""
            BIOSVersion             = ""
            SEPGroup                = ""
            AntivirusLastCheckIn    = ""
            AntivirusFreshness      = "Unknown"
            InventorySourceStatus   = "MissingInventory"
            PatchingSourceStatus    = if ($OSBuild) { "OK" } else { "UnknownBuild" }
            DataQualityStatus       = "MissingInventory"
            ConsolidatedAt          = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
}

$Consolidated |
    Sort-Object Hostname |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Log "Fichier généré : $OutputPath"
Write-Log "Postes consolidés : $($Consolidated.Count)"
Write-Log "Postes inventaire : $($Inventory.Count)"
Write-Log "Postes patching : $($Patching.Count)"
Write-Log "Postes présents dans Patching mais absents de Inventaire : $MissingInventoryRows"
Write-Log "===== Fin consolidation ====="

Write-Host ""
Write-Host "Consolidation terminée."
Write-Host "Source inventaire : $InventoryPath"
Write-Host "Source patching   : $PatchingPath"
Write-Host "Sortie            : $OutputPath"
Write-Host "Log               : $LogFile"
Write-Host "Postes consolidés : $($Consolidated.Count)"