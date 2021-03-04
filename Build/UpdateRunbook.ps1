param (
    [Parameter(Mandatory=$true)][string]$octopusURL,
    [Parameter(Mandatory=$true)][string]$octopusAPIKey,
    [Parameter(Mandatory=$true)][string]$spaceName,
    [Parameter(Mandatory=$true)][string]$projectName,
    [Parameter(Mandatory=$true)][string]$runbookName
)

$ErrorActionPreference = "Stop";

# Define working variables
$header = @{ "X-Octopus-ApiKey" = $octopusAPIKey }

Write-Verbose "Getting Spaces"
# Get space
$spaces = Invoke-RestMethod -Uri "$octopusURL/api/spaces?partialName=$([uri]::EscapeDataString($spaceName))&skip=0&take=100" -Headers $header
$space = $spaces.Items | Where-Object { $_.Name -eq $spaceName }
Write-Verbose "Selected space with id $($space.Id)"

Write-Verbose "Getting Projects"
# Get project
$projects = Invoke-RestMethod -Uri "$octopusURL/api/$($space.Id)/projects?partialName=$([uri]::EscapeDataString($projectName))&skip=0&take=100" -Headers $header
$project = $projects.Items | Where-Object { $_.Name -eq $projectName }
Write-Verbose "Selected project with id $($project.Id)"

Write-Verbose "Getting Runbooks"
# Get runbook
$runbooks = Invoke-RestMethod -Uri "$octopusURL/api/$($space.Id)/projects/$($project.Id)/runbooks?partialName=$([uri]::EscapeDataString($runbookName))&skip=0&take=100" -Headers $header
$runbook = $runbooks.Items | Where-Object { $_.Name -eq $runbookName }
Write-Verbose "Selected runbook with id $($runbook.id)"

# Get a runbook snapshot template
$runbookSnapshotTemplate = Invoke-RestMethod -Uri "$octopusURL/api/$($space.Id)/runbookProcesses/$($runbook.RunbookProcessId)/runbookSnapshotTemplate" -Headers $header

# Create a runbook snapshot
$body = @{
    ProjectId = $project.Id
    RunbookId = $runbook.Id
    Name = $runbookSnapshotTemplate.NextNameIncrement
    Notes = $null
    SelectedPackages = @()
}

# Include latest package version
foreach($package in $runbookSnapshotTemplate.Packages)
{
    # Get latest package version
    Write-Host "Getting version for $($package.PackageId)"
    $packages = Invoke-RestMethod -Uri "$octopusURL/api/$($space.Id)/feeds/$($package.FeedId)/packages/versions?packageId=$($package.PackageId)&take=1" -Headers $header
    $latestPackage = $packages.Items | Select-Object -First 1
    Write-Host "Using latest version of $($latestPackage.Version) for package $($package.PackageId)"
    $package = @{
        ActionName = $package.ActionName
        Version = $latestPackage.Version
        PackageReferenceName = $package.PackageReferenceName
    }

    $body.SelectedPackages += $package
}

$body = $body | ConvertTo-Json -Depth 10
$runbookPublishedSnapshot = Invoke-RestMethod -Method Post -Uri "$octopusURL/api/$($space.Id)/runbookSnapshots?publish=true" -Body $body -Headers $header

# Re-get runbook
$runbook = Invoke-RestMethod -Method Get -Uri "$octopusURL/api/$($space.Id)/runbooks/$($runbook.Id)" -Headers $header

Write-Host "Publishing runbook"
# Publish the snapshot
$runbook.PublishedRunbookSnapshotId = $runbookPublishedSnapshot.Id
Invoke-RestMethod -Method Put -Uri "$octopusURL/api/$($space.Id)/runbooks/$($runbook.Id)" -Body ($runbook | ConvertTo-Json -Depth 10) -Headers $header

Write-Host "Published runbook snapshot: $($runbookPublishedSnapshot.Id) ($($runbookPublishedSnapshot.Name))"