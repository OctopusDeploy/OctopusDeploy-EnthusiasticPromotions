
Set-StrictMode -Version "Latest";
$ErrorActionPreference = "Stop";
$ConfirmPreference = "None";
trap { Write-Error $_ -ErrorAction Continue; exit 1 }

#lookup table for "how long the release needs to be in the specified environment, before allowing it to move on"
$waitTimeForEnvironmentLookup = @{
    "Environments-2583" = @{ "Name" = "Branch Instances (Staging)"; "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Hours 2;   "MinimumTimeBetweenDeployments" = New-TimeSpan -Minutes 0; }
    "Environments-2621" = @{ "Name" = "Octopus Cloud Tests";        "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Minutes 0; "MinimumTimeBetweenDeployments" = New-TimeSpan -Minutes 0; }
    "Environments-2601" = @{ "Name" = "Production";                 "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Minutes 0; "MinimumTimeBetweenDeployments" = New-TimeSpan -Minutes 0; }
    "Environments-2584" = @{ "Name" = "Branch Instances (Prod)";    "BakeTime" = New-TimeSpan -Days 1;    "StabilizationPhaseBakeTime" = New-TimeSpan -Days 1;    "MinimumTimeBetweenDeployments" = New-TimeSpan -Minutes 0; }
    "Environments-2585" = @{ "Name" = "Staff";                      "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Days 1;    "MinimumTimeBetweenDeployments" = New-TimeSpan -Minutes 0; }
    "Environments-2586" = @{ "Name" = "Friends of Octopus";         "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Days 1;    "MinimumTimeBetweenDeployments" = New-TimeSpan -Hours 12; }
    "Environments-2587" = @{ "Name" = "Early Adopters";             "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Days 7;    "MinimumTimeBetweenDeployments" = New-TimeSpan -Days 3; }
    "Environments-2588" = @{ "Name" = "Stable";                     "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Days 7;    "MinimumTimeBetweenDeployments" = New-TimeSpan -Days 7; }
    "Environments-2589" = @{ "Name" = "General Availablilty";       "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Minutes 0; "MinimumTimeBetweenDeployments" = New-TimeSpan -Minutes 0; }
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 10,
        [int]$InitialBackoffInMs = 500
    )

    $backoff = $InitialBackoffInMs
    $retrycount = -1
    $returnvalue = $null
    $success = $false;

    Write-Host "MaxRetries: $MaxRetries"
    Write-Host "InitialBackoffInMs: $InitialBackoffInMs"

    while($success -eq $false) {
        try {
            $retrycount++
            $success = $true;
            $returnvalue = Invoke-Command $ScriptBlock
        }
        catch
        {
            $success = $false;
            $message = If ($null -ne $_.Exception) { $_.Exception.ToString() } Else { $error | Select-Object -first 1 }
            Write-Host "Command failed: $message"

            if (
                    ($null -ne $_.Exception) -and
                    ([bool]($_.Exception.PSobject.Properties.name -match "Response")) -and
                    ($null -ne $_.Exception.Response)
                ) {
                $result = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($result)
                $reader.BaseStream.Position = 0
                $reader.DiscardBufferedData()
                $responseBody = $reader.ReadToEnd();
                Write-Host $responseBody
            }

            if($retrycount -eq $MaxRetries)
            {
                Write-Host "All $retrycount retires have failed."
                throw $_;
            }

            $backoff = $backoff + $backoff
            Write-Host "Invoking a backoff: $backoff [ms]. We have tried $retrycount times"
            Start-Sleep -MilliSeconds $backoff
        }
    }

    return $returnvalue
}

function Test-PipelineBlocked($release) {
    $url = "$octofrontUrl/api/Problem/ActiveProblems/OctopusServer/$($release.Release.Version)"
    try
    {
        $activeProblemsCount = Invoke-WithRetry -ScriptBlock {
            Write-Verbose "Getting response from $url"
            $activeProblems =  (Invoke-restmethod -Uri $url -Headers @{ 'Authorization' = "Bearer $($octofrontApiKey)"}).ActiveProblems

            # log out the  json, so we can diagnose what's happening / write a test for it
            write-verbose "--------------------------------------------------------"
            write-verbose "response:"
            write-verbose "--------------------------------------------------------"
            write-verbose ($activeProblems | ConvertTo-Json -depth 10)
            write-verbose "--------------------------------------------------------"

            return $activeProblems.Count
        }

        return $activeProblemsCount -gt 0

    } catch {
        Write-Error "Unable to reach $url to check if there are any active problems - aborting promotion to be safe. Please investigate as to why Octofront is uncontactable."
        Write-Error $_.Exception.ToString() 
    }

    return $true
}

function Get-CurrentEnvironment($progression, $release) {
    if ($release.NextDeployments.Length -eq 0) { return $null }
    $nextEnvironmentId = $release.NextDeployments[0]
    $channelId = $release.Release.ChannelId
    $channelEnvironments = ((,$progression.ChannelEnvironments.PSObject.Properties | where-object { $_.Name -eq $channelId }).Value)
    $selectedEnvironmentId = $null
    foreach($environment in $channelEnvironments) {
        if ($environment.Id -eq $nextEnvironmentId) { break; }
        $selectedEnvironmentId = $environment.Id
    }
    return $selectedEnvironmentId
}

function Get-EnvironmentName($progression, $environmentId) {
    return ($progression.Environments | Where-Object { $_.Id -eq $environmentId }).Name
}

function Get-AlreadyDeployedEnvironmentIds($release) {
  return @($release.Deployments.PSObject.Properties.Name)
}

function Get-DeploymentsToEnvironment($release, $environmentId) {
  return (,($release.Deployments.PSObject.Properties | where-object { $_.Name -eq $environmentId }))
}

function Get-ChannelName($channels, $channelId) {
    return ($channels.Items | Where-object { $_.Id -eq $channelId }).Name
}

function Get-CurrentDate {
  # for mocking
  return Get-Date
}

function Get-CurrentTimezone {
    # for mocking
    return Get-TimeZone
}

function Get-BrisbaneTimezone {
    if($IsLinux) {
        return Get-TimeZone -Id "Australia/Brisbane"
    }

    return Get-TimeZone -Id "E. Australia Standard Time"
}

function Test-IsWeekendAEST {
    $utc = [System.TimeZoneInfo]::ConvertTimeToUtc((Get-CurrentDate), (Get-CurrentTimezone))
    $dateAEST = [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, (Get-BrisbaneTimezone))

    return ($dateAEST.DayOfWeek -eq "Friday" -and $dateAEST.Hour -ge 16) -or
            $dateAEST.DayOfWeek -eq "Saturday" -or
            $dateAEST.DayOfWeek -eq "Sunday" -or
            ($dateAEST.DayOfWeek -eq "Monday" -and $dateAEST.Hour -lt 8)
}

function Get-MostRecentDeploymentToEnvironment ($release, $environmentId) {
    $alreadyDeployedEnvironments = [array](Get-AlreadyDeployedEnvironmentIds $release)
    if ($alreadyDeployedEnvironments.Contains($environmentId)) {
        $deploymentsToEnvironment = [array](Get-DeploymentsToEnvironment $release $environmentId)
        if ($null -ne $deploymentsToEnvironment) {
            return $deploymentsToEnvironment.Value | Sort-Object -Property CompletedTime -Descending | Select-Object -First 1
        }
    }
    return $null
}

function Add-PromotionCandidate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $promotionCandidates,
        [Parameter(Mandatory)]
        $release,
        [Parameter(Mandatory)]
        $nextEnvironmentId,
        [Parameter(Mandatory)]
        $nextEnvironmentName
    )
    $key = $release.Release.ChannelId + "|" + $nextEnvironmentId
    $semanticVersion = New-Object Octopus.Versioning.Semver.SemanticVersion $release.Release.Version
    if ($promotionCandidates.ContainsKey($key)) {
        $existing = $promotionCandidates[$key]
        if ($existing.Version -lt $semanticVersion) {
            Write-Host " - This is a newer version than the previous promotion candidate ($($existing.Version)). Overriding promotion candidate to this version."
            $existing.Version = $semanticVersion
        } else {
            Write-Host " - This is an older version than the current promotion candidate ($($existing.Version)). Ignoring this promotion candidate."
        }
    } else {
        $promotionCandidates.Add($key, [PSCustomObject]@{
            ChannelId       = $release.Release.ChannelId
            ChannelName     = Get-ChannelName $channels $release.Release.ChannelId
            EnvironmentId   = $nextEnvironmentId
            EnvironmentName = $nextEnvironmentName
            Version         = $semanticVersion
        })
    }
}

function Get-MostRecentReleaseDeployedToEnvironment($progression, $release, $environmentId) {
    return $progression.Releases `
           | Where-Object { $_.Release.ChannelId -eq $release.Release.ChannelId } `
           | where-object { (Get-AlreadyDeployedEnvironmentIds $_) -contains $environmentId } `
           | sort-object { New-Object Octopus.Versioning.Semver.SemanticVersion $_.Release.Version } -Descending `
           | Select-Object -First 1
}

function Test-ReleaseInStabilizationPhase($channelId, $channels) {
    $channel = $channels.Items | Where-Object { $_.Id -eq $channelId }

    switch ($channel.LifecycleId) {
        "Lifecycles-1665" { return $false; } # Branch Builds
        "Lifecycles-1670" { return $false; } # CI Builds
        "Lifecycles-1666" { return $false; } # Current Release (after going GA)
        "Lifecycles-1667" { return $true;  } # Current Release (prior to going GA)
        "Lifecycles-1668" { return $false; } # LTS Release Branch
        "Lifecycles-1669" { return $false; } # Previous Release (prior to new release going GA)
    }
    # unknown lifecycle - let's default to slow... safe by default.
    return $true;
}

# Upgrades at the moment take the instance down, so we dont want to cause an outage every day
# Once we have 0-downtime upgrades for Octopus Cloud, we can remove this
function Test-ShouldLimitDeploymentsToEnvironment($nextEnvironmentId, $mostRecentReleaseDeployedToNextEnvironment) {
    if ($null -eq $mostRecentReleaseDeployedToNextEnvironment) {
        return $false;
    }
    $minimumTimeBetweenDeployments = $waitTimeForEnvironmentLookup[$nextEnvironmentId].MinimumTimeBetweenDeployments
    $mostRecentDeploymentToNextEnvironment = Get-MostRecentDeploymentToEnvironment $mostRecentReleaseDeployedToNextEnvironment $nextEnvironmentId
    return ($mostRecentDeploymentToNextEnvironment.CompletedTime.Add($minimumTimeBetweenDeployments) -gt (Get-CurrentDate))
}

class PromotionCandidateResult {
    [bool]$IsCandidate = $false
    [string]$NextEnvironmentId
    [string]$NextEnvironmentName
}

function Test-IsPromotionCandidate {
    [OutputType([System.Collections.Hashtable])]
    param ($release, $progression, $channels)
    write-host "--------------------------------------------------------"
    Write-Host "Evaluating candidate release $($release.Release.Version):"
    write-host "--------------------------------------------------------"
    write-host " - Channel is $(Get-ChannelName $channels $release.Release.ChannelId)"
    $currentEnvironmentId = Get-CurrentEnvironment $progression $release
    $nonCandidateResult = [PromotionCandidateResult]::new()

    if ($release.NextDeployments.length -eq 0) {
        Write-Host " - Release has already progressed as far as it can."
        return $nonCandidateResult
    }
    if ($null -eq $currentEnvironmentId) {
        Write-Host " - Release has not yet been deployed to the first environment. Ignoring while we wait for the auto-deployment to the first environment to happen."
        return $nonCandidateResult
    }

    $currentEnvironmentName = Get-EnvironmentName $progression $currentEnvironmentId
    Write-Host " - Current environment is '$($currentEnvironmentName)'"

    if ($release.NextDeployments.length -gt 1) {
        # this can happen if a lifecycle is modified and now there's now a gap in the progression
        Write-Host " - Unexpected number of NextDeployments - expected 1, but found $($release.NextDeployments.length):"
        $release.NextDeployments | foreach-object { Write-Host "   - $(Get-EnvironmentName $progression $_) ($_)" }
        Write-Host " - Focusing on $(Get-EnvironmentName $progression $release.NextDeployments[0]) for this run"
    }
    $nextEnvironmentId = $release.NextDeployments[0]
    $nextEnvironmentName = Get-EnvironmentName $progression $nextEnvironmentId
    Write-Host " - Next environment is '$($nextEnvironmentName)'"

    $mostRecentDeploymentToNextEnvironment = Get-MostRecentDeploymentToEnvironment $release $nextEnvironmentId
    $mostRecentReleaseDeployedToNextEnvironment = Get-MostRecentReleaseDeployedToEnvironment -progression $progression -release $release -environmentId $nextEnvironmentId
    if ($null -ne $mostRecentDeploymentToNextEnvironment) {
        Write-Host " - Deployment to '$nextEnvironmentName' already exists in state $($mostRecentDeploymentToNextEnvironment[0].State)."
        return $nonCandidateResult
    }
    if (($null -ne $mostRecentReleaseDeployedToNextEnvironment) -and ((New-Object Octopus.Versioning.Semver.SemanticVersion $mostRecentReleaseDeployedToNextEnvironment.Release.Version) -gt (New-Object Octopus.Versioning.Semver.SemanticVersion $release.Release.Version))) {
        $channelName = Get-ChannelName $channels $release.Release.ChannelId
        Write-Host " - A newer release '$($mostRecentReleaseDeployedToNextEnvironment.Release.Version)' in channel '$channelName' has already been deployed to '$nextEnvironmentName'."
        return $nonCandidateResult
    }
    if (Test-ShouldLimitDeploymentsToEnvironment -nextEnvironmentId $nextEnvironmentId -mostRecentReleaseDeployedToNextEnvironment $mostRecentReleaseDeployedToNextEnvironment) {
        $minimumTimeBetweenDeployments = $waitTimeForEnvironmentLookup[$nextEnvironmentId].MinimumTimeBetweenDeployments
        $mostRecentDeploymentToNextEnvironment = Get-MostRecentDeploymentToEnvironment $mostRecentReleaseDeployedToNextEnvironment $nextEnvironmentId
        Write-Host " - Release '$($release.Release.Version)' is valid for deployment, but '$($mostRecentReleaseDeployedToNextEnvironment.Release.Version)' was deployed recently (within the last $minimumTimeBetweenDeployments). Will try again later after $($mostRecentDeploymentToNextEnvironment.CompletedTime.Add($minimumTimeBetweenDeployments)) (UTC)."
        return $nonCandidateResult
    }

    if (Test-ReleaseInStabilizationPhase -channelId $release.Release.ChannelId -channels $channels) {
        Write-Host " - Release '$($release.Release.Version)' is in stabilization phase - allowing longer bake times"
        $bakeTime = $waitTimeForEnvironmentLookup[$nextEnvironmentId].StabilizationPhaseBakeTime
    } else {
        Write-Host " - Release '$($release.Release.Version)' is not in stabilization phase - using shorter bake times"
        $bakeTime = $waitTimeForEnvironmentLookup[$nextEnvironmentId].BakeTime
    }
    Write-Host " - Calculated the bake time that releases should stay in environment '$currentEnvironmentName' before being promoted to '$nextEnvironmentName' to be $bakeTime."

    $deploymentsToCurrentEnvironment = Get-MostRecentDeploymentToEnvironment $release $currentEnvironmentId
    if (($null -ne $deploymentsToCurrentEnvironment) -and ($deploymentsToCurrentEnvironment.CompletedTime.Add($bakeTime) -gt (Get-CurrentDate))) {
        Write-Host " - Completion time of last deployment to $currentEnvironmentName was $($deploymentsToCurrentEnvironment.CompletedTime) (UTC)"
        Write-Host " - This release is still baking. Will try again later after $($deploymentsToCurrentEnvironment.CompletedTime.Add($bakeTime)) (UTC)."
        return $nonCandidateResult
    }
    if (Test-IsWeekendAEST) {
        # Don't promote after 4pm Friday and 8am Monday morning AEST
        Write-Host " - Bake time is complete but we aren't going to promote it as it's between 4pm Friday AEST and 8am Monday AEST. This helps us avoid potential issues with rolling out to lots of customers over the weekend when a large majority of our team is unavailable to assist if something goes wrong."
        return $nonCandidateResult
    }

    if ($null -eq $deploymentsToCurrentEnvironment) {
        # not sure this should ever happen
        Write-Warning " - Bake time was ignored as there was no deployments to the environment $currentEnvironmentName"
    } else {
        Write-Host " - Completion time of last deployment to $currentEnvironmentName was $($deploymentsToCurrentEnvironment[0].CompletedTime) (UTC). Release has completed baking."
    }
    Write-Host " - Checking Andon cord to see if release pipeline is blocked..."
    if (Test-PipelineBlocked $release) {
        Write-Host " - Release pipeline is currently blocked with problems. Release will not be promoted."
        return $nonCandidateResult
    }
    Write-Host " - Release pipeline doesn't currently have any blocking problems. Release can be promoted."
    Write-Host " - Found candidate for promotion - release $($release.Release.Version) to '$nextEnvironmentName' ($nextEnvironmentId)."
    $candidateResult = [PromotionCandidateResult]::new()
    $candidateResult.IsCandidate = $true
    $candidateResult.NextEnvironmentId = $nextEnvironmentId
    $candidateResult.NextEnvironmentName = $nextEnvironmentName
    return $candidateResult
}

function Get-PromotionCandidates($progression, $channels, $lifecycles) {
    $promotionCandidates = @{}

    Write-Host "Looking for possible releases to promote:"
    foreach ($release in $progression.Releases) {
        $result = [PromotionCandidateResult](Test-IsPromotionCandidate -release $release -progression $progression -channels $channels)
        if ($result.IsCandidate) {
            Add-PromotionCandidate -promotionCandidates $promotionCandidates -release $release -nextEnvironmentId $result.NextEnvironmentId -nextEnvironmentName $result.nextEnvironmentName
        }
    }
    return $promotionCandidates
}

function Get-FromApi($url) {
    Write-Verbose "Getting response from $url"
    $result = Invoke-restmethod -Uri $url -Headers @{ 'X-Octopus-ApiKey' = $enthusiasticPromoterApiKey }

    # log out the  json, so we can diagnose what's happening / write a test for it
    write-verbose "--------------------------------------------------------"
    write-verbose "response:"
    write-verbose "--------------------------------------------------------"
    write-verbose ($result | ConvertTo-Json -depth 10)
    write-verbose "--------------------------------------------------------"
    return $result
}

function Promote-Releases($promotionCandidates) {
    write-host "--------------------------------------------------------"
    if ($promotionCandidates.Count -eq 0) {
        Write-Host "No promotion candidates found"
    } else {
        write-host "Promoting releases:"
        $promotionCandidates.keys | ForEach-Object {
            $promotionCandidate = $promotionCandidates.Item($_)
            write-host "--------------------------------------------------------"
            Write-Host " - Promoting release '$($promotionCandidate.Version)' to environment '$($promotionCandidate.EnvironmentName)' ($($promotionCandidate.EnvironmentId))."
            write-host "--------------------------------------------------------"
            & $octopusToolsPath\tools\octo.exe deploy-release --deployTo $promotionCandidate.EnvironmentId --version $promotionCandidate.Version --project "$projectName" --apiKey $enthusiasticPromoterApiKey --server "https://deploy.octopus.app" --space "Octopus Server"
        }
    }
    write-host "--------------------------------------------------------"
}

if (Test-Path variable:OctopusParameters) {
    #automatically provided variables
    $projectName = $OctopusParameters["Octopus.Project.Name"]
    $spaceId = $OctopusParameters["Octopus.Space.Id"]
    $projectId = $OctopusParameters["Octopus.Project.Id"]

    #variables provided from additional packages
    $octopusToolsPath = $OctopusParameters["Octopus.Action.Package[OctopusTools].ExtractedPath"]
    $octopusVersioningPath = $OctopusParameters["Octopus.Action.Package[Octopus.Versioning].ExtractedPath"]

    #variables from the project
    $octofrontApiKey = $OctopusParameters["OctofrontSoftwareProblemsAuthToken"]
    $octofrontUrl = $OctopusParameters["OctofrontUrl"]
    $enthusiasticPromoterApiKey = $OctopusParameters["EnthusiasticPromoterApiKey"]

    $candidates = Get-ChildItem -recurse -filter "Octopus.Versioning.dll"
    Add-Type -Path $candidates[-1].FullName

    $progression = Get-FromApi "https://deploy.octopus.app/api/$spaceId/progression/$projectId"
    $channels = Get-FromApi "https://deploy.octopus.app/api/$spaceId/projects/$projectId/channels"
    $lifecycles = Get-FromApi "https://deploy.octopus.app/api/$spaceId/lifecycles/all"

    $promotionCandidates = Get-PromotionCandidates -progression $progression -channels $channels -lifecycles $lifecycles

    Promote-Releases $promotionCandidates
}
