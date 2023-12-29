# Workaround a bug in Convert-WindowsImage https://github.com/MicrosoftDocs/Virtualization-Documentation/issues/1340
# In the module, this only checks if Hyper-V is enabled or not. The value itself isn't even used.
try {
  Get-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\WinPE' -Name Version -ErrorAction Stop | Out-Null
}
catch [System.Management.Automation.PSArgumentException] {
  New-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\WinPE' -Name Version -Value X | Out-Null
}
catch [System.Management.Automation.ItemNotFoundException] {
  New-Item -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\WinPE' | Out-Null
  New-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\WinPE' -Name Version -Value X | Out-Null
}

Write-Output "Mounting the ISOs"
$windowsImageMount = Mount-DiskImage -ImagePath C:\SERVER_EVAL_x64FRE_en-us.iso -PassThru
$windowsImageDriveLetter = ($windowsImageMount | Get-Volume).DriveLetter
$virtioImageMount = Mount-DiskImage -ImagePath C:\virtio-win-0.1.240.iso -PassThru
$virtioImageDriveLetter = ($virtioImageMount | Get-Volume).DriveLetter

$installWim = Join-Path -Path ${windowsImageDriveLetter}: -ChildPath "\sources\install.wim"

Write-Output "Collecting Drivers to Install"
$drivers = Get-ChildItem -Recurse -Path ${virtioImageDriveLetter}:\*\2k22\amd64 -Include *.inf

# get the images in the .wim to patch all of them
$imagesInImage = Get-WindowsImage -ImagePath $installWim

foreach ($image in $imagesInImage) {
  Convert-WindowsImage -SourcePath $installWim -DiskLayout UEFI -Edition $image.ImageName -Driver $drivers.FullName
}
