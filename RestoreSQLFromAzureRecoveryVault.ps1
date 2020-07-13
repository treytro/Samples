<#
.SYNOPSIS
    Restores a SQL backup stored in Azure Recovery Services vault to another SQL instance.

.DESCRIPTION
	This runbook demonstrates how to find the most recent full backup for a particular database
    and restore it to a SQL VM that has been registered with the vault.

    It has a dependency on Az.Accounts and Az.RecoveryServices powershell modules. These
    modules must be imported into the Automation account prior to execution.

.PARAMETER VaultName
    String name of the Azure Recovery Services Vault

.PARAMETER ResGroup
    String name of the Resource Group within which the vault resides

.PARAMETER SourceBackupServerFQDN
    String FQDN name of the server from which the SQL backup was taken, such as  agtestnode1.jintech.com

.PARAMETER BkupToRestore
    The String name of the backup item to restore

    For a default instance, the format is typically "sqldatabase;mssqlserver;<databasename>"

    Use Get-AzRecoveryServicesBackupItem in this manner to retrieve the list of possible items to restore for this parameter:
        $vault = Get-AzRecoveryServicesVault -ResourceGroupName "PureEnergy" -Name "TreyVault"
        Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -VaultId $vault.ID

.PARAMETER RestoreDestinationSrvFQDN

    String name of the destination VM.  Typically FQDN such as agtestnode2.jintech.com; but to be certain, use Get-AzRecoveryServicesBackupProtectableItem to list out SQL instances that are registered with the vault. If your target is not in the list, then the SQL instances needs to be registered with ARS Vault.

    $vault = Get-AzRecoveryServicesVault -ResourceGroupName "PureEnergy" -Name "TreyVault"
    Get-AzRecoveryServicesBackupProtectableItem -WorkloadType MSSQL -VaultId $vault.ID -ItemType SQLInstance

.PARAMETER RestoreDestinationInst
    String name of the destination SQL instance. It typically takes the format of "sqlinstance;mssqlserver" where mssqlserver is a default instance.
    Use Get-AzRecoveryServicesBackupProtectableItem as noted above to find the exact string for the instance.

.EXAMPLE

.NOTES
    AUTHOR: Trey Troegel
    LASTEDIT: July 13, 2020
#>

param
(
    [Parameter(Mandatory=$true)]
    [String] $VaultName,

    [Parameter(Mandatory=$true)]
    [String] $ResGroup,

    [Parameter(Mandatory=$true)]
    [String] $SourceBackupServerFQDN,

    [Parameter(Mandatory=$true)]
    [String] $BkupToRestore,

    [Parameter(Mandatory=$true)]
    [String] $RestoreDestinationSrvFQDN,

    [Parameter(Mandatory=$true)]
    [String] $RestoreDestinationInst

)

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave –Scope Process

Write-Verbose –Message ""
Write-Verbose –Message "------------------------ Authentication ------------------------"
Write-Verbose –Message "Logging into Azure ..."

$connection = Get-AutomationConnection -Name AzureRunAsConnection

while(!($connectionResult) -And ($logonAttempt -le 2))
{
    $LogonAttempt++
    # To connect to Azure Government use: Connect-AzAccount -Environment AzureUSGovernment
    $connectionResult =    Connect-AzAccount `
                               -ServicePrincipal `
                               -Tenant $connection.TenantID `
                               -ApplicationId $connection.ApplicationID `
                               -CertificateThumbprint $connection.CertificateThumbprint

    Start-Sleep -Seconds 30

}

Write-Verbose –Message ""
Write-Verbose –Message "Finding Azure Recovery Vault..."
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResGroup -Name $VaultName

<#
Use Get-AzRecoveryServicesBackupItem in the manner to below to find the exact "-Name" parameter of the database to be restored. This will also give you the sometimes elusive Container name that is used in other commands.

    $vault = Get-AzRecoveryServicesVault -ResourceGroupName "MyResGroup" -Name "MyVault"
    Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -VaultId $vault.ID

#>

Write-Verbose –Message ""
Write-Verbose –Message "------------------Finding a backup to be restored------------------"
Write-Verbose –Message "Finding backup items from $($SourceBackupServerFQDN)"
Write-Verbose –Message ""
# There can be multiple database backups with the same name, but from different source servers registered in with vault. A common scenario would be the SQL system databases (master, msdb etc.).
# Therefore, we need to filter Get-AzRecoveryServicesBackupItem by $SourceBackupServerFQDN in order to target the correct backup.
$bkpItem = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -Name $BkupToRestore -VaultId $vault.ID | Where-Object ServerName -eq $SourceBackupServerFQDN

$startDate = (Get-Date).AddDays(-14).ToUniversalTime()
$endDate = (Get-Date).ToUniversalTime()
$RecPointList = Get-AzRecoveryServicesBackupRecoveryPoint -Item $bkpItem -VaultId $vault.ID -StartDate $startdate -EndDate $endDate

# Next, narrow down the list of recovery points to the most recent Full backup by sorting the list Descending and taking the top 1 record
$RecPoint = $RecPointList | Where-Object RecoveryPointType -eq "Full" | Sort-Object -Descending -Property RecoveryPointTime | Select-Object -First 1

<#
To get a list of potential targets, use Get-AzRecoveryServicesBackupProtectableItem to list out SQL instances that are registered with the vault. If your target is not in the list, then the SQL instance needs to be registered with ARS Vault.
You'll want to pull BOTH the -Name and -ServerName parameters from the output of Get-AzRecoveryServicesBackupProtectableItem

    $vault = Get-AzRecoveryServicesVault -ResourceGroupName "MyResGroup" -Name "MyVault"
    Get-AzRecoveryServicesBackupProtectableItem -WorkloadType MSSQL -VaultId $vault.ID -ItemType SQLInstance
#>
$NewDestinationInstance = Get-AzRecoveryServicesBackupProtectableItem -WorkloadType MSSQL -ItemType SQLInstance -Name $RestoreDestinationInst -ServerName $RestoreDestinationSrvFQDN -VaultId $vault.ID

<#
Use Set/Get-AzRecoveryServicesBackupWorkloadRecoveryConfig to adjust restore options such as Restored DB Name, alternate mdf/ldf restore paths, and whether to overwrite an existing database.
#>
$InstanceWithFullConfig = Get-AzRecoveryServicesBackupWorkloadRecoveryConfig -RecoveryPoint $RecPoint -TargetItem $NewDestinationInstance -AlternateWorkloadRestore -VaultId $vault.ID

Write-Verbose –Message ""
Write-Verbose –Message "------------------Restoring------------------"
Write-Verbose –Message "Restoring $($BkupToRestore) to $($RestoreDestinationSrvFQDN)"
Write-Verbose –Message ""
# This is the command that actually performs the restore.
Restore-AzRecoveryServicesBackupItem -WLRecoveryConfig $InstanceWithFullConfig -VaultId $vault.ID
