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

    $result.Count | should -be 4


    $result[0].Version | Should -be "2020.4.7"
    $result[0].EnvironmentName | Should -be "Stable"
    $result[0].ChannelName | Should -be "Previous Release - 2020.4"

    $result[1].Version | Should -be "2020.5.0-ci0986"
    $result[1].EnvironmentName | Should -be "Staff"
    $result[1].ChannelName | Should -be "CI Builds"

    $result[2].Version | Should -be "2020.5.0-rc0002"
    $result[2].EnvironmentName | Should -be "Octopus Cloud Tests"
    $result[2].ChannelName | Should -be "Latest Release - 2020.5"

    $result[3].Version | Should -be "2020.6.0-ci0003"
    $result[3].EnvironmentName | Should -be "Octopus Cloud Tests"
    $result[3].ChannelName | Should -be "CI Builds"
  }

  It 'should only promote 2020.4.7' {
    # everything else is either:
    # * baking
    # * progressed as far as it can
    # * had a deployment attempted, but it failed
    # * had a deployment attempted - its still executing or queued

    Mock Test-PipelineBlocked { return $false; }
    $progression = (Get-Content -Path "SampleData/sample2.json" -Raw) | ConvertFrom-Json
    $channels = (Get-Content -Path "SampleData/channels.json" -Raw) | ConvertFrom-Json
    Mock Get-CurrentDate { return [System.DateTime]::Parse("19/Oct/2020 15:35:06") }

    $result = $((Get-PromotionCandidates $progression $channels).Values) | sort-object -property Version

    $result.Count | Should -be 1

    $result[0].Version | Should -be "2020.4.7"
    $result[0].EnvironmentName | Should -be "Stable"
    $result[0].ChannelName | Should -be "Previous Release - 2020.4"
  }

  It 'should promote 2020.6.0-ci0003 as it is the latest in the CI Builds channel' {
    Mock Test-PipelineBlocked { return $false; }
    Mock Get-CurrentDate { return [System.DateTime]::Parse("19/Oct/2020 15:35:06") }
    $progression = (Get-Content -Path "SampleData/sample3.json" -Raw) | ConvertFrom-Json
    $channels = (Get-Content -Path "SampleData/channels.json" -Raw) | ConvertFrom-Json

    $result = $((Get-PromotionCandidates $progression $channels).Values) | sort-object -property Version

    $result.Count | should -be 2

    $result[0].Version | Should -be "2020.4.7"
    $result[0].EnvironmentName | Should -be "Stable"
    $result[0].ChannelName | Should -be "Previous Release - 2020.4"

    # 2020.6.0-ci0026 is still baking

    $result[1].Version | Should -be "2020.6.0-ci0003"
    $result[1].EnvironmentName | Should -be "Octopus Cloud Tests"
    $result[1].ChannelName | Should -be "CI Builds"
  }

  It 'should not promote 2020.6.0-ci0002 as a newer release (2020.6.0-ci0003) has already been promoted to the Octopus Cloud Tests environment' {
    Mock Test-PipelineBlocked { return $false; }
    $progression = (Get-Content -Path "SampleData/sample4.json" -Raw) | ConvertFrom-Json
    $channels = (Get-Content -Path "SampleData/channels.json" -Raw) | ConvertFrom-Json
    Mock Get-CurrentDate { return [System.DateTime]::Parse("19/Oct/2020 15:35:06") }

    $result = $((Get-PromotionCandidates $progression $channels).Values) | sort-object -property Version

    $result.Count | should -be 0
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
}
