Set-StrictMode -Version "Latest";
$ErrorActionPreference = "Stop";
$ConfirmPreference = "None";
trap { Write-Error $_ -ErrorAction Continue; exit 1 }

Describe 'Enthusiastic promoter' {
  BeforeAll {
    if ($null -eq ("Octopus.Versioning.Semver.SemanticVersion" -as [type])) {
      $existing = Get-Package "Octopus.Versioning" -ErrorAction SilentlyContinue
      if ($null -eq $existing) {
        install-package "Octopus.Versioning" -source https://www.nuget.org/api/v2 -Force -Scope CurrentUser
      }

      $zip = [System.IO.Compression.ZipFile]::Open((Get-Package "Octopus.Versioning").Source,"Read")
      $memStream = [System.IO.MemoryStream]::new()
      $reader = [System.IO.StreamReader]($zip.entries[2]).Open()
      $reader.BaseStream.CopyTo($memStream)
      [byte[]]$bytes = $memStream.ToArray()
      $reader.Close()
      $zip.dispose()

      [System.Reflection.Assembly]::Load($bytes)
    }

    . (Join-Path -Path $PSScriptRoot -ChildPath "enthusiastic-promoter.ps1")
  }

  It 'scenario 1' {
    Mock Test-PipelineBlocked { return $false; }
    $progression = (Get-Content -Path "SampleData/sample1.json" -Raw) | ConvertFrom-Json
    $channels = (Get-Content -Path "SampleData/channels.json" -Raw) | ConvertFrom-Json
    Mock Get-CurrentDate { return [System.DateTime]::Parse("19/Oct/2020 15:35:06") }

    $result = $((Get-PromotionCandidates $progression $channels).Values) | sort-object -property Version

    $result.Count | should -be 3

    $result[0].Version | Should -be "2020.5.0-ci0986"
    $result[0].EnvironmentName | Should -be "Staff"
    $result[0].ChannelName | Should -be "CI Builds"

    $result[1].Version | Should -be "2020.5.0-rc0002"
    $result[1].EnvironmentName | Should -be "Octopus Cloud Tests"
    $result[1].ChannelName | Should -be "Latest Release - 2020.5"

    $result[2].Version | Should -be "2020.6.0-ci0003"
    $result[2].EnvironmentName | Should -be "Octopus Cloud Tests"
    $result[2].ChannelName | Should -be "CI Builds"
  }

  It 'scenario 2' {
    # everything is either:
    # * delayed to avoid too much downtime on octopus cloud (2020.4.7)
    # * progressed as far as it can (2020.3.8, 2020.3.9, 2020.4.5, 2020.4.6, 2020.5.0-ci0969, 2020.5.0-ci0986,  2020.5.0-pr7455-1007,  2020.5.0-pr7455-1008)
    # * has not yet been auto-deployed to the first environment (2020.4.6-beta0001)
    # * had a deployment attempted - its still executing (2020.6.0-ci0003)
    # * had a deployment attempted - its still queued (2020.6.0-ci0002)

    Mock Test-PipelineBlocked { return $false; }
    $progression = (Get-Content -Path "SampleData/sample2.json" -Raw) | ConvertFrom-Json
    $channels = (Get-Content -Path "SampleData/channels.json" -Raw) | ConvertFrom-Json
    Mock Get-CurrentDate { return [System.DateTime]::Parse("19/Oct/2020 15:35:06") }

    $result = $((Get-PromotionCandidates $progression $channels).Values) | sort-object -property Version

    $result.Count | Should -be 0
  }

  It 'should promote 2020.6.0-ci0003 as it is the latest in the CI Builds channel' {
    Mock Test-PipelineBlocked { return $false; }
    Mock Get-CurrentDate { return [System.DateTime]::Parse("19/Oct/2020 15:35:06") }
    $progression = (Get-Content -Path "SampleData/sample3.json" -Raw) | ConvertFrom-Json
    $channels = (Get-Content -Path "SampleData/channels.json" -Raw) | ConvertFrom-Json

    $result = $((Get-PromotionCandidates $progression $channels).Values) | sort-object -property Version

    $result.Count | should -be 1

    # 2020.4.7 is in a holding pattern to avoid too much downtime during upgrades on Octopus Cloud
    # 2020.6.0-ci0026 is still baking

    $result[0].Version | Should -be "2020.6.0-ci0003"
    $result[0].EnvironmentName | Should -be "Octopus Cloud Tests"
    $result[0].ChannelName | Should -be "CI Builds"
  }

  It 'should not promote 2020.6.0-ci0002 as a newer release (2020.6.0-ci0003) has already been promoted to the Octopus Cloud Tests environment' {
    Mock Test-PipelineBlocked { return $false; }
    $progression = (Get-Content -Path "SampleData/sample4.json" -Raw) | ConvertFrom-Json
    $channels = (Get-Content -Path "SampleData/channels.json" -Raw) | ConvertFrom-Json
    Mock Get-CurrentDate { return [System.DateTime]::Parse("19/Oct/2020 15:35:06") }

    $result = $((Get-PromotionCandidates $progression $channels).Values) | sort-object -property Version

    $result | should -be $null
  }

  It 'should choose the stabilisation phase for channels using the Current Release (prior to going GA) lifecycle' {
    $channels = (Get-Content -Path "SampleData/channels.json" -Raw) | ConvertFrom-Json

    $channelId = "Channels-4583" #'Latest Release - 2020.5', uses lifecycle Lifecycles-1667 'Current Release (prior to going GA)'
    $result = Test-ReleaseInStabilizationPhase $channelId $channels
    $result | Should -be $true

    $channelId = "Channels-4449" #'Previous Release - 2020.4', uses lifecycle Lifecycles-1669 'Previous Release (prior to new release going GA)'
    $result = Test-ReleaseInStabilizationPhase $channelId $channels
    $result | Should -be $false
  }

  It 'should handle a modified lifecycle where an earlier phase is added' {
    # when an earlier phase is added, it means there are two candidates for deployment
    Mock Test-PipelineBlocked { return $false; }
    $progression = (Get-Content -Path "SampleData/sample5-modifiedlifecycle.json" -Raw) | ConvertFrom-Json
    $channels = (Get-Content -Path "SampleData/channels.json" -Raw) | ConvertFrom-Json
    Mock Get-CurrentDate { return [System.DateTime]::Parse("19/Oct/2020 15:35:06") }

    $result = $((Get-PromotionCandidates $progression $channels).Values) | sort-object -property Version

    $result | should -be $null
  }

  It 'should handle a release that has not yet been deployed to the initial environment (for as single release) ' {
    Mock Test-PipelineBlocked { return $false; }
    $progression = (Get-Content -Path "SampleData/sample5-release-created-but-no-deployments.json" -Raw) | ConvertFrom-Json
    $channels = (Get-Content -Path "SampleData/channels.json" -Raw) | ConvertFrom-Json
    Mock Get-CurrentDate { return [System.DateTime]::Parse("01/Nov/2020 8:52:17 AM") }

    $result = $((Get-PromotionCandidates $progression $channels).Values) | sort-object -property Version

    $result | should -be $null
  }

  It 'should handle a release that has not yet been deployed to the initial environment (with multiple releases)' {
    Mock Test-PipelineBlocked { return $false; }
    $progression = (Get-Content -Path "SampleData/sample6.json" -Raw) | ConvertFrom-Json
    $channels = (Get-Content -Path "SampleData/channels.json" -Raw) | ConvertFrom-Json
    Mock Get-CurrentDate { return [System.DateTime]::Parse("05/Feb/2021 1:08:20 AM") }

    $result = $((Get-PromotionCandidates $progression $channels).Values) | sort-object -property Version

    $result.Count | should -be 1

    $result[0].Version | Should -be "2020.5.9"
    $result[0].EnvironmentName | Should -be "Production"
    $result[0].ChannelName | Should -be "Latest Release - 2020.5"
  }

  It 'should not promote during weekend period' -TestCases @( # All written in AEST times
    @{ datetime = '20/Nov/2020 16:00:00'; shouldPromote = $false} #Friday 4pm
    @{ datetime = '20/Nov/2020 15:59:59'; shouldPromote = $true} #Friday 3:59pm
    @{ datetime = '21/Nov/2020 00:00:00'; shouldPromote = $false} #Saturday
    @{ datetime = '22/Nov/2020 00:00:00'; shouldPromote = $false} #Sunday
    @{ datetime = '23/Nov/2020 07:59:59'; shouldPromote = $false} #Monday 7:59am
    @{ datetime = '23/Nov/2020 08:00:00'; shouldPromote = $true} #Monday 8:00am
  ) {
    param
    (
      [string] $dateTime,
      [boolean] $shouldPromote
    )

    $timezone = "E. Australia Standard Time";
    if($IsLinux) {
      $timezone = "Australia/Brisbane"
    }

    Mock Test-PipelineBlocked { $false }
    Mock Get-CurrentTimezone { return Get-TimeZone -Id $timezone }
    Mock Get-CurrentDate { return [System.DateTime]::Parse($dateTime) }

    $progression = (Get-Content -Path "SampleData/sample3.json" -Raw) | ConvertFrom-Json
    $channels = (Get-Content -Path "SampleData/channels.json" -Raw) | ConvertFrom-Json

    $result = $((Get-PromotionCandidates $progression $channels).Values) | sort-object -property Version

    ($null -ne $result) | should -be $shouldPromote
  }

  Describe 'Invoke-WithRetry' {
    It 'It stops retries'  {
      $script:counter = 0
      {
          Invoke-WithRetry -ScriptBlock {
            $script:counter++;
            throw "Test error"
          } -MaxRetries 2 -InitialBackoffInMs 1
      } | Should -Throw

      $script:counter | Should -be 3
    }

    It "Does not retry" {
      $script:counter = 0;
      {
          Invoke-WithRetry {
          $script:counter++;
          throw "Test exception"
          } -MaxRetries 0
      } | Should -Throw

      $script:counter | Should -be 1
    }

    It "Works with blocks that do not return value" {
      $script:counter = 0
      Invoke-WithRetry {
          $script:counter++;
          Write-Host "Test"
      }

      $script:counter | Should -be 1
    }

    It "Works with blocks that return value" {
      $value = 12345;
      $returnValue = Invoke-WithRetry {
          return $value;
      }
      $returnValue | Should -be $value
    }
  }
}
