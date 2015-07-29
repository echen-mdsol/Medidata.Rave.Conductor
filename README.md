# Medidata.Rave.Conductor
A PowerShell script to manage Medidata Rave deployment on Prod multiple node environment

# The highlevel workflow
```powershell
workflow Deploy-Rave
{
  param([string[]] $ComputerName, [PSCredential] $DomainCred, [PsCredential] $MachineCred)
  
  sequence {
    
    try{
      Generate-Env-Vars-From-Json #Maybe not json
      
      Validate-Env-Vars
      
      foreach -parallel($node in $nodes)
      {
        invoke-command -computerName $node -scripts { gotoFolder; itk unpack,config } >> T:\RaveDeployte\deploye_id\node_name\log.txt
      }
      # Wait here
      
      foreach -parallel($node in $nodes)
      {
        invoke-command -computerName $node -scripts { gotoFolder; itk stop }
      }
      # Wait here
      
      foreach -parallel($node in $nodes)
      {
        invoke-command -computerName $node -scripts { gotoFolder; itk uninstall,install }
      }
      # Wait here
      
      foreach -parallel($node in $nodes)
      {
        invoke-command -computerName $node -scripts { gotoFolder; itk start }
      }
      # Wait here
      
      Exeucte-diag-level1
      
      }catch{
        
      }
      finally{
        
      }
    }
  } 
}
```
