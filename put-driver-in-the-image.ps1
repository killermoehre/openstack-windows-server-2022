#Requires -modules @{ ModuleName="Dism"; ModuleVersion="3.0" }
#Requires -PSEdition Core
#Requires -RunAsAdministrator

param (
  [Parameter(Mandatory = $true, HelpMessage = "Drive Letter (with colon) of the ISO containing install.wim")]
  [ValidateScript({ Test-Path $_ })]
  [System.IO.DriveInfo]$SourceImageDrive,
  [Parameter(Mandatory = $true, HelpMessage = "Drive Letter (with colon) of the ISO containing the VirtIO drivers and guest-agent MSI")]
  [ValidateScript({ Test-Path $_ })]
  [System.IO.DriveInfo]$VirtioImageDrive
)

# Enable Debug Output
[string]$DebugPreference = 'Continue'
# Disable Confirm Prompts
[string]$ConfirmPreference = 'None'

[System.IO.FileInfo]$installWim = Join-Path -Path $SourceImageDrive -ChildPath "\sources\install.wim" -Resolve

Write-Output "Collecting Drivers to Install"
$virtioDrivers = New-Object -TypeName System.Collections.ArrayList
Get-ChildItem -Recurse -Path ${VirtioImageDrive}\*\2k22\amd64 -Include *.inf | ForEach-Object {
  $virtioDrivers.Add([System.IO.FileInfo]$_) | Out-Null
}

$msisToInstall = New-Object -TypeName System.Collections.ArrayList
$msisToInstall.Add([System.IO.FileInfo]$(Join-Path -Path $VirtioImageDrive -ChildPath "\virtio-win-gt-x64.msi" -Resolve )) | Out-Null
$msisToInstall.Add([System.IO.FileInfo]$(Join-Path -Path $VirtioImageDrive -ChildPath "\guest-agent\qemu-ga-x86_64.msi" -Resolve)) | Out-Null


# get the images in the .wim to patch all of them
$imagesInImage = New-Object -TypeName System.Collections.ArrayList
Get-WindowsImage -ImagePath $installWim | ForEach-Object {
  $imagesInImage.Add([Microsoft.Dism.Commands.BasicImageInfoObject]$_) | Out-Null
}

$newDiskMounts = New-Object -TypeName System.Collections.ArrayList

trap {
  if ($newDiskMounts.Count -gt 0) {
    foreach ($newDiskMount in $newDiskMounts) {
      "Unmounting $($newDiskMount.ImagePath)"
      $newDiskMount | Dismount-DiskImage -ErrorAction Continue
    }
  }
}

foreach ($image in $imagesInImage) {
  [string]$imageName = $image.ImageName
  [System.IO.FileInfo]$imageFile = "${imageName}.vhdx"

  Write-Output "Creating new Hard Disk"
  qemu-img.exe create -f vhdx $imageFile 40G
  $newDiskMount = Mount-DiskImage -ImagePath $PWD\$imageFile -PassThru
  $newDiskMounts.Add($newDiskMount)
  $newDisk = $newDiskMount | Get-Disk
  Initialize-Disk -Number $newDisk.Number -PartitionStyle GPT -PassThru -Confirm:$false -Verbose

  Write-Output "Formatting new Disk"
  $systemPartition = New-Partition -DiskNumber $newDisk.Number -Size 256MB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
  Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$false
  $systemPartition | Set-Partition -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
  $systemPartition | Add-PartitionAccessPath -AssignDriveLetter
  New-Partition -DiskNumber $newDisk.Number -Size 128MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
  $windowsPartition = New-Partition -DiskNumber $newDisk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
  $windowsVolume = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$false

  Write-Output "Assign Drive Letters to new Partitions"
  $windowsPartition | Add-PartitionAccessPath -AssignDriveLetter
  $windowsPartition = $windowsPartition | Get-Partition
  $windowsDrive = $(Get-Partition -Volume $windowsVolume).AccessPaths[0].substring(0, 2)
  $systemPartition = $systemPartition | Get-Partition
  $systemDrive = $systemPartition.AccessPaths[0].trimend("\").replace("\?", "??")

  Write-Output "Write Image to Disk"
  Expand-WindowsImage -ApplyPath $windowsDrive -CheckIntegrity -ImagePath $installWim -Name $imageName -SupportEa

  Write-Output "Add VirtIO Drivers"
  $virtioDrivers | Add-WindowsDriver -Path $windowsDrive -ForceUnsigned

  Write-Output "Add aditional guest components"
  foreach ($msiToInstall in $msisToInstall) {
    $msiexecArguments = @(
      "/i",
      $msiToInstall,
      "/qn",
      "/norestart",
      "TARGETDIR=$($windowsDrive)"
    )
    Start-Process msiexec -ArgumentList $msiexecArguments -NoNewWindow -Wait
  }

  Write-Output "Add Bootloader"
  $bcdbootArguments = @(
    "$($windowsDrive)\Windows",
    "/s $systemDrive",
    "/v",
    "/f UEFI"
  )
  Start-Process bcdboot.exe -ArgumentList $bcdbootArguments -NoNewWindow -Wait

  Write-Output "Finalize Disk"
  $newDiskMount | Dismount-DiskImage
  $newDiskMounts.Remove($newDiskMount)
  qemu-img.exe convert $imageFile $imageName.qcow2
}
