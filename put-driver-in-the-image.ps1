#Requires -modules @{ ModuleName="Dism"; ModuleVersion="3.0" }
#Requires -RunAsAdministrator

param (
  [Parameter(Mandatory = $true, HelpMessage = "Drive Letter (with colon) of the ISO containing install.wim")]
  [ValidateScript({ Test-Path $PSItem })]
  [System.IO.DriveInfo]$SourceImageDrive,
  [Parameter(Mandatory = $true, HelpMessage = "Drive Letter (with colon) of the ISO containing the VirtIO drivers and guest-agent MSI")]
  [ValidateScript({ Test-Path $PSItem })]
  [System.IO.DriveInfo]$VirtioImageDrive
)

# Enable Debug Output with `Continue`
[string]$DebugPreference = 'SilentContinue'
# Disable Confirm Prompts
[string]$ConfirmPreference = 'None'

[System.IO.DirectoryInfo]$logDir = Join-Path -Path $env:TEMP -ChildPath transcript
New-Item -Path $logDir -ItemType Directory -Force
"LogDir=$($logdir.FullName)" | Out-File -FilePath $env:GITHUB_ENV -Append
[System.IO.FileInfo]$logFile = (Start-Transcript -OutputDirectory $logDir -IncludeInvocationHeader).Path
"LogFile=$($logFile)" | Out-File -FilePath $env:GITHUB_ENV -Append

[System.IO.FileInfo]$installWim = Join-Path -Path $SourceImageDrive -ChildPath "\sources\install.wim" -Resolve

Write-Output "Collecting Drivers to Install"
$virtioDrivers = New-Object -TypeName System.Collections.ArrayList
Get-ChildItem -Recurse -Path ${VirtioImageDrive}\*\2k22\amd64 -Include *.inf | ForEach-Object {
  $virtioDrivers.Add([System.IO.FileInfo]$PSItem) | Out-Null
}

$msisToInstall = New-Object -TypeName System.Collections.ArrayList
$msisToInstall.Add([System.IO.FileInfo]$(Join-Path -Path $VirtioImageDrive -ChildPath "\virtio-win-gt-x64.msi" -Resolve )) | Out-Null
$msisToInstall.Add([System.IO.FileInfo]$(Join-Path -Path $VirtioImageDrive -ChildPath "\guest-agent\qemu-ga-x86_64.msi" -Resolve)) | Out-Null


# get the images in the .wim to patch all of them
$imagesInImage = New-Object -TypeName System.Collections.ArrayList
Get-WindowsImage -ImagePath $installWim | ForEach-Object {
  Write-Output "::group::Images in Image"
} {
  Write-Output $PSItem
  $imagesInImage.Add([Microsoft.Dism.Commands.BasicImageInfoObject]$PSItem) | Out-Null
} {
  Write-Output "::endgroup::"
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

$imagesInImage | ForEach-Object {
  $null
} {
  [string]$imageName = $PSItem.ImageName
  [System.IO.FileInfo]$imageFile = $imageName + ".vhdx"

  [string[]]$qemuImgCreateArguments = @("create", "-f", "vhdx", "`"$imageFile`"", "40G")
  Write-Output "Creating new Hard Disk with qemu-img.exe $($qemuImgCreateArguments)"
  Start-Process -FilePath qemu-img.exe -ArgumentList $qemuImgCreateArguments -NoNewWindow -Wait
  [Microsoft.Management.Infrastructure.CimInstance]$newDiskMount = Mount-DiskImage -ImagePath $PWD\$imageFile -PassThru
  $newDiskMounts.Add($newDiskMount) | Out-Null
  Initialize-Disk -Number $newDiskMount.Number -PartitionStyle GPT -PassThru -Confirm:$false

  Write-Output "::group::Formatting new Disk"
  [Microsoft.Management.Infrastructure.CimInstance]$systemPartition = New-Partition -DiskNumber $newDiskMount.Number -Size 256MB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
  Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$false
  $systemPartition | Set-Partition -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
  $systemPartition | Add-PartitionAccessPath -AssignDriveLetter
  New-Partition -DiskNumber $newDiskMount.Number -Size 128MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
  [Microsoft.Management.Infrastructure.CimInstance]$windowsPartition = New-Partition -DiskNumber $newDiskMount.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
  [Microsoft.Management.Infrastructure.CimInstance]$windowsVolume = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$false
  Write-Output "::endgroup::"

  Write-Output "Assign Drive Letters to new Partitions"
  $windowsPartition | Add-PartitionAccessPath -AssignDriveLetter
  [Microsoft.Management.Infrastructure.CimInstance]$windowsPartition = $windowsPartition | Get-Partition
  [System.IO.DriveInfo]$windowsDrive = $(Get-Partition -Volume $windowsVolume).AccessPaths[0].substring(0, 2)
  [Microsoft.Management.Infrastructure.CimInstance]$systemPartition = $systemPartition | Get-Partition
  [System.IO.DriveInfo]$systemDrive = $systemPartition.AccessPaths[0].trimend("\").replace("\?", "??")

  Write-Output "Writing Image to Drive $($windowsDrive)"
  Expand-WindowsImage -ApplyPath $windowsDrive -CheckIntegrity -ImagePath $installWim -Name $imageName -SupportEa


  $virtioDrivers | ForEach-Object {
    Write-Output "::group::Adding VirtIO Drivers"
  } {
    Write-Output $PSItem.ToString()
    Add-WindowsDriver -Path $windowsDrive -Driver $PSItem.ToString() -ForceUnsigned | Out-Null
  } {
    Write-Output "::endgroup::"
  }

  $msisToInstall | ForEach-Object {
    Write-Output "::group::Add aditional guest components"
  } {
    [string[]]$msiexecArguments = @(
      "/i",
      $PSItem,
      "/l!",
      "`"$(Join-Path -Path $logDir -ChildPath $($imageName + "." + $PSItem.Name + ".txt"))`"",
      "/qn",
      "/norestart",
      "ROOTDRIVE=$($windowsDrive)\",
      "NOCOMPANYNAME=1",
      "NOUSERNAME=1"
    )
    Write-Output "Running msiexec with $($msiexecArguments)"
    Start-Process -FilePath msiexec -ArgumentList $msiexecArguments -NoNewWindow -Wait
  } {
    Write-Output "::endgroup::"
  }

  Write-Output "::group::Add Bootloader"
  [string[]]$bcdbootArguments = @(
    "$($windowsDrive)\Windows",
    "/s", $systemDrive,
    "/v",
    "/f", "UEFI"
  )
  Write-Output "bcdboot $($bcdbootArguments)"
  Start-Process -FilePath bcdboot.exe -ArgumentList $bcdbootArguments -NoNewWindow -Wait
  Write-Output "::endgroup::"

  Write-Output "::group::Finalize Disk"
  $newDiskMount | Dismount-DiskImage
  $newDiskMounts.Remove($newDiskMount)
  [string[]]$qemuImgConvertArguments = @("convert", "-f", "vhdx", "-O", "qcow2", "`"$imageFile`"", "`"$($imageName).qcow2`"")
  Start-Process -FilePath qemu-img.exe -ArgumentList $qemuImgConvertArguments -NoNewWindow -Wait
  Write-Output "::endgroup::"
} {
  Get-ChildItem
}
