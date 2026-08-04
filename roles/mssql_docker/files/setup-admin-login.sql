/*
  Idempotent setup: creates a SQL login with sysadmin privileges to use for
  all routine management instead of "sa". Intended to be run with
  sqlcmd -v AdminLogin="..." -v AdminPassword="..."

  NOTE: because sqlcmd does plain text substitution for $(AdminPassword),
  the password must not contain a single-quote character (') or this script
  will fail to parse. Anything else (including spaces) is fine.
*/
SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$(AdminLogin)')
BEGIN
    CREATE LOGIN [$(AdminLogin)] WITH PASSWORD = '$(AdminPassword)', CHECK_POLICY = ON;
    PRINT 'Login [$(AdminLogin)] created.';
END
ELSE
BEGIN
    PRINT 'Login [$(AdminLogin)] already exists, skipping creation.';
END
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.server_role_members rm
    JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
    JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'sysadmin' AND m.name = N'$(AdminLogin)'
)
BEGIN
    ALTER SERVER ROLE sysadmin ADD MEMBER [$(AdminLogin)];
    PRINT 'Login [$(AdminLogin)] added to sysadmin role.';
END
ELSE
BEGIN
    PRINT 'Login [$(AdminLogin)] is already a sysadmin member.';
END
GO
