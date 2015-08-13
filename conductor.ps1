param(
    [string] $jsonDatabag # TODO: Confirm with IT to decide the input contract
)

$setupSession = {
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted
    $DebugPreference = "continue"
}

function Get-LogDir {
    "C:\LogFiles"
}

function Get-LogPath {
    param([string]$name)

    return "$(Get-LogDir)\$($name).log"
}

function Init-LogFiles {
    param([string []] $nodes)
    $nodes | % { New-Item (Get-LogPath $_) -type file -force } | Out-Null
}

function Invoke-DeployPhase {
    param([System.Management.Automation.Runspaces.PSSession[]] $session, [scriptblock] $script)

    $job = Invoke-Command -session $session {
        param($script)

        $scriptblock = $ExecutionContext.InvokeCommand.NewScriptBlock($script)
        try {
            . $scriptblock *>&1
        }
        catch {
            Write-Output $_
            Write-Error $_
        }
    } -ArgumentList ($script) -AsJob

    Wait-Job $job | Out-Null

    $outputs = Receive-Job $job
    $outputs | % {
        $_ >> (Get-LogPath $_.PSComputerName)
    }

    $exceptions = @()
    $job.ChildJobs | % { $_.Error | % { $exceptions += "$($_.OriginInfo.PSComputerName): $_" } }

    Remove-Job $job | Out-Null

    if ($exceptions.count -gt 0) { throw $exceptions }
}

function Get-NodeNames {
    $nodes = @("node1","node2")
    return ,$nodes
}

$installDeploymentScripts = {
    $artifactPath = "$env:ARTIFACTS_DIR\Medidata.AdminProcess.zip"
    $releaseDir = "$env:RELEASE_DIR\Medidata.AdminProcess"

    
    # Download deployment script package
    New-Item $releaseDir -type directory -force | Out-Null

    # Unzip deployment script package
    $shell = new-object -com shell.application
    $shell.namespace($releaseDir).CopyHere($shell.namespace($artifactPath).Items(), 1556)

    # Import the deploy tasks
    . $releaseDir\deploy_tasks_prod.ps1
}

function Get-DatabagFromJson {
    param([string]$databagJson)

    return ConvertFrom-Json $databagJson
}

function Get-EnvScriptFromDatabag {
    param([PSCustomObject]$databag)

    # Get the key/value pairs from the databag and create a script to set them as environment variables
    $envVariables = $databag.psobject.properties.name | % {
        #Write-Output "$_.Name = $databag.$($_.Name)"
        "[environment]::SetEnvironmentVariable(`"$_`", `"$($databag.$($_))`")"
    }

    return [scriptblock]::Create($envVariables -join "`n")
}

function Invoke-DeployWorkflow {
    $databag = Get-DatabagFromJson (Get-Content .\databag_example.json -Raw)

    $nodes = Get-NodeNames
    Init-Logfiles $nodes

    $sessions = New-PSSession -ComputerName $nodes

    $environmentVariables = Get-EnvScriptFromDatabag ($databag) | Out-String
    
    try {
        # 0. Prepare node to run the Rave deployment scripts
        Invoke-DeployPhase -session $sessions -script $setupSession
        Invoke-DeployPhase -session $sessions -script $environmentVariables
        Invoke-DeployPhase -session $sessions -script $installDeploymentScripts

        Invoke-DeployPhase -session $sessions -script {
            # 1. Download, unpack and configure corresponding components on the underlying node
            itk -task download,unpack,config -role auto
            if (is-master) { itk -task download,unpack,config -role $db }
        }

        Invoke-DeployPhase -session $sessions -script {
            # 2. Stop existing services on the underlying node
            itk -task stop -role auto
        }

        Invoke-DeployPhase -session $sessions -script {
            # 3. Reinstall services on the udnerlying node
            if (is-master) { itk -task install -role $db }
            itk -task uninstall,install -role auto
        }

        Invoke-DeployPhase -session $sessions -script {
            # 4. Start services on the underlying node
            itk -task start -role auto
        }
    }
    catch {
        Write-Output "Something bad happened."
        Write-Error $_
    }

    Remove-PSSession $sessions
}

Invoke-DeployWorkflow
