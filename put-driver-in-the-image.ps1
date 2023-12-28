Write-Output "Mounting the ISOs"
$windowsImageMount = Mount-DiskImage -ImagePath SERVER_EVAL_x64FRE_en-us.iso -PassThru
$windowsImageDriveLetter = ($windowsImageMount | Get-Volume).DriveLetter
$virtioImageMount = Mount-DiskImage -ImagePath virtio-win-0.1.240.iso -PassThru
$virtioImageDriveLetter = ($virtioImageMount | Get-Volume).DriveLetter

$installWim = Join-Path -Path $windowsImageDriveLetter -ChildPath "\sources\install.wim"

Write-Output "Collecting Drivers to Install"
$drivers = Get-ChildItem -Recurse -Path $virtioImageDriveLetter\*\2k22\amd64 -Include *.inf

# get the images in the .wim to patch all of them
$imagesInImage = Get-WindowsImage -ImagePath $installWim

foreach ($image in $imagesInImage) {
  Convert-WindowsImage -SourcePath $installWim -DiskLayout UEFI -Edition $image.name -Drivers $drivers.FullName
}
