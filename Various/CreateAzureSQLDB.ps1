#
# CreateAzureSQLDB.ps1
#
Param(
	#Subscription name.
	[Parameter(Mandatory=$true,Position=1)]
	[string] $SubscriptionName,
    #Azure Region.
	[Parameter(Mandatory=$true,Position=2)]
	[string] $AzureRegion,
    #SQL Admin Login
	[Parameter(Mandatory=$true,Position=3)]
	[string] $SQLLogin,
    #SQL Admin Password
	[Parameter(Mandatory=$true,Position=4)]
	[string] $SQLPassword,
    #SQL Database Name
	[Parameter(Mandatory=$true,Position=5)]
	[string] $SQLDatabaseName
)

try
{
	Select-AzureSubscription -SubscriptionName $SubscriptionName -ErrorAction Stop | Out-Null
}
catch
{
	Write-Error "Azure subscription was not found."
	break
}


Select-AzureSubscription $SubscriptionName

# Azure account details automatically set
#$subID = Get-AzureSubscription -Current | %{ $_.SubscriptionId } 


# Provision new SQL Database Server
$sqlServer = New-AzureSqlDatabaseServer -AdministratorLogin $SQLLogin -AdministratorLoginPassword $SQLPassword -Location $AzureRegion


#######################################################
# 3. Azure SQL Server configuration --> authentication

# Create Firewall rule
# To allow connections to the database server you must create a rule that specifies 
# a range of IP addresses from which connections are allowed. 
New-AzureSqlDatabaseServerFirewallRule -ServerName $sqlServer.ServerName -RuleName "allowall" -StartIpAddress 1.1.1.1 -EndIpAddress 255.255.255.255


# Get credentials for SQL authentication
# a) Prompt for credentials
#$cred = Get-Credential
# or b) Use credentials from before
$serverCreds = New-Object System.Management.Automation.PSCredential($SQLLogin,($SQLPassword | ConvertTo-SecureString -AsPlainText -Force))


# Create connection to server using SQL Authentication
#$ctx = $sqlServer | New-AzureSqlDatabaseServerContext -Credential $serverCreds
$ctx = New-AzureSqlDatabaseServerContext -ServerName $sqlServer.ServerName -Credential $serverCreds
#$ctx = New-AzureSqlDatabaseServerContext -ServerName $sqlServer.ServerName -Credential $cred



#######################################################
# 4. Create Azure SQL Database

# Create new database
New-AzureSqlDatabase -DatabaseName $SQLDatabaseName -ConnectionContext $ctx

# Modify the database
Set-AzureSqlDatabase -ConnectionContext $ctx -DatabaseName $SQLDatabaseName -MaxSizeGB 20



#######################################################
# 5. Clean up

# Delete the database
Remove-AzureSqlDatabase $ctx -DatabaseName $SQLDatabaseName

# Delete the database server
Remove-AzureSqlDatabaseServer $sqlServer.ServerName