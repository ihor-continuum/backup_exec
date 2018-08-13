if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") {
	if ($myInvocation.Line) {
        	&"$env:WINDIR\sysnative\windowspowershell\v1.0\powershell.exe" -NonInteractive -NoProfile $myInvocation.Line
    	}else{
        	&"$env:WINDIR\sysnative\windowspowershell\v1.0\powershell.exe" -NonInteractive -NoProfile -file "$($myInvocation.InvocationName)" $args
  	}
	exit $lastexitcode
}

# used for formatting errors to xml
function formatErrorsAsXml($errors) {
	return ($errors | ConvertTo-Xml -NoTypeInformation -As Stream)
}

# return formatted error for exiting script when no jobs info is available
function errorForCode($code, $desc) {
	$e = New-Object -TypeName PSObject
	$e | Add-Member -MemberType NoteProperty -Name "ErrorCode" -Value $code
	$e | Add-Member -MemberType NoteProperty -Name "ErrorDescription" -Value $desc
	return $e
}

# used for getting bex file info
function getBexLogStatus($jobName, $logFilePath){
	Try {
		[xml]$log = Get-Content -Path $logFilePath
		return $log
	} Catch {
		return
	}
}

# converts plaintext BEX log format like "Job ended: Sunday, June 24, 2018 at 8:00:14 AM\n" into DateTime object
function parseJobTime($jobTime) {
	if (!($jobTime)){
		return
	}
	$dateTmpl = "dddd, MMMM d, yyyy a\t h:mm:ss tt"
	if ($jobTime.StartsWith("Job ended:")) {
		$dateStr = $jobTime.TrimStart("Job ended: ").Trim()
	} elseif ($jobTime.StartsWith("Job started:")) {
		$dateStr = $jobTime.TrimStart("Job started: ").Trim()
	} else {
		return 
	}
	return [DateTime]::ParseExact($dateStr, $dateTmpl, $null)
}

# search through Event Log to find an error
# since expected run time
function getEventLogError($jobName, $jobStartTime){

	$jobStartTime = Get-Date -Date $jobStartTime
	Try {
		$eventLogErrors = Get-EventLog -LogName Application -Source "Backup Exec" -EntryType Error,Warning -After $($jobStartTime - (New-Timespan -Seconds 1))
	} Catch {
		return
	}

	if (($jobName.Split([Environment]::NewLine)[0]) -match '\(' -or ($jobName.Split([Environment]::NewLine)[0]) -match '\)'){	
		$jobName = $jobName.Split([Environment]::NewLine)[0].Replace("(", "\(")
		$jobName = $jobName.Split([Environment]::NewLine)[0].Replace(")", "\)")
	}
	
	$eventLogErrors = $eventLogErrors | Sort-Object -Property @{Expression = "TimeGenerated"; Descending = $False}

	$jobName = $jobName.Split([Environment]::NewLine)[0]
	$jobName = """$($jobName)"""

	if ($eventLogErrors.Length -gt 0){
	for ($i=0; $i -lt $eventLogErrors.Length; $i++){
		#write-host $jobName
		#write-host $jobStartTime
		if ($eventLogErrors[$i].Message -Match $jobName){
			return $eventLogErrors[$i]
		}
		continue
	}
	} else {
	    if ($eventLogErrors.Message -Match $jobName){
			return $eventLogErrors
	    }
	    return	
	}
}

function defaultFormattedError(){
	$formattedError = New-Object -TypeName PSObject
	$formattedError | Add-Member -MemberType NoteProperty -Name ResourceType -Value "Backup"
	$formattedError | Add-Member -MemberType NoteProperty -Name ResSubType -Value "Veritas"
	$formattedError | Add-Member -MemberType NoteProperty -Name MndTime -Value $dateNow
	$formattedError | Add-Member -MemberType NoteProperty -Name JobName -Value ""
	$formattedError | Add-Member -MemberType NoteProperty -Name JobStartTime -Value ""
	$formattedError | Add-Member -MemberType NoteProperty -Name LogFileName -Value ""
	$formattedError | Add-Member -MemberType NoteProperty -Name JobType -Value ""
	$formattedError | Add-Member -MemberType NoteProperty -Name CompleteStatusCode -Value ""
	$formattedError | Add-Member -MemberType NoteProperty -Name JobStatus -Value ""
	$formattedError | Add-Member -MemberType NoteProperty -Name ServerName -Value ""
	$formattedError | Add-Member -MemberType NoteProperty -Name JobEndTime -Value ""
	$formattedError | Add-Member -MemberType NoteProperty -Name TimeTakenInSec -Value "0"
	$formattedError | Add-Member -MemberType NoteProperty -Name TimeTakenInHHMMSS -Value ""
	$formattedError | Add-Member -MemberType NoteProperty -Name ErrorCode -Value ""
	$formattedError | Add-Member -MemberType NoteProperty -Name ErrorDescription -Value ""
	$formattedError | Add-Member -MemberType NoteProperty -Name ErrorCategory -Value ""
	return $formattedError
}

# used for retrieving all information by specific
# history job ID and collecting information about
# failed jobs
function getHistoryJobStatus($job){

	$jobInfo = executeBEMCMD("$($specificJobHistory)$($job.ID)")
	
	# check for generated log file
	# if it is not successes - add to error
	$logFilePath = ""
	$jobInfo | Out-String | Select-String -Pattern "LOGFILE:\s+(.+.xml)" | forEach {$_.matches | forEach { $logFilePath = $_.Groups[1].Value}}
	
	$log = getBexLogStatus $job.Name $logFilePath
	
	$formattedError = defaultFormattedError
	$formattedError.JobStartTime = $(Get-Date ($job.ActualStartTime))

	$endDate = ""

	if ($log){
		if ($log.joblog.footer.engine_completion_status.Trim() -eq "Job completion status: Successful") {
			return
		}

		$jobStatusCode = ""
		$jobStatus = ""
		$jobInfo | Out-String | Select-String -Pattern "JOB STATUS:+\s+([0-9])\s[(](.+)[)]" -AllMatches | forEach {$_.matches | forEach { $jobStatusCode = $_.Groups[1].Value; $jobStatus = $_.Groups[2].Value}}
		
		$startDate = (parseJobTime($log.joblog.header.start_time))
		$endDate = (parseJobTime($log.joblog.footer.end_time))
		$took = ($endDate - $startDate)

		$formattedError.LogFileName = $log.joblog.header.log_name.Split(":")[1].Trim()
		$formattedError.JobType = $log.joblog.header.type.Split(":")[1].Trim()
		$formattedError.ServerName = $log.joblog.header.server.Split(":")[1].Trim()
		$formattedError.JobEndTime = $endDate
		$formattedError.CompleteStatusCode = $jobStatusCode
		$formattedError.JobStatus = $jobStatus
		$formattedError.TimeTakenInSec = $took.TotalSeconds
		$formattedError.TimeTakenInHHMMSS = ("{0:hh:mm:ss}" -f $took.toString())
		
	}

	if ($endDate){
		$e = getEventLogError $job.Name $($endDate)
	} else {
		$e = getEventLogError $job.Name $(Get-Date -Date $job.ActualStartTime)
	}
	if ($e){
		$took = $e.TimeGenerated - $(Get-Date $job.ActualStartTime)
		
		$formattedError.ServerName = $e.MachineName
		$formattedError.JobEndTime = $e.TimeGenerated
		$formattedError.ErrorCode = $e.EventID
		$formattedError.ErrorDescription = $e.Message
		$formattedError.ErrorCategory = $e.CategoryNumber
		$formattedError.TimeTakenInSec = $took.TotalSeconds
		$formattedError.TimeTakenInHHMMSS = ("{0:hh:mm:ss}" -f $took.toString())
		
		$errors.Add($formattedError) | Out-Null
		return
	}
	continue
}

# used for validating history jobs by start time
# and previous execution of script 
function isInTimeRange($startTime){
	if (($(Get-Date $startTime) -gt $lastRunDate) -and (($(Get-Date $startTime) -lt $dateNow))){
		return $startTime
	}
	return
}

# used for getting history jobs executions
function getHistoryJobsByJobID($jobID){
	$getJobHistoryInfo = executeBEMCMD("$($allJobsHistoryInfo)$($jobID) -h")
	$jobs = @() 

	$jobIDs = @()
	$jobNames = @()
	$jobStartTimes = @()

	$getJobHistoryInfo | Out-String | Select-String -Pattern "JOB ID:+\s+({\w+-\w+-\w+-\w+-\w+})" -AllMatches | forEach {$_.matches | forEach { $jobIDs += $_.Groups[1].Value}}
	$getJobHistoryInfo | Out-String | Select-String -Pattern "JOB NAME:+\s+(.+)" -AllMatches | forEach {$_.matches | forEach { $jobNames += $_.Groups[1].Value}}
	$getJobHistoryInfo | Out-String | Select-String -Pattern "JOB ACTUAL START TIME:+\s+(.+[0-9])" -AllMatches | forEach {$_.matches | forEach { $jobStartTimes += $_.Groups[1].Value}}

	for ($i=0; $i -lt $jobIDs.Count; $i++){
		$jobs += @{"ID"=$jobIDs[$i];"Name"=$jobNames[$i];"ActualStartTime"=$jobStartTimes[$i]}
	}

	return $jobs
}

# used for getting all jobs info
function getJobs($bemcmdInfo){
	$jobIDs = @()
	
	$bemcmdInfo | Out-String | Select-String -Pattern "JOB ID:+\s+({\w+-\w+-\w+-\w+-\w+})" -AllMatches | forEach {$_.matches | forEach { $jobIDs += $_.Groups[1].Value}}

	forEach ($jobID in $jobIDs){
		$parsedHistoryJobs = getHistoryJobsByJobID($jobID)

		# get all executions history by specific job ID
		if ($parsedHistoryJobs){
			forEach ($job in $parsedHistoryJobs){
				if (!(isInTimeRange("$($job.ActualStartTime)"))){
					continue
				}
				getHistoryJobStatus $job
			}
		}
	continue
	}
}	

# used for calling bemcmd.exe with specific arguments
function executeBEMCMD($arguments){
	$bemcmd = New-Object System.Diagnostics.ProcessStartInfo 
	$bemcmd.FileName = $cmdPATH 
	$bemcmd.Arguments = $arguments
	$bemcmd.UseShellExecute = $false 
	$bemcmd.CreateNoWindow = $true 
	$bemcmd.RedirectStandardOutput = $true 
	$bemcmd.RedirectStandardError = $true

	$process= New-Object System.Diagnostics.Process 
	$process.StartInfo = $bemcmd
	$process.Start() | Out-Null

	$res = $process.StandardOutput.ReadToEnd()
	return $res
}

# used for getting last script execution
function getLastRunDate(){
	# default check interval is the last 2 hours, extend to maximum of 24h if script wasn't run
	Try {
	  $lastRunDate = [DateTime]::Parse((cat $lastRunFile))
	} Catch {
	  date > $lastRunFile
	  return $dateNow - (New-TimeSpan -Hours 2)
	}
	$elapsed = $dateNow - $lastRunDate
	if ($elapsed.TotalHours -gt 24 ){
		return $dateNow - (New-TimeSpan -Hours 24)
	}
	if ($elapsed.TotalHours -gt 2 ){
		$lastRunDateInHours = Get-Date -Date $($lastRunDate) -UFormat %H
		return $dateNow - (New-TimeSpan -Hours $lastRunDateInHours)
	}
	# get at least 2h of previous data in case of recent script\machine crash
	if ($elapsed.TotalHours -lt 2 ){
		return $dateNow - (New-TimeSpan -Hours 2)
	}
	return $lastRunDate
}

# prepare single XML object for error
function errorObject($obj) {
	$object = New-Object -TypeName PSObject

	$object | Add-Member -MemberType NoteProperty -Name ResourceType -Value "Backup"
	$object | Add-Member -MemberType NoteProperty -Name ResSubType -Value "Veritas"
	$object | Add-Member -MemberType NoteProperty -Name MndTime -Value $dateNow

	$object | Add-Member -MemberType NoteProperty -Name ServerName -Value $obj.BackupExecServerName
	$object | Add-Member -MemberType NoteProperty -Name JobName -Value $obj.Name
	$object | Add-Member -MemberType NoteProperty -Name JobType -Value $obj.JobType
	$object | Add-Member -MemberType NoteProperty -Name StartTime -Value $obj.StartTime
	$object | Add-Member -MemberType NoteProperty -Name LogFileName -Value $obj.JobLogFilePath

	$object | Add-Member -MemberType NoteProperty -Name EndTime -Value $obj.EndTime
	$object | Add-Member -MemberType NoteProperty -Name CompleteStatusCode -Value $obj.JobStatus

	$object | Add-Member -MemberType NoteProperty -Name ErrorCode -Value $obj.ErrorCode
	$object | Add-Member -MemberType NoteProperty -Name ErrorDescription -Value $obj.ErrorMessage
	$object | Add-Member -MemberType NoteProperty -Name ErrorCategory -Value $obj.ErrorCategory

	$object | Add-Member -MemberType NoteProperty -Name TimeTakenInSec -Value $obj.ElapsedTime.Seconds
	$object | Add-Member -MemberType NoteProperty -Name TimeTakenInHHMMSS -Value $obj.ElapsedTime
	return $object
}

$DebugPreference = "Continue"
$ErrorActionPreference = "Stop"; #Make all errors terminating, or "Continue" to revert back

# ================= start main program logic ==============

# BEMCMD arguments
$allJobsInfo = "-o506 -d1"
$allJobsHistoryInfo = "-o21 -i"
$specificJobHistory = "-o21 -hi:"
$actualJobStatus = "-o16 -i"

$registryMiscPath = "HKEY_LOCAL_MACHINE\SOFTWARE\Symantec\Backup Exec For Windows\Backup Exec\Engine\Misc"
$reg = Get-ItemProperty -Path Registry::$registryMiscPath
$beDir = Split-Path -Path $reg.'Job Log Path'

$lastRunFile = "../temp/be_status.start"
$dateNow = Get-Date
$legacyCMD = "bemcmd.exe"

$cmdPATH = Join-Path $beDir $legacyCMD
$errors = New-Object System.Collections.ArrayList

# validate existing of $lastRunFile
# if not - create
if((Test-Path ..\temp\) -eq $False){
	New-Item -Path ..\ -Name temp -ItemType "directory" | Out-Null
}

if((Test-Path $lastRunFile) -eq $False){
	New-Item -Path ..\temp -Name $lastRunFile -ItemType File | Out-Null
}

# get last run date to determine the period of data to grab from logs and schedule
$lastRunDate = getLastRunDate
if ($args[0]){
	$lastRunDate = $args[0]
}

date > $lastRunFile

# this is a 14+ version block
if(Get-Module -List BEMCLI) {
	Write-Debug "BEMCLI modules found"
	Import-Module BEMCLI

	$errors = @()

	try { # BE Server service may be down
		$job_history = Get-BEJobHistory | Where-Object {($_.JobType -eq "Backup")} | Where-Object {$_.EndTime -gt $lastRunDate} | sort EndTime -Descending
	} catch {
		Write-Output (formatErrorsAsXml (errorForCode -6 "BE Serve service is down"))
		exit -6
	}

	$fe = defaultFormattedError

	$warnings = Get-EventLog -LogName Application -Source 'Backup Exec' -EntryType Error,Warning -After $lastRunDate -ErrorAction SilentlyContinue
	
	if ($warnings) {
        foreach ($w in $warnings) {
			$fe.JobStartTime = $w.TimeGenerated
			$fe.ServerName = $w.MachineName
			$fe.ErrorCode = $w.EventID
			$fe.ErrorDescription = $w.Message

			$errors += $fe
	   }
    }

    if ($job_history) {
		foreach ($j in $job_history) {
			$OkStatus =  @('Succeeded', 'Completed', 'Active', 'Ready', 'Scheduled', 'SucceededWithExceptions')

			if ($OkStatus -contains $j.JobStatus) { continue }

			$errors += errorObject $j
		}
    }
	Write-Output (formatErrorsAsXml $errors)

	exit 0
} # end of 14+ version block

if (!(Test-Path $cmdPATH)){
	$desc = "BE cli binary not found: $cmdPATH"

	Write-Output (formatErrorsAsXml (errorForCode -2 $desc))
	exit -2
}

getJobs(executeBEMCMD($allJOBsInfo))

Write-Output (formatErrorsAsXml $errors)
exit 0
