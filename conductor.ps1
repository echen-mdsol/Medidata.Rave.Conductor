param(
    [string] $jsonDatabag # TODO: Confirm with IT to decide the input contract
)

$setupSession = {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned
    $DebugPreference = "continue"
    . C:\Github\Rave\Medidata.AdminProcess\deploy_tasks_dev.ps1
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
    $env:PACKAGE_DIR="\\hdcsharedmachine\packages\Rave\2015.2.0"
    $env:DEPLOY_ID ="yyyyMMddhhmmss-buildid"
    $env:RELEASE_DIR="C:\MedidataApp\Rave\Sites\$env:SITE_NAME\release\$env:DEPLOY_ID"
    $env:ARTIFACTS_DIR="C:\MedidataApp\Rave\Sites\$env:SITE_NAME\artifacts\$env:DEPLOY_ID"
}

function Invoke-DeployWorkflow {
    $nodes = Get-NodeNames
    $sessions = New-PSSession -ComputerName $nodes

    try {
        Invoke-RemoteScriptInParallel -sessions $sessions -script $replacewritehost
        Invoke-RemoteScriptInParallel -sessions $sessions -script $setupSession
        Invoke-RemoteScriptInParallel -sessions $sessions -script $injectEnvironmentVariables
        Invoke-RemoteScriptInParallel -sessions $sessions -script {
            New-Item -path $env:ARTIFACTS_DIR -type directory
            Copy-Item "$env:PACKAGES_DIR\*.zip" "$env:ARTIFACTS_DIR"
            New-Item -path "$env:RELEASE_DIR\Medidata.AdminProcess" -type directory
            # Unzip deployment scripts
            (new-object -com shell.application).namespace(\"$env:RELEASE_DIR\\Medidata.AdminProcess\").CopyHere((new-object -com shell.application).namespace(\"$env:ARTIFACTS_DIR\\Medidata.AdminProcess.zip\").Items(), 1556)

            . $env:RELEASE_DIR\\Medidata.Installation\\deploy_tasks_prod.ps1

            itk -task unpack,config -role auto
            if (is-master) { itk -task unpack,config -role $db }
            if (is-master) { validate-env-vars }
        }

        Invoke-RemoteScriptInParallel -sessions $sessions -script {
            itk -task stop -role auto
        }

        Invoke-RemoteScriptInParallel -sessions $sessions -script {
            if (is-master) { itk -task install -role $db }
            itk -task uninstall,install -role auto
        }

        Invoke-RemoteScriptInParallel -sessions $sessions -script {
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
