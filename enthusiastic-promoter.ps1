
#lookup table for "how long the release needs to be in the specified environment, before allowing it to move on"
$waitTimeForEnvironmentLookup = @{
    "Environments-2583" = @{ "Name" = "Branch Instances (Staging)"; "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Hours 2;   }
    "Environments-2621" = @{ "Name" = "Octopus Cloud Tests";        "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Minutes 0; }
    "Environments-2601" = @{ "Name" = "Production";                 "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Minutes 0; }
    "Environments-2584" = @{ "Name" = "Branch Instances (Prod)";    "BakeTime" = New-TimeSpan -Days 1;    "StabilizationPhaseBakeTime" = New-TimeSpan -Days 1;    }
    "Environments-2585" = @{ "Name" = "Staff";                      "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Days 1;    }
    "Environments-2586" = @{ "Name" = "Friends of Octopus";         "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Days 1;    }
    "Environments-2587" = @{ "Name" = "Early Adopters";             "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Days 7;    }
    "Environments-2588" = @{ "Name" = "Stable";                     "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Days 7;    }
    "Environments-2589" = @{ "Name" = "General Availablilty";       "BakeTime" = New-TimeSpan -Minutes 0; "StabilizationPhaseBakeTime" = New-TimeSpan -Minutes 0; }
}

function Test-PipelineBlocked($release) {

    $activeProblems =  (Invoke-restmethod -Uri "$octofrontUrl/api/Problem/ActiveProblems/OctopusServer/$($release.Release.Version)" -Headers @{ 'Authorization' = "Bearer $($octofrontApiKey)"}).ActiveProblems

    return $activeProblems.Count -gt 0
}

function Get-CurrentEnvironment($progression, $release) {
    $nextEnvironmentId = $release.NextDeployments[0]
    $channelId = $release.Release.ChannelId
    $channelEnvironments = ((,$progression.ChannelEnvironments.PSObject.Properties | where-object { $_.Name -eq $channelId }).Value)
    foreach($environment in $channelEnvironments) {
        if ($environment.Id -eq $nextEnvironmentId) { break; }
        $currentEnvironmentId = $environment.Id
    }
    return $currentEnvironmentId
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

function Get-BrisbaneTimezone {
    if($IsLinux) {
        return "Australia/Brisbane"
    }

    return "E. Australia Standard Time"
}

function Test-IsWeekend {
    $dateAEST = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-CurrentDate), (Get-BrisbaneTimezone))
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

function Add-PromotionCandidate($promotionCandidates, $release, $nextEnvironmentId) {
    $key = $release.Release.ChannelId + "|" + $nextEnvironmentId
    $semanticVersion = New-Object Octopus.Versioning.Semver.SemanticVersion $release.Release.Version
    if ($promotionCandidates.ContainsKey($key)) {
        $existing = $promotionCandidates[$key]
        if ($existing.Version -lt $semanticVersion) {
            Write-Host " - This is a newer version than the previous promotion candidate ($($existing.Version)). Overriding promotion candidate to this version."
            $existing.Version = $semanticVersion
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

function Get-PromotionCandidates($progression, $channels, $lifecycles) {
    $promotionCandidates = @{}

    Write-Host "Looking for possible releases to promote:"
    foreach ($release in $progression.Releases) {
        write-host "--------------------------------------------------------"
        Write-Host "Evaluating candidate release $($release.Release.Version):"
        write-host "--------------------------------------------------------"
        write-host " - Channel is $(Get-ChannelName $channels $release.Release.ChannelId)"
        $currentEnvironmentId = Get-CurrentEnvironment $progression $release

        if ($release.NextDeployments.length -eq 0) {
            Write-Host " - Release has already progressed as far as it can."
        } elseif ($null -eq $currentEnvironmentId) {
            Write-Host " - Release has not yet been deployed to the first environment. Ignoring while we wait for the auto-deployment to the first environment to happen."
        } else {
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
            } elseif (($null -ne $mostRecentReleaseDeployedToNextEnvironment) -and ((New-Object Octopus.Versioning.Semver.SemanticVersion $mostRecentReleaseDeployedToNextEnvironment.Release.Version) -gt (New-Object Octopus.Versioning.Semver.SemanticVersion $release.Release.Version))) {
                $channelName = Get-ChannelName $channels $release.Release.ChannelId
                Write-Host " - A newer release '$($mostRecentReleaseDeployedToNextEnvironment.Release.Version)' in channel '$channelName' has already been deployed to '$nextEnvironmentName'."
            } else {
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
                } elseif(Test-IsWeekend) {
                    # Don't promote after 4pm Friday and 8am Monday morning AEST
                    Write-Host " - Bake time is complete but we aren't going to promote it as it's between 4pm Friday AEST and 8am Monday AEST to avoid potential issues with rolling out to more customers over the weekend when a large marjority of our team will be unavailable to assist with fixes."
                    return;
                }
                else {
                    if ($null -eq $deploymentsToCurrentEnvironment) {
                        # not sure this should ever happen
                        Write-Warning " - Bake time was ignored as there was no deployments to the environment $currentEnvironmentName"
                    } else {
                        Write-Host " - Completion time of last deployment to $currentEnvironmentName was $($deploymentsToCurrentEnvironment[0].CompletedTime) (UTC). Release has completed baking."
                    }
                    Write-Host " - Checking Andon cord to see if release pipeline is blocked..."
                    if (Test-PipelineBlocked $release) {
                        Write-Host " - Release pipeline is currently blocked with problems. Release will not be promoted."
                    } else {
                        Write-Host " - Release pipeline doesn't currently have any blocking problems. Release can be promoted."
                        Write-Host " - Found candidate for promotion - release $($release.Release.Version) to '$nextEnvironmentName' ($nextEnvironmentId)."

                        Add-PromotionCandidate -promotionCandidates $promotionCandidates -release $release -nextEnvironmentId $nextEnvironmentId
                    }
                }
            }
        }
    }
    return $promotionCandidates
}

function Get-FromApi($url) {
    Write-Verbose "Getting response from $url"
    $result = Invoke-restmethod -Uri $url -Headers @{ 'X-Octopus-ApiKey' = $octopusApiKey }

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
            & $octopusToolsPath\tools\octo.exe deploy-release --deployTo $promotionCandidate.EnvironmentId --version $promotionCandidate.Version --project "$projectName" --apiKey $OctopusApiKey --server "https://deploy.octopus.app" --space "Octopus Server"
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
    $octopusApiKey = $OctopusParameters["OctopusApiKey"]

    $candidates = Get-ChildItem -recurse -filter "Octopus.Versioning.dll"
    Add-Type -Path $candidates[-1].FullName

    $progression = Get-FromApi "https://deploy.octopus.app/api/$spaceId/progression/$projectId"
    $channels = Get-FromApi "https://deploy.octopus.app/api/$spaceId/projects/$projectId/channels"
    $lifecycles = Get-FromApi "https://deploy.octopus.app/api/$spaceId/lifecycles/all"

    $promotionCandidates = Get-PromotionCandidates -progression $progression -channels $channels -lifecycles $lifecycles

    Promote-Releases $promotionCandidates
}
