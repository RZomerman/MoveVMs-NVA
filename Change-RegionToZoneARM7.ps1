

#Get TargetVM
#validate regional deployment
#validate IP address
#publicIP address available?
#type of publicIP
#Availability Set?

#shutdown TargetVM
#snapshot disk
#create new disk with zone from snapshot
#if public IP create new public IP

[CmdletBinding()]
Param(
   [Parameter(Mandatory=$True,Position=2)]
   [string]$VMName,
   [Parameter(Mandatory=$False,Position=3)]
   [string]$TargetZone,
   [Parameter(Mandatory=$True,Position=1)]
   [string]$ResourceGroup,
   [Parameter(Mandatory=$False,Position=4)]
   [string]$VmSize,
   [Parameter(Mandatory=$False)]
   [boolean]$SkipAZCheck=$true,
   [Parameter(Mandatory=$False)]
   [boolean]$Login,
   [Parameter(Mandatory=$False)]
   [boolean]$SelectSubscription,
   [Parameter(Mandatory=$False)]
   [boolean]$Report
)


Function ConvertDisktoZonal ($DiskID){
    $DiskResource=Get-AzResource -ResourceId $DiskID
    $Disk=Get-AZdisk -ResourceGroupName $DiskResource.ResourceGroupName -DiskName $DiskResource.Name

    #Snapshot config
    $Snapshotconfig=New-AzSnapshotConfig -SourceUri $DiskID -Location $DiskResource.Location -CreateOption copy -SkuName Standard_LRS
    $timestamp = Get-Date -Format yyMMddThhmmss
    $snapshotName = ($DiskResource.Name + $timestamp)
    writelog ("   >Creating snapshot of " + $DiskResource.Name) -LogFile $LogFile
    $DiskSnapshot=New-AzSnapshot -Snapshot $snapshotConfig -SnapshotName $snapshotName -ResourceGroupName $DiskResource.ResourceGroupName

    $DiskSnapshotID=$DiskSnapshot.id
    $DiskResourceLocation=$DiskResource.Location
    $SKU=$Disk.sku.name
    $Tier=$Disk.sku.tier

    writelog ("   >Snapshot ID: " + $DiskSnapshotID) -LogFile $LogFile
    writelog ("   >Disk Location: " + $DiskResourceLocation) -LogFile $LogFile
    writelog ("   >Disk SKU: " + $SKU) -LogFile $LogFile
    writelog ("   >Disk Tier: " + $Tier) -LogFile $LogFile

    #Scanning and converting tags for disk object
    If ($DiskResource.Tag){
        writelog "Tags have been found on the original Disk - setting same on new Disk" -LogFile $LogFile
        $newtag=""
        $TagsOnDisk=$DiskResource.Tag
        #open the new tag to add
        $newtag="@{"
        $TagsOnDisk.GetEnumerator() | ForEach-Object{
            $message = '{0}="{1}";' -f $_.key, $_.value
            $newtag=$newtag + $message
        }
        #removing last semicolon
        $newtag=$newtag.Substring(0,$newtag.Length-1)
        #closing newtag value
        $newtag=$newtag +"}"

        #@{key0="value0";key1=$null;key2="value2"}
        
        #Creating new Disk Configuration with TAGS and Zone information
        writelog "Creating new disk configuration with tags" -LogFile $LogFile
        $DiskConfig=New-AzDiskConfig -Zone $TargetZone -SkuName $SKU -Location $DiskResourceLocation -CreateOption Copy -SourceResourceId $DiskSnapshotID -tag $newtag 
    }else{
        #Creating new Disk Configuration with Zone information
        writelog "  - Creating new disk configuration" -LogFile $LogFile -Color Green
        $DiskConfig=New-AzDiskConfig -Zone $TargetZone -SkuName $SKU -Location $DiskResourceLocation -CreateOption Copy -SourceResourceId $DiskSnapshotID
    }
    
    #Create the disk from the snapshot
    $DiskName=($DiskResource.name + "z")
    $DiskResourceResourceGroupName=$DiskResource.ResourceGroupName
    writelog "  - Deploying new Disk"  -LogFile $LogFile -Color Green
    $NewDisk=New-AzDisk -DiskName $DiskName  -ResourceGroupName $DiskResourceResourceGroupName -Disk $DiskConfig

    #after creating the disk returning the disk ID
    [string]$NewDiskID=$NewDisk.Id
    return $NewDiskID
}

Function ConvertNICtoZonal ($NICID){
    $NICObject=Get-AzNetworkInterface -ResourceId $NICID
    #Each NIC can have multiple IP Address configurations - we need to scan all of them
    #[array]$IPConfigurations=$NICObject.IpConfigurations.publicIPAddress.id
####
for ($s=1;$s -le $NICObject.IpConfigurations.publicIPAddress.id.count ; $s++ ){
    $ChangedNICConfig=$false
    
    $IPObject=Get-AzResource -ResourceId $NICObject.IpConfigurations[$s-1].publicIPAddress.id
    $IpAddressConfig=Get-AzPublicIpAddress -Name $IPObject.Name -ResourceGroupName $IPObject.ResourceGroupName 
    if ($IpAddressConfig.sku.Name -eq 'basic' -or $IpAddressConfig.zones -notcontains $TargetZone) {
            Writelog ("   >IP Address is of " + $IpAddressConfig.sku.Name + " type in the " + $IpAddressConfig.sku.Tier + " - deploying new IP address with correct configuration") -LogFile $LogFile
            If ($IpAddressConfig.zones -notcontains $TargetZone) {
                writelog ("   >IP Address supported zones: " + [string]$IpAddressConfig.zones) -LogFile $LogFile
                Writelog ("   >IP Address is in wrong zone deploying new IP address with correct configuration") -LogFile $LogFile
            }
            #Exporting configuration of Public IP address
            [string]$ExportFile=($workfolder + '\' + $IPObject.ResourceGroupName  + '-' + $IpAddressConfig.Name + '.json')
            $Description = "  - Exporting the Public IP JSON Deployment file: $ExportFile "
            $Command = {Export-AzResourceGroup -ResourceGroupName $ResourceGroup -Resource $IpAddressConfig.id -IncludeParameterDefaultValue -IncludeComments -Force -Path $ExportFile }
            $null=RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
            $Command=""

            #if DNSSettings where added - will copy and remove from old IP (if DNS based VPN's are used)
            If ( $IpAddressConfig.DnsSettings) {
                Writelog ("   >DNS Name on IP: " +  $IpAddressConfig.DnsSettings)  -LogFile $LogFile
                $IPDNSConfig=$IpAddressConfig.DnsSettings.DomainNameLabel
                $IpAddressConfig.DnsSettings.DomainNameLabel=$null
                If ($IpAddressConfig.DnsSettings.fqdn) {
                  $IpAddressConfig.DnsSettings.fqdn=$null
                }
                Writelog ("   >Removing DNS Name from IP")  -LogFile $LogFile
                $null=Set-AzPublicIpAddress -PublicIpAddress $IpAddressConfig
            }
            #setting new name
            $IpAddressNewName=$IpAddressConfig.Name + "z"
            writelog "   >Requiring new Public IP address with zone configuration for VM deployment"  -LogFile $LogFile

            $ResourceGroupNameForCommand=$IpAddressConfig.ResourceGroupName
            $Location=$IpAddressConfig.Location
            $Command="New-AzPublicIpAddress -Name $IpAddressNewName -ResourceGroupName $ResourceGroupNameForCommand -Location $Location -Sku Standard -Tier Regional -AllocationMethod Static -IpAddressVersion IPv4 -Zone $TargetZone"
            #if DNSSettings where added - will copy and remove from old IP (if DNS based VPN's are used)
            If ( $IpAddressConfig.DnsSettings) {
                Writelog ("   >DNS Name on IP: " +  $IpAddressConfig.DnsSettings)  -LogFile $LogFile
                $IPDNSConfig=$IpAddressConfig.DnsSettings.DomainNameLabel
                $IpAddressConfig.DnsSettings.DomainNameLabel=$null
                Writelog ("   >Removing DNS Name from IP")  -LogFile $LogFile
                Set-AzPublicIpAddress -PublicIpAddress $IpAddressConfig
                $Command = $Command + " -DomainNameLabel $IPDNSConfig" 
            }
            If ($IpAddressConfig.Tag){
                writelog "   >Tags have been found on the original IP - setting same on new IP" -LogFile $LogFile

                $newtag=""
                $TagsOnIP=$IpAddressConfig.Tag
                #open the new tag to add
                $newtag="@{"
                $TagsOnIP.GetEnumerator() | ForEach-Object{
                    $message = '{0}="{1}";' -f $_.key, $_.value
                    $newtag=$newtag + $message
                }
                #removing last semicolon
                $newtag=$newtag.Substring(0,$newtag.Length-1)
                #closing newtag value
                $newtag=$newtag +"}"

                #@{key0="value0";key1=$null;key2="value2"}
                $Command=$Command + " -tag $newtag"
            }
                    
            $Command = [Scriptblock]::Create($Command)
            $Description = "  - Creating new Public IP: $IpAddressNewName"
            writelog "   >Deploying new Public IP address with correct information"  -LogFile $LogFile
            $null=RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"

            #Once a new Public IP has been created - it needs to be linked to the NIC
            $NewIP=Get-AzPublicIpAddress -Name $IpAddressNewName -ResourceGroupName $ResourceGroupNameForCommand
            $NICObject.IpConfigurations[$s-1].publicIPAddress.id=$NewIP.id
            $ChangedNICConfig=$true
        }
    }
    If ($ChangedNICConfig){
        writelog "  !! VM has at least 1 new Public IP !!"  -LogFile $LogFile -Color Yellow
        $null=Set-AzNetworkInterface -NetworkInterface $NICObject
        writelog "   >Writing new Network Interface IP Configuration information"  -LogFile $LogFile
    }
}
write-host ""
write-host ""
Set-Item -Path Env:\SuppressAzurePowerShellBreakingChangeWarnings -Value $true
#Cosmetic stuff
write-host ""
write-host ""
write-host "                               _____        __                                " -ForegroundColor Green
write-host "     /\                       |_   _|      / _|                               " -ForegroundColor Yellow
write-host "    /  \    _____   _ _ __ ___  | |  _ __ | |_ _ __ __ _   ___ ___  _ __ ___  " -ForegroundColor Red
write-host "   / /\ \  |_  / | | | '__/ _ \ | | | '_ \|  _| '__/ _' | / __/ _ \| '_ ' _ \ " -ForegroundColor Cyan
write-host "  / ____ \  / /| |_| | | |  __/_| |_| | | | | | | | (_| || (_| (_) | | | | | |" -ForegroundColor DarkCyan
write-host " /_/    \_\/___|\__,_|_|  \___|_____|_| |_|_| |_|  \__,_(_)___\___/|_| |_| |_|" -ForegroundColor Magenta
write-host "     "
write-host " This script reconfigures a VM to an Availability Zone" -ForegroundColor "Green"
write-host "  - Disks will be snapshotted and new disks will be created" -ForegroundColor "Green"
write-host "  - Basic Public Ip addresses will be duplicated for standard SKU" -ForegroundColor "Green"
write-host "  - New resources will have the 'z' appended to the name to indicate zonal configurations" -ForegroundColor "Green"


#Importing the functions module and primary modules for AAD and AD


If (!((Get-Module -name Az.Compute -ListAvailable))){
    Write-host "Az.Compute Module was not found - cannot continue - please install the module using install-module AZ"
    Exit
}

If (Get-Module -name RegionToZone ){
    Write-host "Reloading RegionToZone module file"
    remove-module RegionToZone
}

Import-Module .\Change-RegionToZone.psm1 -DisableNameChecking

##Setting Global Paramaters##
$ErrorActionPreference = "Stop"
$date = Get-Date -UFormat "%Y-%m-%d-%H-%M"
$workfolder = Split-Path $script:MyInvocation.MyCommand.Path
$logFile = $workfolder+'\ChangeSize'+$date+'.log'
Write-Output "  - Steps will be tracked in log file : [ $logFile ]" 

##Login to Azure##
If ($Login) {
    $Description = "  -Connecting to Azure"
    $Command = {LogintoAzure}
    $AzureAccount = RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"
}

#Retrieve info on VM
$vmObject=get-azvm -resourcegroupname $ResourceGroup -Name $VMName

If (!($vmObject)) {
    WriteLog "Target VM does not exist, cannot move" -LogFile $LogFile -Color "Red" 
        exit
}

#Validating if VM can be moved to Availablity Zone (supported by location and SKU)
If (!($SkipAZCheck)){
    writelog "  - Retrieving information on Availability Zone presence and SKU availablity in requested zone this takes a while" -logFile $logFile
    $EligableForMigration=Get-AzComputeResourceSku | where {$_.Locations.Contains($VMObject.location) -and $_.Name.contains($vmObject.HardwareProfile.VMsize) -and $_.LocationInfo.zones.contains($TargetZone.toString())}

    If ($VMAvailabilityZones -notcontains $TargetZone){
        writelog "VMSize not available in AZ or no AZ found in VM location" -logFile $logFile -Color Red    
        exit
    }
    #If (!($EligableForMigration)){
    #    writelog "VMSize not available in AZ or no AZ found in VM location" -logFile $logFile -Color Red    
    #    exit
    #}
}


#Ensuring we retain the disks on deletion - this is required, else the disks might be deleted with the VM on the last step
$vmObject.StorageProfile.OsDisk.DeleteOption="detach"

for ($s=1;$s -le $VmObject.StorageProfile.DataDisks.Count ; $s++ ){
    if (!($VmObject.StorageProfile.DataDisks[$s-1].vhd)){
        $VmObject.StorageProfile.DataDisks[$s-1].DeleteOption="Detach"
    }
}
writelog "  - Changing VM/Disk deletion mode to detach to retain old disks" -logFile $logFile -Color Green
$null=Update-AzVM -VM $VMObject -ResourceGroupName $VMObject.ResourceGroupName


 #Exporting the VM object to a JSON file - for backup purposes -- main file and actual deployment file
    write-host ""
    Write-host "Exporting JSON backup for the VM - This allows the VM to be easily re-deployed back to original state in case something goes wrong" -ForegroundColor Yellow
    Write-host "if so, please run new-AzResourceGroupDeployment -Name <deploymentName> -ResourceGroup <ResourceGroup> -TemplateFile .\<filename>" -ForegroundColor Yellow
    write-host ""
    $Filename=($ResourceGroup + "-" + $VMName)
    $Command = {ConvertTo-Json -InputObject $vmObject -Depth 100 | Out-File -FilePath $workfolder'\'$Filename'-Object.json'}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"

    $VMBackupObject=$VMObject
    $VMBackupObject.StorageProfile.OsDisk.CreateOption = 'Attach'
    If ($VMBackupObject.StorageProfile.DataDisks.Count -gt 1) {
        for ($s=1;$s -le $VMBackupObject.StorageProfile.DataDisks.Count ; $s++ ){
            $VMBackupObject.StorageProfile.DataDisks[$s-1].CreateOption = 'Attach'
        }
    }
    $VMBackupObject.OSProfile = $null
    $VMBackupObject.StorageProfile.ImageReference = $null
    $Description = "  - Creating the VM Emergency restore file : EmergencyRestore-$ResourceGroup-$VMName.json "
    $Command = {ConvertTo-Json -InputObject $VMBackupObject -Depth 100 | Out-File -FilePath 'EmergencyRestore-'$workfolder'/'$ResourceGroup-$VMName'.json'}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"

#Exporting object file to be reimported later and for adjustments if required prior to deployment
    [string]$VMExportFile=($workfolder + '/' + $ResourceGroup + '-' + $VMName + '.json')
    $Description = "  - Exporting the VM JSON Deployment file: $VMExportFile "
    $Command = {Export-AzResourceGroup -ResourceGroupName $ResourceGroup -Resource $vmObject.id -IncludeParameterDefaultValue -IncludeComments -Force -Path $VMExportFile }
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile -Color "Green"


#Shutting down VM to ensure data integrity
writelog "  - Stopping VM for data integrity" -logFile $logFile -Color Green
Stop-AzVM -ResourceGroupName $resourcegroup -Name $VMname -Force | Out-Null

#Need to get information on the object - this includes - Public IP address configuration and disk information
#Each VM can have one or multiple NIC's which we need to query independently
writelog "  - Retrieving Network Interface information" -logFile $logFile -Color Green
write-host "    if the VM has basic Public IP Addresses - these need to be changed to Standard and set to support Zonal configuration"
[array]$NICArray=$vmObject.NetworkProfile.NetworkInterfaces.id
Foreach ($NIC in $NICArray){
    writelog "   >NIC: $NIC" -logFile $logFile -color Yellow
    $null=ConvertNICtoZonal -NICID $NIC
}

#Create a snapshot of the disk(s) - this snapshot will be used to deploy a new (zonal) disk(s)
write-host ""
writelog "  - Retrieving OS Disk information" -logFile $logFile -Color Green
$OsDisk=$VMObject.StorageProfile.OsDisk
if (!($VmObject.StorageProfile.OsDisk.VHD)) {
    writelog "  - Converting OS Disk to Zonal"  -LogFile $LogFile -Color Green
    [string]$newOSDiskID=ConvertDisktoZonal -DiskID $VMObject.StorageProfile.OsDisk.ManagedDisk.Id
    $newOSDiskID=$newOSDiskID.trim()
    $VMObject.StorageProfile.OsDisk.ManagedDisk.Id = $newOSDiskID
    $VMObject.StorageProfile.OsDisk.name = ($VMObject.StorageProfile.OsDisk.name + "z")
    writelog "  - Converted OS Disk and mounted new disk"  -LogFile $LogFile -Color Green

}else{
    writelog "Unmanaged Disk found - need to covert - TO BE IMPLEMENTED" -logFile $LogFile
    exit
}

#Converting all data disks
If ($VmObject.StorageProfile.DataDisks.Count -gt 1) {
    writelog "  - Retrieving Data Disk(s) information" -logFile $logFile -Color Green
    for ($s=1;$s -le $VmObject.StorageProfile.DataDisks.Count ; $s++ ){
        $VmObject.StorageProfile.DataDisks[$s-1].CreateOption = 'Attach'
        if (!($VmObject.StorageProfile.DataDisks[$s-1].vhd)){
            writelog ("   >Converting Data Disk to Zonal: " + $VmObject.StorageProfile.DataDisks[$s-1].Name)  -LogFile $LogFile
            $DataDiskID=ConvertDisktoZonal -DiskID $VmObject.StorageProfile.DataDisks[$s-1].ManagedDisk.Id
            $DataDiskID=$DataDiskID=.replace(" ","")
            $VmObject.StorageProfile.DataDisks[$s-1].ManagedDisk.Id = $DataDiskID
            $VmObject.StorageProfile.DataDisks[$s-1].Name=($VmObject.StorageProfile.DataDisks[$s-1].Name + "zone")
            writelog "  - Converted Data Disk $s and mounted new disk"  -LogFile $LogFile -Color Green
        }
    }
}
writelog "  - Setting deployment options" -logFile $logFile -Color Green
#Setting configuration for new deployment
    writelog "   >Setting storage configuration" -LogFile $LogFile
    $VmObject.OSProfile = $null
    $VmObject.StorageProfile.ImageReference = $null
    $VmObject.StorageProfile.OsDisk.CreateOption = 'Attach'
    if ($VmObject.StorageProfile.OsDisk.Image) {
        writelog "   >Resetting reference image" -LogFile $LogFile
        $VmObject.StorageProfile.OsDisk.Image = $null
    }

    If ($VmObject.StorageProfile.DataDisks.Count -gt 1) {
        for ($s=1;$s -le $VmObject.StorageProfile.DataDisks.Count ; $s++ ){
            $VmObject.StorageProfile.DataDisks[$s-1].CreateOption = 'Attach'
            writelog "   >Setting disks to attach" -LogFile $LogFile
        }
    }

    If ($VMSize){
        writelog ("   >Setting VMSize to" + $VMSize) -LogFile $LogFile
        $VmObject.HardwareProfile.VmSize = $VMSize
    }

#Need to discard proximity placement groups
    If ( $VmObject.ProximityPlacementGroup){
        writelog "   >Removing proximity placement group configuration" -LogFile $LogFile
        $VmObject.ProximityPlacementGroup=$null
    }

#Need to discard any availabilty sets
    If ( $VmObject.AvailabilitySetReference){
        writelog "   >Removing Availability Set configuration" -LogFile $LogFile
        $VmObject.AvailabilitySetReference = $null
    }

#setting availabilit zone for deployment
    $ZoneList = New-Object System.Collections.Generic.List[string]
    $ZoneList.add($TargetZone)
    $VmObject.Zones=$ZoneList

#Redeploying VM
    $VMName=$VmObject.Name 
    $Description = "   -Recreating the Azure VM: (Step 1 : Removing the VM...) "
    $Command = {Remove-AzVM -Name $VmObject.Name -ResourceGroupName $VmObject.ResourceGroupName -Force | Out-null}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile
    
    #Write-host "  -Waiting for 5 seconds to backend to sync" -ForegroundColor Yellow
    Start-sleep 5
    
    $Description = "   -Recreating the Azure VM: (Step 2 : Creating the VM...) "
    $Command = {New-AZVM -ResourceGroupName $VmObject.ResourceGroupName -Location $VmObject.Location -VM $VmObject | Out-Null}
    RunLog-Command -Description $Description -Command $Command -LogFile $LogFile
