/*===========================================================================
  06_app_login_permissions.sql   AppSupportLab - least-privilege app access

  Creates the Windows login for the IIS app-pool service account, maps it into
  AppSupportLab, and grants it exactly what OrderDesk needs - nothing more.

  This file is what makes failures 1 and 4 distinguishable in the lab:
    failure 1 (bad service-account password) -> Windows logon fails,
              the app pool will not even start, SQL never sees a login attempt
    failure 4 (permission denied)            -> the login succeeds and SQL
              rejects the statement with error 229

  Set @ServiceAccount to match powershell\lab.config.ps1 before running.
===========================================================================*/

SET NOCOUNT ON;
USE master;
GO

DECLARE @ServiceAccount SYSNAME = N'$(LabServiceAccount)';  -- sqlcmd variable
-- If you are running this in SSMS rather than via sqlcmd, replace the line
-- above with a literal, e.g.:
--   DECLARE @ServiceAccount SYSNAME = N'LABNET\svc_orderdesk';
-- or for a workgroup VM:
--   DECLARE @ServiceAccount SYSNAME = N'WIN-LAB01\svc_orderdesk';

DECLARE @sql NVARCHAR(MAX);

-- Guard against running this with the placeholder un-substituted (which is
-- what happens in SSMS outside SQLCMD mode). The token is built from CHAR(36)
-- rather than written literally, because a literal would itself be parsed as
-- a sqlcmd variable and break this script.
IF @ServiceAccount IS NULL
   OR @ServiceAccount = N''
   OR @ServiceAccount = CONCAT(CHAR(36), N'(LabServiceAccount)')
    THROW 52000, 'Set @ServiceAccount, or pass -v LabServiceAccount="DOMAIN\acct" to sqlcmd.', 1;

PRINT CONCAT('Service account: ', @ServiceAccount);

/*--- server-level login ---------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @ServiceAccount)
BEGIN
    SET @sql = CONCAT(N'CREATE LOGIN ', QUOTENAME(@ServiceAccount), N' FROM WINDOWS
                        WITH DEFAULT_DATABASE = [AppSupportLab];');
    EXEC sys.sp_executesql @sql;
    PRINT 'Created login.';
END
ELSE
    PRINT 'Login already exists.';

-- The app needs no server-level rights at all. VIEW SERVER STATE is granted
-- only so /diag and the health check can report on connections.
SET @sql = CONCAT(N'GRANT VIEW SERVER STATE TO ', QUOTENAME(@ServiceAccount), N';');
EXEC sys.sp_executesql @sql;
GO

/*--- database user and role ----------------------------------------------*/
USE AppSupportLab;
GO

DECLARE @ServiceAccount SYSNAME = N'$(LabServiceAccount)';
DECLARE @sql NVARCHAR(MAX);

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @ServiceAccount)
BEGIN
    SET @sql = CONCAT(N'CREATE USER ', QUOTENAME(@ServiceAccount),
                      N' FOR LOGIN ', QUOTENAME(@ServiceAccount), N';');
    EXEC sys.sp_executesql @sql;
    PRINT 'Created database user.';
END

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'OrderDeskApp' AND type = 'R')
BEGIN
    CREATE ROLE OrderDeskApp AUTHORIZATION dbo;
    PRINT 'Created role OrderDeskApp.';
END

/*--- the grants the app actually uses ------------------------------------*/
GRANT SELECT, INSERT, UPDATE ON SCHEMA::app   TO OrderDeskApp;
GRANT SELECT                  ON SCHEMA::audit TO OrderDeskApp;
GRANT SELECT                  ON SCHEMA::ops   TO OrderDeskApp;
GRANT EXECUTE ON ops.usp_ReconcileOrderTotals TO OrderDeskApp;

/*--- and the things it must never do ------------------------------------*/
-- The app deletes nothing; deletions go through a DBA.
DENY DELETE ON SCHEMA::app TO OrderDeskApp;
-- The audit trail is append-only even to the schema owner's role.
DENY INSERT, UPDATE, DELETE ON SCHEMA::audit TO OrderDeskApp;
-- The app has no business reading the fix backups.
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::fix TO OrderDeskApp;

SET @sql = CONCAT(N'ALTER ROLE OrderDeskApp ADD MEMBER ', QUOTENAME(@ServiceAccount), N';');
EXEC sys.sp_executesql @sql;
PRINT 'Added service account to OrderDeskApp.';
GO

/*--- show the effective permissions, for the ticket ----------------------*/
DECLARE @ServiceAccount SYSNAME = N'$(LabServiceAccount)';

SELECT  dp.name           AS Principal,
        dp.type_desc      AS PrincipalType,
        p.permission_name,
        p.state_desc,
        p.class_desc,
        COALESCE(SCHEMA_NAME(p.major_id), OBJECT_SCHEMA_NAME(p.major_id)) AS SchemaName,
        OBJECT_NAME(p.major_id) AS ObjectName
FROM    sys.database_permissions AS p
JOIN    sys.database_principals  AS dp ON dp.principal_id = p.grantee_principal_id
WHERE   dp.name IN (N'OrderDeskApp', @ServiceAccount)
ORDER BY dp.name, p.state_desc DESC, p.permission_name;

PRINT '';
PRINT 'Verify as the app would see it (run while impersonating):';
PRINT '  EXECUTE AS LOGIN = ''<service account>'';';
PRINT '  SELECT TOP 1 * FROM app.Orders;           -- should succeed';
PRINT '  DELETE FROM app.Orders WHERE 1 = 0;       -- should fail with 229';
PRINT '  REVERT;';

PRINT '=== 06_app_login_permissions.sql complete ===';
GO
