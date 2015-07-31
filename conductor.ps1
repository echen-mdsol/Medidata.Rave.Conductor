$setupSession = {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned
    . C:\Github\Rave\Medidata.AdminProcess\deploy_tasks_dev.ps1
}

$testThings = {
    $VerbosePreference = "continue"
    hostname
    Write-Host "Host"
    Write-Output "Output"
    Write-Verbose "Verbose"
    Write-Error "Error Message"
    Write-Warning "Warning"
    Write-Debug "Debug"
    #Throw "Exception Message"
    Get-UICulture
}

function Invoke-ConductorCommands {
    param($tasks)

    $sessions = Get-PSSession
    $job = Invoke-Command -session $sessions {
    param($script)

        $scriptblock = [ScriptBlock]::Create($script)
        try {        
            . $scriptblock *>&1
        }
        catch {
            Write-Error $_
        }
    } -ArgumentList ($tasks) -AsJob 
	
    Wait-Job $job | Out-Null

    $outputs = Receive-Job $job
    $outputs | % { 
         $_ >> c:\temp\$($_.PSComputerName).output 
    }

    $exceptions = @()
    $job.ChildJobs | % { $_.Error | % { $exceptions += $_ } }

    if ($exceptions.count -gt 0) { throw $exceptions }

    Remove-Job $job | Out-Null
}

function Invoke-ConductorCommands-test {
    param($tasks)

    $sessions = Get-PSSession
    Invoke-Command -session $sessions $tasks
}

$predeploy = {
    itk stop
}

function Invoke-Conductor {
    param([string[]] $jsonDatabag)

    $nodes = @("node1","node2")

    $nodes | % { "" > C:\temp\$($_).output }

    $sessions = New-PSSession -ComputerName $nodes

    try {
        Invoke-ConductorCommands $setupSession
        Invoke-ConductorCommands $testThings
        Invoke-ConductorCommands $predeploy
    }
    catch {
        Write-Error "Something bad happened"
    }
    
    Remove-PSSession $sessions	
}


Invoke-Conductor