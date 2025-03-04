﻿<#PSScriptInfo

   .VERSION 1.0.2

   .AUTHOR  Will Dormann

   .LICENSEURI https://opensource.org/licenses/BSD-2-Clause

   .SYNOPSIS
   Applies a WDAC XML policy file to a Windows system

   .DESCRIPTION
   This script will apply a WDAC XML policy file to a Windows system.
   Support is provided for both Multiple Policy Format files
   as well as legacy single-policy files.

   .PARAMETER xmlpolicy
   Specifies the WDAC XML Policy file

   .PARAMETER enforce
   Flag to specify that the policy is to be enforced, rather than audited.

   .EXAMPLE
   PS> .\applywdac.ps1 -xmlpolicy driverblocklist.xml -enforce
   Apply the WDAC policy contained in driverblocklist.xml in enforcing mode

   .EXAMPLE
   PS> .\applywdac.ps1 -xmlpolicy driverblocklist.xml
   Apply the WDAC policy contained in driverblocklist.xml in audit-only mode

  .EXAMPLE
   PS> .\applywdac.ps1 -auto -enforce
   Download and install the precompiled binary policy from Microsoft

#>
Param([string]$xmlpolicy, [switch]$enforce, [switch]$auto)

try{
  Add-Type -AssemblyName System.IO.Compression.FileSystem
} catch {
  throw "This PowerShell instance is probably running in constrained mode. You will not be able to make WDAC changes."
}

function ApplyWDACPolicy {
  Param([string]$xmlpolicy, [switch]$enforce, [switch]$auto)

  if (($xmlpolicy -eq "") -and !($auto)) {
    Get-Help ApplyWDACPolicy -Detailed
    return
  }

  $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-Not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script requires administrative privileges"
    return
  }

  If ([System.Environment]::OSVersion.Version.Major -lt 10) {
    Write-Error "Windows 10 or later is required to deploy WDAC policies."
    return
  }

  if ($auto) {
    If ([System.Environment]::OSVersion.Version.Build -eq 14393) {
      Write-Error "This version of Windows is too old to successfully connect to Microsoft using HTTPS to download rules."
      Write-Warning "Driver policies must be installed on this platform using the -xml option on a local file."
      Write-Warning "See https://learn.microsoft.com/en-us/windows/security/threat-protection/windows-defender-application-control/microsoft-recommended-driver-block-rules for the current Microsoft block list"
      return
    }
    if ($enforce) {
      $policybin = "SiPolicy_Enforced.p7b"
    }
    else {
      Write-warning "This policy is being deployed in audit mode. Rules will not be enforced!"
      Write-warning "Try again with the -enforce option to make this policy enforced."
      $policybin = "SiPolicy_Audit.p7b"
    }

    $binpolicyzip = [IO.Path]::GetTempFileName() | Rename-Item -NewName { $_ -replace 'tmp$', 'zip' } -PassThru
    Write-Output "Downloading https://aka.ms/VulnerableDriverBlockList"
    Invoke-WebRequest https://aka.ms/VulnerableDriverBlockList -UseBasicParsing -OutFile $binpolicyzip
    $zipFile = [IO.Compression.ZipFile]::OpenRead($binpolicyzip)
    Write-Output "Extracting $policybin to $env:windir\system32\CodeIntegrity\SiPolicy.p7b"
    $zipFile.Entries | Where-Object Name -like $policybin | ForEach-Object { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($_, "$env:windir\system32\CodeIntegrity\SiPolicy.p7b", $true) }
    Get-ChildItem "$env:windir\system32\CodeIntegrity\SiPolicy.p7b"
    Write-Output "`nPlease Reboot to apply changes"
  }
  else {

    $xmlpolicy = (Resolve-Path "$XmlPolicy")
    $xmloutput = New-TemporaryFile

    Copy-Item -path $xmlpolicy -Destination $xmloutput -PassThru | Set-ItemProperty -name isreadonly -Value $false

    [xml]$Xml = Get-Content "$xmloutput"
    # Retrieve the namespace (needed for WDAC policies)
    $namespaceURI = $Xml.DocumentElement.NamespaceURI

    # Set up an XML namespace manager
    $namespace = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    $namespace.AddNamespace("ns", $namespaceURI)

    # Perform a namespace-aware XPath query
    $auditModeEnabled = $Xml.SelectNodes("//ns:Rules/ns:Rule/ns:Option[text()='Enabled:Audit Mode']", $namespace)

    if ($auditModeEnabled.Count -gt 0) {
        $auditmode = 1
    } else {
        $auditmode = 0
    }

    If ( $xml.SiPolicy.PolicyTypeID ) {
      Write-Output "Legacy XML format detected"
      If ([System.Environment]::OSVersion.Version.Build -eq 14393) {
        # Windows 1607 doesn't understand the MaximumFileVersion attribute.  Remove it.
        Write-Output "Removing MaximumFileVersion attributes, as this version of Windows cannot handle them..."
        $xml.SiPolicy.Filerules.ChildNodes | ForEach-Object -MemberName RemoveAttribute("MaximumFileVersion")
        Write-Output "Removing Update Policy No Reboot option, as this version of Windows cannot handle them..."
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace("ns", $xml.DocumentElement.NamespaceURI)
        $node = $xml.SelectSingleNode("//ns:Rules/ns:Rule[ns:Option='Enabled:Update Policy No Reboot']", $ns)
        if ( $node ) {
          $node.ParentNode.RemoveChild($node)
        }
        $xml.Save((Resolve-Path "$xmloutput"))
      }
      If ([System.Environment]::OSVersion.Version.Build -le 18362.900) {
        # Install on system that doesn't support multi-policy
        if ($enforce -or ($auditmode -eq 0)) {
          Set-RuleOption -FilePath "$xmloutput" -Option 3 -Delete
        }
        else {
          Write-warning "This policy is being deployed in audit mode. Rules will not be enforced!"
          Write-warning "Try again with the -enforce option to make this policy enforced."
        }
        $policytypeid = $xml.SiPolicy.PolicyTypeID
        if ($policytypeid -notmatch "{A244370E-44C9-4C06-B551-F6016E563076}") {
          Write-Warning "This WDAC policy uses a PolicyTypeID other than {A244370E-44C9-4C06-B551-F6016E563076}. Applying this policy may not have the expected outcome."
        }
        ConvertFrom-CIPolicy -xmlFilePath "$xmloutput" -BinaryFilePath ".\SiPolicy.p7b"
        $PolicyBinary = ".\SIPolicy.p7b"
        $DestinationBinary = $env:windir + "\System32\CodeIntegrity\SiPolicy.p7b"
        Copy-Item  -Path $PolicyBinary -Destination $DestinationBinary -Force
        Invoke-CimMethod -Namespace root\Microsoft\Windows\CI -ClassName PS_UpdateAndCompareCIPolicy -MethodName Update -Arguments @{FilePath = $DestinationBinary }
      }
      else {
        # Install on system that does support multi-policy
        $policytypeid = $xml.SiPolicy.PolicyTypeID
        if ($enforce -or ($auditmode -eq 0)) {
          Set-RuleOption -FilePath "$xmloutput" -Option 3 -Delete
        }
        else {
          Write-warning "This policy is being deployed in audit mode. Rules will not be enforced!"
          Write-warning "Try again with the -enforce option to make this policy enforced."
        }
        ConvertFrom-CIPolicy -xmlFilePath "$xmloutput" -BinaryFilePath ".\$policytypeid.cip"
        $PolicyBinary = ".\$policytypeid.cip"
        $DestinationFolder = $env:windir + "\System32\CodeIntegrity\CIPolicies\Active\"
        Copy-Item -Path $PolicyBinary -Destination $DestinationFolder -Force
      }
    }
    ElseIf ( $xml.SiPolicy.PolicyID ) {
      Write-Output "Multiple Policy Format XML detected"
      If ([System.Environment]::OSVersion.Version.Build -le 18362.900) {
        Write-Error "This version of Windows does not support Multiple Policy Format XML files"
        return
      }
      else {
        # Install on system that does support multi-policy
        $policytypeid = $xml.SiPolicy.PolicyID
        if ($enforce -or ($auditmode -eq 0)) {
          Set-RuleOption -FilePath "$xmloutput" -Option 3 -Delete
        }
        else {
          Write-warning "This policy is being deployed in audit mode. Rules will not be enforced!"
          Write-warning "Try again with the -enforce option to make this policy enforced."
        }
        ConvertFrom-CIPolicy -xmlFilePath "$xmloutput" -BinaryFilePath ".\$policytypeid.cip"
        $PolicyBinary = ".\$policytypeid.cip"
        $DestinationFolder = $env:windir + "\System32\CodeIntegrity\CIPolicies\Active\"
        Copy-Item -Path $PolicyBinary -Destination $DestinationFolder -Force
      }
    }
    Else {
      Write-Error "Cannot determine XML format."
      return
    }

    #Save a copy of the potentially-modified XML file for our record
    $appliedpolicy = [io.path]::GetFileNameWithoutExtension($xmlpolicy) + "-applied.xml"
    Write-Output "Copy of applied policy XML saved as: $appliedpolicy`n"
    Copy-Item -path $xmloutput -Destination $appliedpolicy -PassThru | Set-ItemProperty -name isreadonly -Value $false
    Write-Output "`nPlease Reboot to apply changes"
  }
}

if ($auto) {
  # Use binary policy from Microsoft
  if ($enforce) {
    ApplyWDACPolicy -auto -enforce
  }
  else {
    ApplyWDACPolicy -auto
  }
}
else {
  # Compile our own specified policy
  if ($enforce) {
    ApplyWDACPolicy -xmlpolicy $xmlpolicy -enforce
  }
  else {
    ApplyWDACPolicy -xmlpolicy $xmlpolicy
  }
}
