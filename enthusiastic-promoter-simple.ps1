
Set-StrictMode -Version "Latest";
$ErrorActionPreference = "Stop";
$ConfirmPreference = "None";
trap { Write-Error $_ -ErrorAction Continue; exit 1 }

#lookup table for "how long the release needs to be in the specified environment, before allowing it to move on"
$waitTimeForEnvironmentLookup = @{
    "Environments-1183" = @{ "Name" = "dev-westus2";           "BakeTime" = New-TimeSpan -Minutes 0;  "PreventDeploymentsOnWeekends" = $false; }
    "Environments-833" =  @{ "Name" = "test-westus2";          "BakeTime" = New-TimeSpan -Minutes 0;  "PreventDeploymentsOnWeekends" = $false; }
    "Environments-3086" = @{ "Name" = "test-westus";           "BakeTime" = New-TimeSpan -Minutes 0;  "PreventDeploymentsOnWeekends" = $false; }
    "Environments-2381" = @{ "Name" = "production-eastau";     "BakeTime" = New-TimeSpan -Days 1;     "PreventDeploymentsOnWeekends" = $true; }
    "Environments-1913" = @{ "Name" = "production-westeurope"; "BakeTime" = New-TimeSpan -Days 1;     "PreventDeploymentsOnWeekends" = $true; }
    "Environments-829" =  @{ "Name" = "production-westus2";    "BakeTime" = New-TimeSpan -Days 1;     "PreventDeploymentsOnWeekends" = $true; }
    "Environments-3085" = @{ "Name" = "production-westus";     "BakeTime" = New-TimeSpan -Minutes 0;  "PreventDeploymentsOnWeekends" = $true; }
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
    if($IsLinux -or $IsMacOS) {
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
           | Where-Object { $false -eq [string]::IsNullOrEmpty($_.Deployments) } `
           | Where-Object { (Get-AlreadyDeployedEnvironmentIds $_) -contains $environmentId } `
           | Sort-Object { New-Object Octopus.Versioning.Semver.SemanticVersion $_.Release.Version } -Descending `
           | Select-Object -First 1
}

# Upgrades at the moment take the instance down, so we dont want to cause an outage every day
# Once we have 0-downtime upgrades for Octopus Cloud, we can remove this
function Test-ShouldLimitDeploymentsToEnvironment($nextEnvironmentId, $mostRecentReleaseDeployedToNextEnvironment) {
    if ($null -eq $mostRecentReleaseDeployedToNextEnvironment) {
        return $false;
    }
    if (-not ($waitTimeForEnvironmentLookup.ContainsKey($nextEnvironmentId))) {
        Write-Error "Unable to find environment '$nextEnvironmentId' in lookup table. Cannot continue." -ErrorAction Continue
        exit 1
    }
    $minimumTimeBetweenDeployments = $waitTimeForEnvironmentLookup[$nextEnvironmentId].MinimumTimeBetweenDeployments
    $mostRecentDeploymentToNextEnvironment = Get-MostRecentDeploymentToEnvironment $mostRecentReleaseDeployedToNextEnvironment $nextEnvironmentId
    if ($null -eq $mostRecentDeploymentToNextEnvironment.CompletedTime) {
        return $true
    }
    return ($mostRecentDeploymentToNextEnvironment.CompletedTime.Add($minimumTimeBetweenDeployments) -gt (Get-CurrentDate))
}

function Format-Timespan([System.TimeSpan] $timespan) {
    $result = ""
    if ($timespan.Days -gt 0) {
        $result = $result + "$($timespan.Days)d:$($timespan.Hours.ToString("D2"))h"
    } else {
        $result = $result + "$($timespan.Hours)h"
    }
    if ($timespan.Minutes -gt 0) { $result = $result + ":$($timespan.Minutes.ToString("D2"))m"}
    return $result
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

    $candidateResults = New-Object 'Collections.Generic.List[PromotionCandidateResult]'

    if ($release.NextDeployments.length -eq 0) {
        Write-Host " - Release has already progressed as far as it can."
        $candidateResults.Add($nonCandidateResult)
        return $candidateResults
    }
    if ($null -eq $currentEnvironmentId) {
        Write-Host " - Release has not yet been deployed to the first environment. Ignoring while we wait for the auto-deployment to the first environment to happen."
        $candidateResults.Add($nonCandidateResult)
        return $candidateResults
    }

    $currentEnvironmentName = Get-EnvironmentName $progression $currentEnvironmentId
    Write-Host " - Current environment is '$($currentEnvironmentName)'"

    if ($release.NextDeployments.length -gt 1) {
        # this can happen if a lifecycle is modified and now there's now a gap in the progression
        Write-Host " - Unexpected number of NextDeployments - expected 1, but found $($release.NextDeployments.length):"
        $release.NextDeployments | foreach-object { Write-Host "   - $(Get-EnvironmentName $progression $_) ($_)" }
        Write-Host " - Focusing on $(Get-EnvironmentName $progression $release.NextDeployments[0]) for this run"
    }
    write-host $release.NextDeployments
    foreach ($nextEnvironmentId in $release.NextDeployments) {
        #$nextEnvironmentId = $release.NextDeployments[0]
        $nextEnvironmentName = Get-EnvironmentName $progression $nextEnvironmentId
        Write-Host " - Next environment is '$($nextEnvironmentName)'"

        $mostRecentDeploymentToNextEnvironment = Get-MostRecentDeploymentToEnvironment $release $nextEnvironmentId
        $mostRecentReleaseDeployedToNextEnvironment = Get-MostRecentReleaseDeployedToEnvironment -progression $progression -release $release -environmentId $nextEnvironmentId
        if ($null -ne $mostRecentDeploymentToNextEnvironment) {
            Write-Host " - Deployment to '$nextEnvironmentName' already exists in state $($mostRecentDeploymentToNextEnvironment[0].State)."
            continue
        }
        if (($null -ne $mostRecentReleaseDeployedToNextEnvironment) -and ((New-Object Octopus.Versioning.Semver.SemanticVersion $mostRecentReleaseDeployedToNextEnvironment.Release.Version) -gt (New-Object Octopus.Versioning.Semver.SemanticVersion $release.Release.Version))) {
            $channelName = Get-ChannelName $channels $release.Release.ChannelId
            Write-Host " - A newer release '$($mostRecentReleaseDeployedToNextEnvironment.Release.Version)' in channel '$channelName' has already been deployed to '$nextEnvironmentName'."
            continue
        }
        if (Test-ShouldLimitDeploymentsToEnvironment -nextEnvironmentId $nextEnvironmentId -mostRecentReleaseDeployedToNextEnvironment $mostRecentReleaseDeployedToNextEnvironment) {
            $minimumTimeBetweenDeployments = $waitTimeForEnvironmentLookup[$nextEnvironmentId].MinimumTimeBetweenDeployments
            $mostRecentDeploymentToNextEnvironment = Get-MostRecentDeploymentToEnvironment $mostRecentReleaseDeployedToNextEnvironment $nextEnvironmentId
            if ($null -eq $mostRecentDeploymentToNextEnvironment.CompletedTime) {
                Write-Host " - Release '$($release.Release.Version)' is blocked as '$($mostRecentReleaseDeployedToNextEnvironment.Release.Version)' has not yet completed. Will try again later."
            } else {
                $ageOfLastDeployment = Format-Timespan (Get-CurrentDate).Subtract($mostRecentDeploymentToNextEnvironment.CompletedTime)
                $retryTime = $mostRecentDeploymentToNextEnvironment.CompletedTime.Add($minimumTimeBetweenDeployments)
                $formattedMinimumTimeBetweenDeployments = Format-Timespan $minimumTimeBetweenDeployments
                Write-Host " - Release '$($release.Release.Version)' is blocked as '$($mostRecentReleaseDeployedToNextEnvironment.Release.Version)' was deployed recently ($ageOfLastDeployment ago, which is within the last $formattedMinimumTimeBetweenDeployments)."
                $currDate = Get-CurrentDate
                $retryTimeSpan = Format-TimeSpan $retryTime.Subtract($currDate)
                Write-Host " - Will try again later after $($retryTime.ToString("R")) (in $retryTimeSpan)."
            }
            continue
        }

        Write-Host " - Release '$($release.Release.Version)' is not in stabilization phase - using shorter bake times"
        $bakeTime = $waitTimeForEnvironmentLookup[$currentEnvironmentId].BakeTime
        $formattedBakeTime = Format-Timespan $bakeTime
        Write-Host " - Calculated the bake time that releases should stay in environment '$currentEnvironmentName' before being promoted to '$nextEnvironmentName' to be $formattedBakeTime."

        $deploymentsToCurrentEnvironment = Get-MostRecentDeploymentToEnvironment $release $currentEnvironmentId
        if (($null -ne $deploymentsToCurrentEnvironment) -and ($deploymentsToCurrentEnvironment.CompletedTime.Add($bakeTime) -gt (Get-CurrentDate))) {
            $ageOfLastDeployment = Format-Timespan (Get-CurrentDate).Subtract($deploymentsToCurrentEnvironment.CompletedTime)
            Write-Host " - Completion time of last deployment to $currentEnvironmentName was $($deploymentsToCurrentEnvironment.CompletedTime.ToString("R")) ($ageOfLastDeployment ago)"
            $retryTime = $deploymentsToCurrentEnvironment.CompletedTime.Add($bakeTime)
            $currDate = Get-CurrentDate
            $retryTimeSpan = Format-TimeSpan $retryTime.Subtract($currDate)
            Write-Host " - This release is still baking. Will try again later after $($retryTime.ToString("R")) (in $retryTimeSpan)."
            continue
        }
        if (-not $waitTimeForEnvironmentLookup.ContainsKey($nextEnvironmentId)) {
            Write-Host " - $nextEnvironmentName does not have a mapping for progression, skipping."
            continue
        }

        if (Test-IsWeekendAEST -and $waitTimeForEnvironmentLookup[$nextEnvironmentId].PreventDeploymentsOnWeekends) {
            # Don't promote after 4pm Friday and 8am Monday morning AEST
            Write-Host " - Bake time is complete but we aren't going to promote it to $nextEnvironmentName as it's between 4pm Friday AEST and 8am Monday AEST. This helps us avoid potential issues with rolling out to lots of customers over the weekend when a large majority of our team is unavailable to assist if something goes wrong."
            continue
        }

        if ($null -eq $deploymentsToCurrentEnvironment) {
            # not sure this should ever happen
            Write-Warning " - Bake time was ignored as there was no deployments to the environment $currentEnvironmentName"
        } else {
            Write-Host " - Completion time of last deployment to $currentEnvironmentName was $($deploymentsToCurrentEnvironment[0].CompletedTime.ToString("R")). Release has completed baking."
        }
        Write-Host " - Checking Andon cord to see if release pipeline is blocked..."
        Write-Host " - Release pipeline doesn't currently have any blocking problems. Release can be promoted."
        Write-Host " - Found candidate for promotion - release $($release.Release.Version) to '$nextEnvironmentName' ($nextEnvironmentId)."
        $candidateResult = [PromotionCandidateResult]::new()
        $candidateResult.IsCandidate = $true
        $candidateResult.NextEnvironmentId = $nextEnvironmentId
        $candidateResult.NextEnvironmentName = $nextEnvironmentName
        $candidateResults.Add($candidateResult)
    }
    return $candidateResults
}

function Get-PromotionCandidates($progression, $channels) {
    $promotionCandidates = @{}

    Write-Host "Looking for possible releases to promote:"
    foreach ($release in $progression.Releases) {
        Write-Host $release.NextDeployments
        $results = [PromotionCandidateResult[]](Test-IsPromotionCandidate -release $release -progression $progression -channels $channels)
        foreach ($result in $results) {
            if ($result.IsCandidate) {
                Add-PromotionCandidate -promotionCandidates $promotionCandidates -release $release -nextEnvironmentId $result.NextEnvironmentId -nextEnvironmentName $result.nextEnvironmentName
            }
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
            & $octopusToolsPath deploy-release --deployTo $promotionCandidate.EnvironmentId --version $promotionCandidate.Version --project $projectId --apiKey $enthusiasticPromoterApiKey --server "$octopusServerUrl" --space $spaceId
        }
    }
    write-host "--------------------------------------------------------"
}

#if (Test-Path variable:OctopusParameters) {
    #automatically provided variables
    $projectName = "Promotion tester"#$OctopusParameters["Octopus.Project.Name"]
    $spaceId = "Spaces-142" #$OctopusParameters["Octopus.Space.Id"]
    $projectId = "Projects-4985" #$OctopusParameters["Octopus.Project.Id"]

    #variables provided from additional packages
    $octopusToolsPath = "dotnet-octo" #$OctopusParameters["Octopus.Action.Package[OctopusTools].ExtractedPath"]

    #variables from the project
    $enthusiasticPromoterApiKey = "API-CHWIBWDVLKUMHWBGCAXL5UEHKGWOTGX" #$OctopusParameters["EnthusiasticPromoterApiKey"]
    $octopusServerUrl = "https://deploy.octopus.app" #$OctopusParameters["Octopus.Web.ServerUri"]

    try {
        $candidates = Get-ChildItem -recurse -filter "Octopus.Versioning.dll"
        Add-Type -Path $candidates[-1].FullName

        $progression = Get-FromApi "$octopusServerUrl/api/$spaceId/progression/$($projectId)?releaseHistoryCount=100"
        $channels = Get-FromApi "$octopusServerUrl/api/$spaceId/projects/$projectId/channels"

        $promotionCandidates = Get-PromotionCandidates -progression $progression -channels $channels
    } catch {

        [System.Console]::Error.WriteLine("$($error[0].CategoryInfo.Category): $($error[0].Exception.Message)")
        [System.Console]::Error.WriteLine($error[0].InvocationInfo.PositionMessage)
        [System.Console]::Error.WriteLine($error[0].ScriptStackTrace)
        if ($null -ne $error[0].ErrorDetails) {
            [System.Console]::Error.WriteLine($error[0].ErrorDetails.Message)
        }

        exit 1
    }

    Promote-Releases $promotionCandidates
#}
