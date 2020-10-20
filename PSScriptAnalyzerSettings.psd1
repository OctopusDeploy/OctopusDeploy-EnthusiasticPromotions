# ScriptAnalyzerSettings.psd1
# sourced from https://github.com/EdrisT/SublimeLinter-contrib-Powershell/blob/669a90c841a0c99ff5c68913330b5a0fc09aeaaf/PSScriptAnalyzerSettings.psd1
# Example settings file for PSScriptAnalyzer.
@{
    # Uncomment next line to choose which diagnostic records will be shown.
    # Severity = @('Error', 'Warning', 'Information')

    # If you have created custom rules you want to use, uncomment next line and put the path to your custom rule in the CustomRulePath variable
    # CustomRulePath = 'path\to\CustomRuleModule.psm1'

    # A list of all rules can be aquired with Get-ScriptAnalyzerRule from a powershell prompt
    # More informaton about rules: https://github.com/PowerShell/PSScriptAnalyzer/tree/master/RuleDocumentation#psscriptanalyzer-rules
    # Include all default rules
    IncludeDefaultRules = $true

    # Specific rules to exclude.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost' #we know that where this runs is fine
    )

    # Specific rules to include. If this is used, all other rules are excluded!
    IncludeRules = @()

    # Compability rules
    Rules = @{
        PSUseCompatibleCommands = @{
            # Enable compatible commands check
            Enable = $true

            # Lists the PowerShell platforms we want to check compatibility with
            # More informaton about this: https://github.com/PowerShell/PSScriptAnalyzer/blob/master/RuleDocumentation/UseCompatibleCommands.md#usecompatiblecommands
            TargetProfiles = @(
                'win-8_x64_10.0.14393.0_5.1.14393.2791_x64_4.0.30319.42000_framework', #ps 5.1 on win2016
                'ubuntu_x64_18.04_6.2.0_x64_4.0.30319.42000_core' # ps 6.2 on ubuntu 18.0.4
            )
        }
        PSUseCompatibleSyntax = @{
            # Enable compatible syntax check
            Enable = $true
            # Lists the PowerShell versions we want to check compatibility with
            # More information about this: https://github.com/PowerShell/PSScriptAnalyzer/blob/master/RuleDocumentation/UseCompatibleSyntax.md
            TargetVersions = @(
                '5.1',
                '6.2'
            )
        }
    }
}
