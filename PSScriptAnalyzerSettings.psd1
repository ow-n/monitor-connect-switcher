@{
    # PSScriptAnalyzer settings for monitor-connect-switcher.
    # Starts from the default rule set and excludes four rules that do not fit
    # an interactive, Windows-only desktop-automation script. Each exclusion is
    # a deliberate, justified choice - not a way to hide real problems.
    ExcludeRules = @(
        # PSAvoidUsingWriteHost:
        # This tool's user experience IS colored host output - -Status, -List,
        # and the apply log all use Write-Host with -ForegroundColor on purpose.
        # The script returns nothing to a pipeline, so routing this to the output
        # stream would only break the colored console UX it exists to provide.
        'PSAvoidUsingWriteHost',

        # PSReviewUnusedParameter:
        # The -Identify overlay wires WinForms event handlers whose required
        # signature is (sender, eventArgs). Only eventArgs is needed, but the
        # leading 'sender' parameter must stay so eventArgs binds positionally.
        'PSReviewUnusedParameter',

        # PSUseSingularNouns:
        # 'Show-Profiles' intentionally lists ALL profiles; the plural reads
        # clearer than a forced-singular noun. Cosmetic only, no functional impact.
        'PSUseSingularNouns',

        # PSAvoidAssignmentToAutomaticVariable:
        # '-Profile' is this tool's established public CLI parameter (every .bat
        # wrapper and all docs call '.\monitor-profile.ps1 -Profile <name>').
        # Inside the script $Profile resolves to the parameter via local scope;
        # the automatic $Profile (the PS profile path) is never used here, so the
        # shadowing is harmless. Renaming would break the public interface.
        'PSAvoidAssignmentToAutomaticVariable'
    )
}
