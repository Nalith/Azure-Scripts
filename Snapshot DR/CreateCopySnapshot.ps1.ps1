#
# CreateCopySnapshot.ps1
#
Param(
	#Subscription name of the VM.
	[Parameter(Mandatory=$true,Position=1)]
	[string] $SubscriptionName,

	#The cloud service name of the VM.
	[Parameter(Mandatory=$true,Position=2)]
	[string] $CloudServiceName,

	#The VM name to copy.
	[Parameter(Mandatory=$true,Position=3)]
	[string] $AzureVMName,

	#The DR storage account name.
	[Parameter(Mandatory=$true,Position=4)]
	[string] $DRStorageAccountName,

	#Automatically shutdown VM.
	[Parameter(Mandatory=$false,Position=5)]
	[bool] $AutoShutdownVM=$false
)

#Declare variables
$DRSnapshots = @{}
$InitialVMPowerState = ""
$XMLPath = "C:\Azure DR XML"
$DstStorageAccountContainerName = "vhds"

#Functions
function LogToFile([int]$stepnumber, [string]$outputtext)
{
	$date = Get-Date
	$datestr = $date.ToShortDateString() + " " + $date.ToShortTimeString()

	if((Test-Path -Path $XMLPath) -eq $false)
	{
		New-Item -Path $XMLPath -ItemType Directory | Out-Null
	}

	if($stepnumber -ige 0)
	{
		Add-Content -Path "$XMLPath\$AzureVMName.log" "[$datestr] Step $stepnumber`: $outputtext"
	}
	else
	{
		Add-Content -Path "$XMLPath\$AzureVMName.log" "[$datestr]`: $outputtext"
	}
	
}

function CenterText([string]$text, [int]$width, [string]$padCharLeft = ' ', [string]$padCharRight = '')
{
    $output = $text
    if ($padCharRight.Length -eq 0){
        $padCharRight = $padCharLeft
    }
    while($output.Length -le $width){
        $output = $padCharLeft + $output + $padCharRight
    }
    return $output
}

function Write-HostCustom([int]$stepnumber, [string]$outputtext)
{
	$date = Get-Date
	$datestr = $date.ToShortDateString() + " " + $date.ToShortTimeString() 
	Write-Host "[$datestr] Step $stepnumber`: " -NoNewline -ForegroundColor Green
	Write-Host $outputtext
	LogToFile $stepnumber $outputtext
}

function Write-HostCustomHeader([string]$outputtext)
{
	$outputtext = "$outputtext`:"
	$outputtext = $outputtext.PadRight(150).ToUpper()
	Write-Host $outputtext -ForegroundColor Black -BackgroundColor White
	LogToFile -1 $outputtext
}

function Write-HostCustomSubHeader([string]$outputtext)
{
	$outputtext = "$outputtext"
	$outputtext = $outputtext.PadRight(140).ToUpper()
	Write-Host $outputtext -ForegroundColor Black -BackgroundColor Gray
	LogToFile -1 $outputtext
}

function Write-ErrorCustom([int]$stepnumber, [string]$outputtext)
{
	$date = Get-Date
	$datestr = $date.ToShortDateString() + " " + $date.ToShortTimeString() 
	Write-Host "[$datestr] Step $stepnumber`: " -NoNewline -ForegroundColor Black -BackgroundColor Red
	Write-Host $outputtext -ForegroundColor Black -BackgroundColor Red
	LogToFile $stepnumber $outputtext
}

function Move-DRSnapshot($VMDisk, [string]$DRSnapshotDateTime)
{
	$DstStorageAccountName = $DRStorageAccountName

	#Append -DR to disk name
	$DRVMDiskName = $VMDisk.DiskName + "-DR"

	$SrcBlobName = $VMDisk.MediaLink.Segments[2]

	Write-HostCustomSubHeader "Disk: $SrcBlobName"

	#Get original disk properties
	$SrcStorageAccountName = $VMDisk.MediaLink.Host.Split('.')[0]
	
    $DRVMDiskMediaLink = $VMDisk.MediaLink.ToString().Replace($SrcStorageAccountName,$DRStorageAccountName)
	$DRVMDiskOS = $VMDisk.OS
	$DRVMDiskHostCaching = $VMDisk.HostCaching
	
	#Test to see if there is already a DR disk created
	$DRVMDiskDisk = Get-AzureDisk -DiskName $DRVMDiskName -ErrorAction SilentlyContinue

	if($DRVMDiskDisk)
	{
		Write-HostCustom 3 "Removing Existing Azure DR Disk: $DRVMDiskName"
		$RemovedAzureDisk = Remove-AzureDisk -DiskName $DRVMDiskName
	}
	
	$SrcStorageAccountKey = (Get-AzureStorageKey -StorageAccountName $SrcStorageAccountName).Primary
    $DstStorageAccountKey = (Get-AzureStorageKey -StorageAccountName $DstStorageAccountName).Primary
    
    $SrcStorageAccountContext =  New-AzureStorageContext -StorageAccountName $SrcStorageAccountName -StorageAccountKey $SrcStorageAccountKey
    $DstStorageAccountContext = New-AzureStorageContext  -StorageAccountName $DstStorageAccountName -StorageAccountKey $DstStorageAccountKey

    $SnapshotQualifiedStorageUri = $DRSnapshots[$VMDisk.DiskName.ToString()].SnapshotQualifiedStorageUri
    
    $SrcBlobName = $VMDisk.MediaLink.Segments[2]
	
	try
	{
		Get-AzureStorageContainer -Name $DstStorageAccountContainerName -Context $DstStorageAccountContext -ErrorAction Stop | Out-Null
	}
	catch
	{
		New-AzureStorageContainer -Name $DstStorageAccountContainerName -Context $DstStorageAccountContext | Out-Null
		Write-HostCustom 3 "Creating $DstStorageAccountContainerName container in $DstStorageAccountName storage account."
	}
	    
    $CopyBlob = Start-AzureStorageBlobCopy -CloudBlob $DRSnapshots[$VMDisk.DiskName.ToString()] -Context $SrcStorageAccountContext -DestContext $DstStorageAccountContext -DestContainer $DstStorageAccountContainerName -DestBlob $SrcBlobName -Force

	### Retrieve the current status of the copy operation ###
	$CopyStatus = $CopyBlob | Get-AzureStorageBlobCopyState 
 
	Write-HostCustom 3 "Copying VHD Snapshot to DR Storage Account: $SrcBlobName"
	### Loop until complete ###                                    
	While($CopyStatus.Status -eq "Pending")
	{
		$CopyStatus = $CopyBlob | Get-AzureStorageBlobCopyState 
		Start-Sleep 30
		Write-Host ">" -NoNewline
	}
	Write-Host "#"
	Write-HostCustom 3 "Copying VHD Snapshot to DR Storage Account Completed: $SrcBlobName"
	Write-HostCustom 3 "Deleting VHD ($SrcBlobName) Snapshot..."
    $DRSnapshots[$VMDisk.DiskName.ToString()].Delete()

	#Add Azure Disk for DR	
	#Write-Host "Creating Azure DR Disk"
	if($DRVMDiskOS -ne $null -and $DRVMDiskOS -ne "")
	{
		Write-HostCustom 3 "Creating Azure DR OS Disk: $DRVMDiskName"
		$AzureDisk = Add-AzureDisk -DiskName $DRVMDiskName -MediaLocation $DRVMDiskMediaLink -OS $DRVMDiskOS
	}
	else
	{
		Write-HostCustom 3 "Creating Azure DR Data Disk: $DRVMDiskName"
		$AzureDisk = Add-AzureDisk -DiskName $DRVMDiskName -MediaLocation $DRVMDiskMediaLink
	}
}

function Create-DRSnapshot($VMDisk)
{
	$SrcStorageAccountName = $VMDisk.MediaLink.Host.Split('.')[0]
	$SrcStorageAccountKey = (Get-AzureStorageKey -StorageAccountName $SrcStorageAccountName).Primary
	$SrcStorageAccountContext = New-AzureStorageContext -StorageAccountName $SrcStorageAccountName -StorageAccountKey $SrcStorageAccountKey
	$SrvStorageAccountContainerName = $VMDisk.MediaLink.Segments[1].ToString().Replace("/", "")
	$SrcBlobName = $VMDisk.MediaLink.Segments[2]
	
	$SrcDiskBlob = Get-AzureStorageBlob -Context $SrcStorageAccountContext -Container $SrvStorageAccountContainerName -Blob $SrcBlobName
	$SrcdPageBlob = [Microsoft.WindowsAzure.Storage.Blob.CloudPageBlob] $SrcDiskBlob.ICloudBlob

    #Write-Host "Creating snapshot for: $SrcBlobName"
	Write-HostCustom 2 "Creating Disk Snapshot for: $SrcBlobName"

	$SrcdPageBlobSnapshot = $SrcdPageBlob.CreateSnapshot()
	$DRSnapshots[$VMDisk.DiskName.ToString()] = $SrcdPageBlobSnapshot
}

function ExportAndUpdate-VMXML()
{
	Write-HostCustomHeader "AzureVM XML Configuration"
	Write-HostCustom 4 "Exporting and Updating VM Configuration as XML."

	if((Test-Path -Path $XMLPath) -eq $false)
	{
    New-Item -Path $XMLPath -ItemType Directory | Out-Null
	}

	$XMLFilePath = "C:\Azure DR XML\$AzureVMName-DR.xml"

	$result = Export-AzureVM -ServiceName $CloudServiceName -Name $AzureVMName -Path $XMLFilePath

	$XML = [xml](Get-Content $XMLFilePath)
	$Node = $XML.PersistentVM
	$Node.RoleName = "$AzureVMName-DR"
	$Node.OSVirtualHardDisk.DiskName = $Node.OSVirtualHardDisk.DiskName + "-DR"

	foreach($DataDisk in $Node.DataVirtualHardDisks.DataVirtualHardDisk)
	{
		$DataDisk.DiskName = $DataDisk.DiskName + "-DR"
	}

	$XML.Save($XMLFilePath)

	#Upload XML to Storage Account for Backup
	Write-HostCustom 4 "Uploading VM Configuration XML to Storage Account."
	$DstStorageAccountName = $DRStorageAccountName
	$DstStorageAccountKey = (Get-AzureStorageKey -StorageAccountName $DstStorageAccountName).Primary
	$DstStorageAccountContext = New-AzureStorageContext  -StorageAccountName $DstStorageAccountName -StorageAccountKey $DstStorageAccountKey
	Set-AzureSubscription -CurrentStorageAccountName $DstStorageAccountName -SubscriptionName $SubscriptionName
	$AzureStorageBlobContent = Set-AzureStorageBlobContent -Context $DstStorageAccountContext -Container $DstStorageAccountContainerName -File $XMLFilePath -Force
}

function Main()
{
	Write-HostCustomHeader "Commencing pre-flight checks"
	#Check to see if a valid Azure Subscription was provided.
	try
	{
		Select-AzureSubscription -SubscriptionName $SubscriptionName -ErrorAction Stop | Out-Null
		Write-HostCustom 0 "Azure subscription details are valid."
	}
	catch
	{
		Write-ErrorCustom 0 "Azure subscription was not found."
		break
	}
	#Check to see if a valid Storage Account was provided.
	try
	{
		Get-AzureStorageAccount -StorageAccountName $DRStorageAccountName -ErrorAction Stop -WarningAction Ignore | Out-Null
		Write-HostCustom 0 "Storage account details are valid."
	}
	catch
	{
		Write-ErrorCustom 0 "Storage account not found, please ensure the specified storage account is valid."
		break
	}
	#Check to see if valid VM Cloud Service and VMName was provided.
	if((Get-AzureVM -Name $AzureVMName -ServiceName $CloudServiceName -ErrorAction Stop -WarningAction Ignore))
	{
		Write-HostCustom 0 "AzureVM details are valid."
	}
	else
	{
		Write-ErrorCustom 0 "Unable to find AzureVM, please ensure the Cloud Service and/or VM name provided are valid."
		break
	}

	Write-HostCustomHeader "Getting AzureVM Information"
	Write-HostCustom 1 "Getting AzureVM Configuration."

	#Write-Host "Getting AzureVM Configuration..."
	$AzureVM = Get-AzureVM -Name $AzureVMName -ServiceName $CloudServiceName -ErrorAction Stop -WarningAction Ignore

	$InitialVMPowerState = $AzureVM.PowerState

	if($InitialVMPowerState -eq "Started" -and $AutoShutdownVM -eq $true)
	{
		Write-HostCustom 1 "Shutting down AzureVM."
		$AzureVM | Stop-AzureVM -StayProvisioned | Out-Null
		#Get updated VM State
		$AzureVM = Get-AzureVM -Name $AzureVMName -ServiceName $CloudServiceName
	}

	if($AzureVM.PowerState -eq "StoppedDeallocated" -or $AzureVM.PowerState -eq "Stopped")
	{
		#Get OS disk.
		Write-HostCustom 1 "Getting AzureVM OS Disk Configuration."
		#Write-Host "Getting AzureVM OS Disk..."
		$VMOSDisk = $AzureVM | Get-AzureOSDisk
		#Get Data disks if any.
		Write-HostCustom 1 "Getting AzureVM Data Disk/s Configuration."
		#Write-Host "Getting AzureVM Data Disks..."
		$VMDataDisks = $AzureVM | Get-AzureDataDisk
	
		Write-HostCustomHeader "Creating VHD snapshots"
		#CopyVDHtoDRStorageAccount $VMOSDisk
		Create-DRSnapshot $VMOSDisk

		foreach ($VMDataDisk in $VMDataDisks) 
		{
			Create-DRSnapshot $VMDataDisk
		}
    
		#StartVM here
		if($InitialVMPowerState -eq "Started" -and ($AzureVM.PowerState -eq "StoppedDeallocated" -or $AzureVM.PowerState -eq "Stopped"))
		{
			Write-HostCustom 2 "Starting AzureVM."
			$AzureVM | Start-AzureVM | Out-Null
			#Get updated VM State
			$AzureVM = Get-AzureVM -Name $AzureVMName -ServiceName $CloudServiceName
		}
	
		Write-HostCustomHeader "Copying VHD snapshots to $DRStorageAccountName"
		Move-DRSnapshot $VMOSDisk

		foreach ($VMDataDisk in $VMDataDisks) 
		{
			Move-DRSnapshot $VMDataDisk
		}

		ExportAndUpdate-VMXML
	}
	else
	{
		Write-ErrorCustom 1 "VM PowerState is not ""StoppedDeallocated"" or ""Stopped"" as expected."
	}
}

Main