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

function Invoke-RemoteScriptInParallel {
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

function Invoke-DeployWorkflow {
    $nodes = Get-NodeNames
    $sessions = New-PSSession -ComputerName $nodes

    try {
        Invoke-RemoteScriptInParallel -sessions $sessions -script {
            # 0. Prepare node to run the Rave deployment scripts
            & $replacewritehost
            & $setupSession
            & $injectEnvironmentVariables
        }

        Invoke-RemoteScriptInParallel -sessions $sessions -script {
            # 1. Download deployment script package
            New-Item -path $env:ARTIFACTS_DIR -type directory
            Copy-Item "$env:PACKAGES_DIR\Medidata.AdminProcess.zip" -Destination "$env:ARTIFACTS_DIR"

            # 2. Unzip deployment script package
            (new-object -com shell.application).namespace(\"$env:RELEASE_DIR\Medidata.AdminProcess\").CopyHere((new-object -com shell.application).namespace(\"$env:ARTIFACTS_DIR\Medidata.AdminProcess.zip\").Items(), 1556)

            . $env:RELEASE_DIR\Medidata.AdminProcess\deploy_tasks_prod.ps1

            # 3. Download, unpack and configure corresponding components on the underlying node
            itk -task download,unpack,config -role auto
            if (is-master) { itk -task download,unpack,config -role $db }
        }

        Invoke-RemoteScriptInParallel -sessions $sessions -script {
            # 4. Stop existing services on the underlying node
            itk -task stop -role auto
        }

        Invoke-RemoteScriptInParallel -sessions $sessions -script {
            # 5. Reinstall services on the udnerlying node
            if (is-master) { itk -task install -role $db }
            itk -task uninstall,install -role auto
        }

        Invoke-RemoteScriptInParallel -sessions $sessions -script {
            # 6. Start services on the underlying node
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
