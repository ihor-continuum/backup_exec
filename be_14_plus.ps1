# Set-ExecutionPolicy RemoteSigned
# $PSVersionTable.PSVersion
# enable Powershell ISE on windows 2008: https://social.technet.microsoft.com/wiki/contents/articles/30347.enable-powershell-ise-from-windows-server-2008-r2.aspx
# http://systemmanager.ru/bemcli.en/topics/get-bejobhistory.html
# BEMCLI .chm help: https://www.veritas.com/support/en_US/article.000116189

$DebugPreference = "Continue"
$ErrorActionPreference = "Stop"; #Make all errors terminating, or "Continue" to revert back

# TODO FIXME: this is a copy-paste from script for version "<14", reuse that one on scripts merge
function error_for_code($code, $desc) {
  $e = New-Object –TypeName PSObject
  $e | Add-Member -MemberType NoteProperty -Name "ErrorCode" -Value $code
  $e | Add-Member -MemberType NoteProperty -Name "ErrorDescription" -Value $desc
  return $e
}

# TODO FIXME: this one should be reused from "<14" script as well
function format_errors_as_xml($errors) {
  return ($errors | ConvertTo-Xml -NoTypeInformation -As Stream)
}

function format_bemcli_job_error($job) {
    $object = New-Object –TypeName PSObject

    $object | Add-Member –MemberType NoteProperty –Name ServerName –Value $job.BackupExecServerName
    $object | Add-Member –MemberType NoteProperty –Name JobName –Value $job.Name
    $object | Add-Member –MemberType NoteProperty –Name JobType –Value $job.JobType
    $object | Add-Member –MemberType NoteProperty –Name StartTime –Value $job.StartTime
    $object | Add-Member –MemberType NoteProperty –Name LogName –Value $job.JobLogFilePath

    $object | Add-Member –MemberType NoteProperty –Name EndTime –Value $job.EndTime
    $object | Add-Member –MemberType NoteProperty –Name Engine_Completion_Status –Value $job.JobStatus

    $object | Add-Member –MemberType NoteProperty –Name ErrorCode –Value $job.ErrorCode
    $object | Add-Member –MemberType NoteProperty –Name ErrorDescription –Value $job.ErrorMessage
    $object | Add-Member –MemberType NoteProperty –Name ErrorCategory –Value $job.ErrorCategory

    $object | Add-Member –MemberType NoteProperty –Name TimeTaken_sec –Value $job.ElapsedTime.Seconds
    $object | Add-Member –MemberType NoteProperty –Name TimeTaken_HMS –Value $job.ElapsedTime

    return $object
}

if(Get-Module -List BEMCLI) {
  Write-Debug "BEMCLI modules found"
  Import-Module BEMCLI
  
  $errors = @()

  # TODO FIXME: change EndTime comparison to $last_script_run
  try { # BE Server service may be down
    $job_history = Get-BEJobHistory | Where-Object {($_.JobType -eq "Backup")} | Where-Object {$_.EndTime -gt (Get-date).AddDays(-1)} | sort EndTime -Descending
  } catch {
    Write-Output (format_errors_as_xml (error_for_code -6 "BE Serve service is down"))
    exit -6
  }
  
  # TODO FIXME substitute with proper $last_run_time for '-After'
  $warnings = Get-EventLog -LogName Application -Source 'Backup Exec' -EntryType Warning -After (Get-date).AddHours(-1)
  
  foreach ($w in $warnings) {
    Write-Debug $w
	$fe = New-Object -TypeName PSObject
	$fe | Add-Member -MemberType NoteProperty -Name StartTime -Value $w.TimeGenerated
	$fe | Add-Member -MemberType NoteProperty -Name ServerName -Value $w.MachineName
	$fe | Add-Member -MemberType NoteProperty -Name EventID -Value $w.EventID
	$fe | Add-Member -MemberType NoteProperty -Name Message -Value $w.Message

	$errors += $fe
  }

  foreach ($j in $job_history) {
    $OkStatus =  @('Succeeded', 'Completed', 'Active', 'Ready', 'Scheduled', 'SucceededWithExceptions')
    
    if ($OkStatus -contains $j.JobStatus) { continue }
    
    $errors += format_bemcli_job_error $j
  }
  
  Write-Output $errors
  
  exit 0
}

Write-Debug "BE version less that 14, don't have PowerShell CMDLets, proceed with BEMCMD"

