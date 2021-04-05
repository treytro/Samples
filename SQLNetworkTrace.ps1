#Requires -RunAsAdministrator

function SQLConnectionTrace{

<#
.SYNOPSIS
    This will take a network trace when connecting to a SQL instance or AG Listener.
    The result will be an etl and cab file in the logPath destination.
    
.DESCRIPTION
    The goal of this function is to minimize the network trace size. The script will start the network trace 
    (netsh trace start), and immediately try to connect with System.Data.SqlClient, then  
    stop the traces as soon as it fails or succeeds.
    It should be run from the client system by someone that is an Admin.
    The default is a single sided client network trace, unless TraceType 'TwoSided' is specified.
    For a two sided trace to work, you will need to be an Admin on both client and the SQL system 
    and a valid path that exists on both systems should be provided.


.PARAMETER logPath
    The path where the CAB and ETL files will be written. This need to exist on both systems, 
    so the C: drive may be a good choice.

.PARAMETER sqlInstanceName
    The SQL instance name. If using an AG Listener, then specify the listener name instead.

.PARAMETER remoteSQLHostName
    If connecting to a default SQL instance, then this will be the same as the sqlInstanceName.
    However, if connecting to a named instance or listener, then this will be the hostname of the SQL system.

.PARAMETER TraceType
    ClientOnly (default) means the netsh trace will only be run on the client trying to connect to SQL.
    TwoSided means that "netsh trace start" will be executed on both systems, and a resulting .etl and .cab file 
        will be written to the logPath on each system.

.EXAMPLE
     TwoSidedSQLNetworkTrace -logPath 'C:\temp\' -sqlInstanceName CMServer1

.EXAMPLE
     TwoSidedSQLNetworkTrace -logPath 'F:\temp\' -sqlInstanceName AGListener -remoteSQLHostName WinNode2 -TraceType TwoSided

.NOTES
    Author:  Trey Troegel
    Recommendations:
    On both systems, force a time synchronization using: W32tm /resync /force 
    If troubleshooting Kerberos, you may want to do a KLIST Purge first


#>
 [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$logPath,
        [Parameter(Mandatory=$true)]
        [string]$sqlInstanceName,
        [Parameter(Mandatory=$false)]
        [string]$remoteSQLHostName,
        [Parameter(Mandatory=$false)]
        [ValidateSet('ClientOnly', 'TwoSided')]
        [string]$TraceType='ClientOnly'
    )

$sessions = $null
$netshResults = $null
$clientHostName = $env:computername


if((Test-Path -Path $logPath -PathType ‘Container’) -ne $true){
    Write-Host 'Provide a valid logPath value where the network trace file can be written. For a two sided trace, the path needs to exist on both systems.' -ForegroundColor Red
    exit
}

if($TraceType -eq 'TwoSided'){
    if($null -eq $remoteSQLHostName){
    Write-Host 'Enter the hostname of the remote SQL system for a two sided network trace.' -ForegroundColor Red
    exit
    }

    $sessions = New-PSSession -ComputerName $clientHostName,$remoteSQLHostName
}
else
    {$sessions = New-PSSession -ComputerName $clientHostName}

$connectionResultsFile = Join-Path -Path $logPath -ChildPath 'ConnectionResult.txt'

'Client Hostname: ' + $env:computername | Tee-Object -FilePath $connectionResultsFile
'Logon server is ' + $env:LOGONSERVER | Tee-Object -Append -FilePath $connectionResultsFile
'The Process ID of this process is ' + $PID | Tee-Object -Append -FilePath $connectionResultsFile

$networkTraceFile =   Join-Path -Path $logPath -ChildPath 'Network_Trace.etl'
$netshCommand =  'netsh trace start capture=yes tracefile=' + $networkTraceFile + ' filemode=circular overwrite=yes maxsize=1024'
$netshScriptBlock = [Scriptblock]::Create($netshCommand)
$netshResults = Invoke-Command -Session $sessions -ScriptBlock $netshScriptBlock -AsJob

$netshResults | Wait-Job

# Start-Sleep -s 2

$sqlConn = New-Object System.Data.SqlClient.SqlConnection
$sqlConn.ConnectionString = 'Server=tcp:' + $sqlInstanceName + ';Integrated Security=true;Initial Catalog=master;Application Name=Powershell Connection Test'

'Starting SQL Connection test on...' | Tee-Object -Append -FilePath $connectionResultsFile
Get-Date -Format "dddd MM/dd/yyyy HH:mm:ss K" | Tee-Object -Append -FilePath $connectionResultsFile

#$doneSql = Invoke-Command -ScriptBlock {$sqlConn.Open()} *>> $connectionResultsFile

try{
    $sqlConn.Open()
}
catch [Exception]
{
    $_.Exception|format-list -force | Tee-Object -Append -FilePath $connectionResultsFile
}


if($sqlConn.State -eq 'Open'){
    'Connection SUCCEEDED. The connection state is ' + $sqlConn.State | Tee-Object -Append -FilePath $connectionResultsFile
    
    }
else
{
    Write-Host 'Connection FAILED. The connection state is' $sqlConn.State -ForegroundColor Red
    }


Write-Host 'Cleaning up and closing any open connections...'

# sleep for a couple of seconds before closing the connection
Start-Sleep -s 2

$sqlConn.Close()

Write-Host 'The connection state is' $sqlConn.State
#Start-Sleep -s 2

'Stopping network trace...' | Tee-Object -Append -FilePath $connectionResultsFile

$networkTracesStopped = Invoke-Command -Session $sessions -ScriptBlock {netsh trace stop} -AsJob

$networkTracesStopped | Wait-Job

'Network trace(s) stopped: ' + $(Get-Date -Format "dddd MM/dd/yyyy HH:mm:ss K") | Tee-Object -Append -FilePath $connectionResultsFile

'Writing ipconfig information of local system to ' + $connectionResultsFile | Tee-Object -Append -FilePath $connectionResultsFile
ipconfig /all *>> $connectionResultsFile
}

# SQLConnectionTrace -logPath 'C:\temp' -sqlInstanceName AGNode3 -remoteSQLHostName AGNode3 -TraceType TwoSided
SQLConnectionTrace -logPath 'C:\temp' -sqlInstanceName AGNode3