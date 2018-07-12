Backup Exec job status monitoring and reporting script

https://continuum.atlassian.net/browse/OSS-10560
https://continuum.atlassian.net/browse/RMM-28464

Script overview:

Prerequisites:
 - Get list of jobs and job schedules
   - bemcmd.exe for BE version up and including 13
   - load BE powershell extension and use Get-BEJobs for 13+
 - Get list of Event Log errors for the last 2 hours

Script Logic:
- return predefined error template if BE service is down and schedule can't be retrieved

- for each event log error:
  - if event log is in clauses 1-5(job executed, but with erorrs) - append to error list

- for each job with scheduled time in the last 2 hours:
  - check BEX log by job id in the last 2 hours
  - append to error list if there's no BEX log for the job

- return error list

Error list and generation conditions:
    1. The Backup-to-Disk device is out of free space. (Veritas)
      Event Log id 58058
       
    2. Backup Exec - Media error : Insert media into the drive (Veritas)
      Event Log id 58061
      
    3. Please remove the media from the drive and Respond OK.(Veritas)
      Event Log id 58063
      
    4. Backup Exec - Backup failed due to an error (Veritas)
      Event Log id 34113
      
    5. Backup Exec - Insert media into the slots (Veritas)
      Event Log id 58064
    
    6. Veritas backup job failure
      Event Log id 34113
      
    7. Veritas daily backup has failed to execute
      a) Job with "NEXT RUNTIME" in the past 2h
      b) No BEX file generated
      
    8. Veritas weekly backup has failed to execute
      a) Job with "FIRST/SECOND/THIRD/FOURTH/LAST WEEK" schedule in the last 2h
      b) No BEX file generated
      
    9) Veritas backup job taking long time to complete
      ???
      
    10) Veritas backup job failed to execute (auto-sense)
      ???
      
    11) Veritas monthly backup has failed to execute
      a) Job with "DAYS OF MONTH" schedule in the last 2h
      b) No BEX file generated 
