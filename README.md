# Medidata.Rave.Conductor
A PowerShell script to manage Medidata Rave deployment on Prod multiple node environment

# The highlevel workflow
```powershell
workflow Deploy-Rave-Single-Url
{
  param([string[]] $jsonDatabag)

  sequence {

    try{
      $allEnvVarPowerShellString = Generate-Env-Vars-From-Json $jsonDatabag #Maybe not json

      Validate-Env-Vars $allEnvVarPowerShellString

      # 1. Prepare deployment scripts and env vars for each node
      foreach -parallel($node in $nodes)
      {
        # Inject databag with env vars on each node's release directory
        $allEnvVarPowerShellString | Out-File \\$node.ComputerName\C$\MedidataApp\Sites\SiteName\12factor\release\$env:DEPLOY_ID\databag.ps1

        # Copy Rave deployment scripts onto each node's release directory
        Unzip-RaveAdminProcess $pathOfMedidataAdminProcessZip \\$node.ComputerName\C$\MedidataApp\Sites\SiteName\12factor\release\$env:DEPLOY_ID\Medidata.AdminProcess
      }
      # Wait here until all node return

      # 2. Start playing "lego blocks" on each node
      foreach -parallel($node in $nodes)
      {
        invoke-command -computerName $node -scripts { gotoFolder; itk download,unpack,config } >> T:\RaveDeployte\deploye_id\node_name\log.txt
      }
      # Wait here until all node return

      foreach -parallel($node in $nodes)
      {
        invoke-command -computerName $node -scripts { gotoFolder; itk stop }
      }
      # Wait here until all node return

      foreach -parallel($node in $nodes)
      {
        invoke-command -computerName $node -scripts { gotoFolder; itk uninstall,install }
      }
      # Wait here until all node return

      foreach -parallel($node in $nodes)
      {
        invoke-command -computerName $node -scripts { gotoFolder; itk start }
      }
      # Wait here until all node return

      # 3. All lego games are over till here.
      Exeucte-diag-level1

    }
    catch
    {

    }
    finally
    {

    }
  }
}
```
