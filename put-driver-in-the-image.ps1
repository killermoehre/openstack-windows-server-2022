# Enable Debug Output
$DebugPreference = 'Continue'
# Disable Confirm Prompts
$ConfirmPreference = 'None'

Write-Output "Mounting the ISOs"
$windowsImageMount = Mount-DiskImage -ImagePath C:\SERVER_EVAL_x64FRE_en-us.iso -PassThru
$windowsImageDriveLetter = ($windowsImageMount | Get-Volume).DriveLetter
$virtioImageMount = Mount-DiskImage -ImagePath C:\virtio-win-0.1.240.iso -PassThru
$virtioImageDriveLetter = ($virtioImageMount | Get-Volume).DriveLetter

$installWim = "$($windowsImageDriveLetter):\sources\install.wim"

Write-Output "Collecting Drivers to Install"
$drivers = Get-ChildItem -Recurse -Path ${virtioImageDriveLetter}:\*\2k22\amd64 -Include *.inf
$msisToInstall = @(
  "$($virtioImageDriveLetter):\virtio-win-gt-x64.msi",
  "$($virtioImageDriveLetter):\guest-agent\qemu-ga-x86_64.msi"
)

# get the images in the .wim to patch all of them
$imagesInImage = Get-WindowsImage -ImagePath $installWim

foreach ($image in $imagesInImage) {
  $imageName = $image.ImageName
  $imageFile = "${imageName}.vhdx"

  Write-Output "Creating new Hard Disk"
  qemu-img.exe create -f vhdx $imageFile 40
  $newDiskMount = Mount-DiskImage -ImagePath $PWD\$imageFile -PassThru
  $newDisk = $newDiskMount | Get-DiskImage | Get-Disk
  Initialize-Disk -Number $newDisk.Number -PartitionStyle GPT -PassThru -Confirm:$false

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
  $windowsDrive = $(Get-Partition -Volume $windowsVolume).AccessPaths[0].substring(0,2)
  $systemPartition = $systemPartition | Get-Partition
  $systemDrive = $systemPartition.AccessPaths[0].trimend("\").replace("\?", "??")

  Write-Output "Write Image to Disk"
  Expand-WindowsImage -ApplyPath $windowsDrive -CheckIntegrity -Compact -ImagePath $installWim -Name $imageName -SupportEa

  Write-Output "Add VirtIO Drivers"
  $drivers | Add-WindowsDriver -Path $windowsDrive -ForceUnsigned

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
  qemu-img.exe convert $imageFile $imageName.qcow2
}
