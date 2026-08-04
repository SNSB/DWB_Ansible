/*
  Idempotent setup: creates (or leaves alone if already present) a SQL Server
  Agent job that runs a full backup of every user database, every day at
  00:15, writing .bak files to /var/opt/mssql/backup (mounted from the host),
  then prunes old backups so only the 3 newest full backups per database
  are kept.
*/
USE msdb;
GO

-- Pruning needs to delete individual files, which T-SQL can't do on its own,
-- so xp_cmdshell is enabled here (only, and specifically, for this job's use).
IF NOT EXISTS (
    SELECT 1 FROM sys.configurations
    WHERE name = 'xp_cmdshell' AND CAST(value_in_use AS INT) = 1
)
BEGIN
    EXEC sp_configure 'show advanced options', 1;
    RECONFIGURE;
    EXEC sp_configure 'xp_cmdshell', 1;
    RECONFIGURE;
    PRINT 'xp_cmdshell enabled (required for backup pruning).';
END
GO

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'Daily Full Backup')
BEGIN
    EXEC msdb.dbo.sp_add_job
        @job_name        = N'Daily Full Backup',
        @enabled         = 1,
        @description     = N'Full backup of all user databases, daily at 00:15, keeping the 3 newest backups per database',
        @owner_login_name = N'$(AdminLogin)';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name  = N'Daily Full Backup',
        @step_name = N'Backup all user databases',
        @subsystem = N'TSQL',
        @database_name = N'master',
        @on_success_action = 3,  -- go to next step
        @on_fail_action    = 3,  -- still attempt pruning even if a backup fails
        @command   = N'
DECLARE @name     NVARCHAR(256);
DECLARE @path     NVARCHAR(512) = N''/var/opt/mssql/backup/'';
DECLARE @fileName NVARCHAR(512);
DECLARE @stamp    NVARCHAR(20)  = REPLACE(REPLACE(CONVERT(NVARCHAR(19), GETDATE(), 120), '':'', ''-''), '' '', ''_'');

DECLARE db_cursor CURSOR FOR
    SELECT name FROM sys.databases
    WHERE name NOT IN (N''master'', N''model'', N''msdb'', N''tempdb'')
      AND state = 0;  -- ONLINE only

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @name;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @fileName = @path + @name + N''_FULL_'' + @stamp + N''.bak'';
    BACKUP DATABASE @name TO DISK = @fileName WITH INIT, COMPRESSION, CHECKSUM;
    FETCH NEXT FROM db_cursor INTO @name;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;
';

    EXEC msdb.dbo.sp_add_jobstep
        @job_name  = N'Daily Full Backup',
        @step_name = N'Prune old backups',
        @subsystem = N'TSQL',
        @database_name = N'master',
        @command   = N'
DECLARE @name      NVARCHAR(256);
DECLARE @path      NVARCHAR(512) = N''/var/opt/mssql/backup'';
DECLARE @keepCount INT = 3;
DECLARE @cmd       NVARCHAR(1000);

DECLARE db_cursor CURSOR FOR
    SELECT name FROM sys.databases
    WHERE name NOT IN (N''master'', N''model'', N''msdb'', N''tempdb'')
      AND state = 0;  -- ONLINE only

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @name;

WHILE @@FETCH_STATUS = 0
BEGIN
    -- List that database''s .bak files newest-first, skip the first N (keep them),
    -- delete the rest. "_FULL_" is the literal separator used when naming files.
    SET @cmd = N''ls -1t "'' + @path + N''/'' + @name + N''_FULL_"*.bak 2>/dev/null | tail -n +'' 
               + CAST(@keepCount + 1 AS NVARCHAR(10)) + N'' | xargs -r rm --'';
    EXEC master..xp_cmdshell @cmd;
    FETCH NEXT FROM db_cursor INTO @name;
END

CLOSE db_cursor;
DEALLOCATE db_cursor;
';

    -- Wire the two steps together: 1 = Backup, 2 = Prune
    EXEC msdb.dbo.sp_update_jobstep
        @job_name = N'Daily Full Backup',
        @step_id  = 1,
        @on_success_step_id = 2;

    EXEC msdb.dbo.sp_update_job
        @job_name = N'Daily Full Backup',
        @start_step_id = 1;

    EXEC msdb.dbo.sp_add_jobschedule
        @job_name      = N'Daily Full Backup',
        @name          = N'DailyAt0015',
        @freq_type     = 4,      -- daily
        @freq_interval = 1,      -- every 1 day
        @active_start_time = 001500;  -- HHMMSS -> 00:15:00

    EXEC msdb.dbo.sp_add_jobserver
        @job_name    = N'Daily Full Backup',
        @server_name = N'(local)';

    PRINT 'Job "Daily Full Backup" created (backup + prune-to-3), scheduled daily at 00:15.';
END
ELSE
BEGIN
    PRINT 'Job "Daily Full Backup" already exists, skipping creation.';
END
GO
