param([ValidateSet('Enable','Disable')][string]$Action)

function Set-KonturAutostart {
    param([ValidateSet('Enable','Disable')][string]$Mode, [string]$InstallDirectory)
    $taskName = 'Kontur Wallpaper Startup'
    $launcher = Join-Path $InstallDirectory 'Kontur.exe'
    $startup = [Environment]::GetFolderPath('Startup')
    if (-not $startup) { throw 'Windows Startup folder was unavailable.' }
    $link = Join-Path $startup 'Контур.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $scheduled = $false
    try {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $folder = $service.GetFolder('\')
        $existing = $null
        try { $existing = $folder.GetTask($taskName) } catch {}
        if ($Mode -eq 'Disable') {
            if ($existing) {
                $target = $existing.Definition.Actions.Item(1)
                if ($target.Path -eq $launcher -and $target.Arguments -eq '--startup') { $folder.DeleteTask($taskName,0) }
            }
        } else {
            if ($existing) {
                $target = $existing.Definition.Actions.Item(1)
                if ((Split-Path -Leaf $target.Path) -ne 'Kontur.exe' -or $target.Arguments -ne '--startup') {
                    throw 'Another application owns the scheduled task name.'
                }
            }
            $account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $definition = $service.NewTask(0)
            $definition.RegistrationInfo.Description = 'Start Kontur and restore the selected video wallpaper at Windows sign-in.'
            $definition.Principal.UserId = $account
            $definition.Principal.LogonType = 3
            $definition.Principal.RunLevel = 0
            $definition.Settings.Enabled = $true
            $definition.Settings.DisallowStartIfOnBatteries = $false
            $definition.Settings.StopIfGoingOnBatteries = $false
            $definition.Settings.StartWhenAvailable = $true
            $definition.Settings.ExecutionTimeLimit = 'PT2M'
            $definition.Settings.MultipleInstances = 2
            $trigger = $definition.Triggers.Create(9)
            $trigger.UserId = $account
            $trigger.Delay = 'PT10S'
            $command = $definition.Actions.Create(0)
            $command.Path = $launcher
            $command.Arguments = '--startup'
            $command.WorkingDirectory = $InstallDirectory
            $null = $folder.RegisterTaskDefinition($taskName,$definition,6,$account,$null,3,$null)
            $scheduled = $true
        }
    } catch { Write-Warning $_.Exception.Message }

    if (Test-Path -LiteralPath $link -PathType Leaf) {
        $old = $shell.CreateShortcut($link)
        $ownsLink = $old.TargetPath -eq $launcher -or ($scheduled -and
            $old.Arguments -eq '--startup' -and (Split-Path -Leaf $old.TargetPath) -eq 'Kontur.exe')
        if ($ownsLink -and ($scheduled -or $Mode -eq 'Disable')) { Remove-Item -LiteralPath $link -ErrorAction Stop }
    }
    if ($Mode -eq 'Enable' -and -not $scheduled) {
        $shortcut = $shell.CreateShortcut($link)
        if ((Test-Path -LiteralPath $link) -and (Split-Path -Leaf $shortcut.TargetPath) -ne 'Kontur.exe') {
            throw 'Another application owns the Startup shortcut name.'
        }
        $shortcut.TargetPath = $launcher
        $shortcut.Arguments = '--startup'
        $shortcut.WorkingDirectory = $InstallDirectory
        $shortcut.IconLocation = "$launcher,0"
        $shortcut.Save()
    }
    if ($Mode -eq 'Enable') { if ($scheduled) { 'scheduled-task' } else { 'startup-shortcut' } }
}

if ($Action) { Set-KonturAutostart -Mode $Action -InstallDirectory $PSScriptRoot }
