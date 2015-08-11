param(
    [string] $jsonDatabag # TODO: Confirm with IT to decide the input contract
)

$setupSession = {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned
    $DebugPreference = "continue"
}

$replacewritehost = {
    remove-item function:write-host -ea 0

    # create a proxy for write-host
    $metaData = New-Object System.Management.Automation.CommandMetaData (Get-Command 'Microsoft.PowerShell.Utility\Write-Host')
    $proxy = [System.Management.Automation.ProxyCommand]::create($metaData)

    # change its behavior
    $content = $proxy -replace '(\$steppablePipeline.Process)', 'Write-Debug (Out-String -inputobject $Object -stream); $1'

    # load our version
    Invoke-Expression "function Write-Host { $content }"
}

function Invoke-DeployPhase {
    param([System.Management.Automation.Runspaces.PSSession[]] $sessions, [scriptblock] $script)

    $job = Invoke-Command -session $sessions {
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
        $_ >> .\$($_.PSComputerName).output
    }

    $exceptions = @()
    $job.ChildJobs | % { $_.Error | % { $exceptions += "$($_.OriginInfo.PSComputerName): $_" } }

    Remove-Job $job | Out-Null

    if ($exceptions.count -gt 0) { throw $exceptions }
}

function Get-NodeNames {
    $nodes = @("node1","node2")

    $nodes | % { "" > .\$($_).output }

    return $nodes
}

$injectEnvironmentVariables = {
    # Set all environment variables based on the input JSON string
    $env:SITE_NAME="RaveProdTestSite"
    $env:PACKAGE_DIR="\\hdcsharedmachine\C$\packages\Rave\2015.2.0"
    $env:DEPLOY_ID ="yyyyMMddhhmmss-buildid"
    $env:RELEASE_DIR="C:\MedidataApp\Rave\Sites\$env:SITE_NAME\release\$env:DEPLOY_ID"
    $env:ARTIFACTS_DIR="C:\MedidataApp\Rave\Sites\$env:SITE_NAME\artifacts\$env:DEPLOY_ID"
}

$installDeploymentScripts = {
    $packagePath = "$env:PACKAGES_DIR\Medidata.AdminProcess.zip"
    $artifactPath = "$env:ARTIFACTS_DIR\Medidata.AdminProcess.zip"
    $releaseDir = "$env:RELEASE_DIR\Medidata.AdminProcess"

    # Download deployment script package
    New-Item $artifactPath -type file -force
    Copy-Item $packagePath $artifactPath -force

    # Unzip deployment script package
    $shell = new-object -com shell.application
    $shell.namespace($releaseDir).CopyHere($shell.namespace($artifactPath).Items(), 1556)

    # Import the deploy tasks
    . $releaseDir\deploy_tasks_prod.ps1
}

function Invoke-DeployWorkflow {
    $nodes = Get-NodeNames
    $sessions = New-PSSession -ComputerName $nodes

    try {
        # 0. Prepare node to run the Rave deployment scripts
        Invoke-DeployPhase -sessions $sessions -script $setupSession
        Invoke-DeployPhase -sessions $sessions -script $replacewritehost
        Invoke-DeployPhase -sessions $sessions -script $injectEnvironmentVariables
        Invoke-DeployPhase -sessions $sessions -script $installDeploymentScripts

        Invoke-DeployPhase -sessions $sessions -script {
            # 1. Download, unpack and configure corresponding components on the underlying node
            itk -task download,unpack,config -role auto
            if (is-master) { itk -task download,unpack,config -role $db }
        }

        Invoke-DeployPhase -sessions $sessions -script {
            # 2. Stop existing services on the underlying node
            itk -task stop -role auto
        }

        Invoke-DeployPhase -sessions $sessions -script {
            # 3. Reinstall services on the udnerlying node
            if (is-master) { itk -task install -role $db }
            itk -task uninstall,install -role auto
        }

        Invoke-DeployPhase -sessions $sessions -script {
            # 4. Start services on the underlying node
            itk -task start -role auto
        }
    }
    catch {
        Write-Host "Something bad happened."
        Write-Error $_
    }

    Remove-PSSession $sessions
}

Invoke-DeployWorkflow
