# used for getting actual job status
function getActualJobStatus($mainJobID){
    $status = ""
    executeBEMCMD("$($actualJobStatus)$($mainJobID)") | Out-String | Select-String -Pattern "JOB STATUS:+\s+\w+\s+\((\w+)\)" | forEach {$_.matches | forEach { $status = $_.Groups[1].Value}}
	if ($status -eq "Running"){
		return $status
	}
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
	} Catch {
		return
	}
	$logJobName = $log.joblog.header.name.Trim()
	if (!($log -and $log.joblog.footer.engine_completion_status.Trim() -eq "Job completion status: Successful")) {
		return $log
	}
}

# converts plaintext BEX log format like "Job ended: Sunday, June 24, 2018 at 8:00:14 AM\n" into DateTime object
function parseJobTime($jobTime) {
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
	Try {
		$eventLogErrors = Get-EventLog -LogName Application -Source "Backup Exec" -EntryType Error,Warning -After $jobStartTime
	} Catch {
		return
	}
	foreach ($e in $eventLogErrors) {
		if ($e.Message | Select-String -Pattern $jobName.Split([Environment]::NewLine)[0]){
			return $e
		}
	}
}

# used for retrieving all information by specific
# history job ID and collecting information about
# failed jobs
function getHistoryJobStatus($job, $mainJobID){

	$jobInfo = executeBEMCMD("$($specificJobHistory)$($job.ID) -h")
	if ($jobInfo | Out-String | Select-String -Pattern "RETURN VALUE: -1"){	
		
		# check for generated event logs
		# if presents add to errors
		$e = getEventLogError $job.Name $job.ActualStartTime
			
		if ($e){		
			$formattedError = New-Object -TypeName PSObject
			$formattedError | Add-Member -MemberType NoteProperty -Name "JobName" -Value $job.Name
			$formattedError | Add-Member -MemberType NoteProperty -Name "StartTime" -Value $e.TimeGenerated
			$formattedError | Add-Member -MemberType NoteProperty -Name "ServerName" -Value $e.MachineName
			$formattedError | Add-Member -MemberType NoteProperty -Name "EventID" -Value $e.EventID
			$formattedError | Add-Member -MemberType NoteProperty -Name "Message" -Value $e.Message

			$errors.Add($formattedError) | Out-Null
			return
		}
		
		# check for actual status of job
		# if it is equal to Running escape it
		if (!(getActualJobStatus $mainJobID)){
			
			$formattedError = New-Object -TypeName PSObject
			$formattedError | Add-Member -MemberType NoteProperty -Name "JobName" -Value $job.Name
			$formattedError | Add-Member -MemberType NoteProperty -Name "StartTime" -Value $job.ActualStartTime
			$formattedError | Add-Member -MemberType NoteProperty -Name "ErrorCode" -Value 24
			$formattedError | Add-Member -MemberType NoteProperty -Name "ErrorDescription" -Value "Job was not started according to schedule"
			
			$errors.Add($formattedError) | Out-Null
			return
		}
	}
		
	# check for generated log file
	# if it is not successes - add to error
	$logFilePath = ""
	$jobInfo | Out-String | Select-String -Pattern "LOGFILE:\s+(.+.xml)" | forEach {$_.matches | forEach { $logFilePath = $_.Groups[1].Value}}
	$log = getBexLogStatus $job.Name $logFilePath

	if ($log){
		$bexError = errorObject $log
		$errors.Add($bexError) | Out-Null
		return
	}
	
	return
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
				getHistoryJobStatus $job $jobID
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
	  $lastRunDate = $dateNow - (New-TimeSpan -Hours 2)
	}
	$elapsed = $dateNow - $lastRunDate
	if ($elapsed.TotalHours -gt 24 ){
		return $dateNow - (New-TimeSpan -Hours 24)
	}
	if ($elapsed.TotalHours -gt 2 ){
		return $dateNow - (New-TimeSpan -Hours 24)
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

	if ($obj.gettype() -eq [System.Xml.XmlDocument]){
		$startDate = (parseJobTime($obj.joblog.header.start_time))
		$endDate = (parseJobTime($obj.joblog.footer.end_time))

		$object | Add-Member -MemberType NoteProperty -Name ServerName -Value $obj.joblog.header.server.Trim()
		$object | Add-Member -MemberType NoteProperty -Name JobName -Value $obj.joblog.header.name.Trim()
		$object | Add-Member -MemberType NoteProperty -Name JobType -Value $obj.joblog.header.type.Trim()
		$object | Add-Member -MemberType NoteProperty -Name StartTime -Value $startDate
		$object | Add-Member -MemberType NoteProperty -Name LogName -Value $obj.joblog.header.log_name.Trim()

		$object | Add-Member -MemberType NoteProperty -Name EndTime -Value $endDate
		$object | Add-Member -MemberType NoteProperty -Name EngineCompletionStatus -Value $obj.joblog.footer.engine_completion_status.Trim()

		$object | Add-Member -MemberType NoteProperty -Name ErrorCode -Value $obj.joblog.footer.CompleteStatus
		$object | Add-Member -MemberType NoteProperty -Name ErrorDescription -Value $obj.joblog.footer.AbortUserName
		$object | Add-Member -MemberType NoteProperty -Name ErrorCategory -Value $obj.joblog.footer.ErrorCategory

		$took = ($endDate - $startDate)

		$object | Add-Member -MemberType NoteProperty -Name TimeTaken_sec -Value $took.Seconds
		$object | Add-Member -MemberType NoteProperty -Name TimeTaken_HMS -Value ("{0:hh:mm:ss}" -f $took.toString())
	} else {
		$object | Add-Member -MemberType NoteProperty -Name ServerName -Value $obj.BackupExecServerName
		$object | Add-Member -MemberType NoteProperty -Name JobName -Value $obj.Name
		$object | Add-Member -MemberType NoteProperty -Name JobType -Value $obj.JobType
		$object | Add-Member -MemberType NoteProperty -Name StartTime -Value $obj.StartTime
		$object | Add-Member -MemberType NoteProperty -Name LogName -Value $obj.JobLogFilePath

		$object | Add-Member -MemberType NoteProperty -Name EndTime -Value $obj.EndTime
		$object | Add-Member -MemberType NoteProperty -Name EngineCompletionStatus -Value $obj.JobStatus

		$object | Add-Member -MemberType NoteProperty -Name ErrorCode -Value $obj.ErrorCode
		$object | Add-Member -MemberType NoteProperty -Name ErrorDescription -Value $obj.ErrorMessage
		$object | Add-Member -MemberType NoteProperty -Name ErrorCategory -Value $obj.ErrorCategory

		$object | Add-Member -MemberType NoteProperty -Name TimeTaken_sec -Value $obj.ElapsedTime.Seconds
		$object | Add-Member -MemberType NoteProperty -Name TimeTaken_HMS -Value $obj.ElapsedTime
	}
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

	$warnings = Get-EventLog -LogName Application -Source 'Backup Exec' -EntryType Warning -After $lastRunDate

	if ($warnings) {
        foreach ($w in $warnings) {
			$fe = New-Object -TypeName PSObject

			$fe | Add-Member -MemberType NoteProperty -Name ResourceType -Value "Backup"
			$fe | Add-Member -MemberType NoteProperty -Name ResSubType -Value "Veritas"
			$fe | Add-Member -MemberType NoteProperty -Name MndTime -Value $dateNow

			$fe | Add-Member -MemberType NoteProperty -Name StartTime -Value $w.TimeGenerated
			$fe | Add-Member -MemberType NoteProperty -Name ServerName -Value $w.MachineName
			$fe | Add-Member -MemberType NoteProperty -Name EventID -Value $w.EventID
			$fe | Add-Member -MemberType NoteProperty -Name Message -Value $w.Message

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