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

$testThings = {
    $VerbosePreference = "continue"
    hostname
    Write-Host "Host"
    Write-Output "Output"
    Write-Verbose "Verbose"
    #Write-Error "Error Message"
    Write-Warning "Warning"
    Write-Debug "Debug"
    Throw "Exception Message"
    Get-UICulture
}

$predeploy = {
    itk stop
}

function Invoke-ConducutorCommand {
    param($tasks)

    $sessions = Get-PSSession
    
    $job = Invoke-Command -session $sessions {
    param($tasks)
        
        $scriptblock = $ExecutionContext.InvokeCommand.NewScriptBlock($tasks)
        try {        
            . $scriptblock *>&1
        }
        catch {
            Write-Output $_
            Write-Error $_
        }
    } -ArgumentList ($tasks) -AsJob 
	
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

function Invoke-Conductor {
    param([string[]] $jsonDatabag)

    $nodes = @("node1","node2")

    $nodes | % { "" > .\$($_).output }

    $sessions = New-PSSession -ComputerName $nodes

    try {
        Invoke-ConducutorCommand $replacewritehost
        Invoke-ConducutorCommand $setupSession 
        #Invoke-ConducutorCommand $testThings       
        
        Invoke-ConducutorCommand {
             itk stop
        #     itk uninstall
        #     itk config, install, start
        }


    }
    catch {
        Write-Host "Something bad happened."
        Write-Error $_
    }
    
    Remove-PSSession $sessions	
}

Invoke-Conductor