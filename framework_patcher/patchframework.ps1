# PowerShell script to patch framework.jar
# Requires Java and zip utilities to be installed

$ErrorActionPreference = "Stop"
$dirnow = $PWD.Path

# Find jar command from Java installation
$jarCmd = $null
$javaBin = Split-Path (Get-Command java).Source
if (Test-Path "$javaBin\jar.exe") {
    $jarCmd = "$javaBin\jar.exe"
} else {
    # Search for jar.exe in common Java installation paths
    $javaHomes = @(
        "C:\Program Files\Java",
        "C:\Program Files (x86)\Java",
        "${env:JAVA_HOME}"
    )
    foreach ($javaHome in $javaHomes) {
        if ($javaHome -and (Test-Path $javaHome)) {
            $found = Get-ChildItem -Path $javaHome -Recurse -Filter "jar.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $jarCmd = $found.FullName
                break
            }
        }
    }
}

if (-not $jarCmd) {
    Write-Host "Error: jar command not found. Please ensure Java JDK is installed and in PATH." -ForegroundColor Red
    exit 1
}

# Check if framework.jar exists
if (-not (Test-Path "$dirnow\framework.jar")) {
    Write-Host "no framework.jar detected!" -ForegroundColor Red
    exit 1
}

# Function to run APKEditor
function Invoke-APKEditor {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments=$true)]$Arguments)

    $jarfile = "$dirnow\tool\APKEditor.jar"
    $javaOpts = @("-Xmx4096M", "-Dfile.encoding=utf-8", "-Djdk.util.zip.disableZip64ExtraFieldValidation=true", "-Djdk.nio.zipfs.allowDotZipEntry=true")

    & java $javaOpts -jar $jarfile $Arguments
}

# Function to generate certificate chain patch
function Get-CertificateChainPatch {
    param([string]$lineNumber)

    return @"
    .line $lineNumber
    invoke-static {}, Lcom/android/internal/util/danda/OemPorts10TUtils;->onEngineGetCertificateChain()V
"@
}

# Function to generate instrumentation patch
function Get-InstrumentationPatch {
    param([string]$register, [int]$lineNumber)

    $returnline = $lineNumber + 1

    return @"
    invoke-static {$register}, Lcom/android/internal/util/danda/OemPorts10TUtils;->onNewApplication(Landroid/content/Context;)V

    .line $returnline

"@
}

# Function to generate bootloader spoof patch
function Get-BlSpoofPatch {
    param([string]$register)

    return @"
    invoke-static {$register}, Lcom/android/internal/util/danda/OemPorts10TUtils;->genCertificateChain([Ljava/security/cert/Certificate;)[Ljava/security/cert/Certificate;

    move-result-object $register

"@
}

# Function to escape regex special characters
function Escape-ForRegex {
    param([string]$text)

    return [regex]::Escape($text)
}

Write-Host "unpacking framework.jar"
Invoke-APKEditor -- d -i framework.jar -o frmwrk | Out-Null
Move-Item framework.jar frmwrk.jar -Force

Write-Host "patching framework.jar"

# Find required files
$keystorespiclassfile = (Get-ChildItem -Path frmwrk -Recurse -Filter "AndroidKeyStoreSpi.smali" | Select-Object -First 1).FullName.Substring("$dirnow\frmwrk\".Length)
$utilfolder = (Get-ChildItem -Path frmwrk -Recurse -Filter "util" -Directory | Where-Object { $_.FullName -match "com\\android\\internal\\util" } | Select-Object -Last 1).FullName.Substring("$dirnow\frmwrk\".Length)
$instrumentationsmali = (Get-ChildItem -Path frmwrk -Recurse -Filter "Instrumentation.smali" | Select-Object -First 1).FullName.Substring("$dirnow\frmwrk\".Length)

# Extract method signatures
$keystoreContent = Get-Content "frmwrk\$keystorespiclassfile"
$instrumentationContent = Get-Content "frmwrk\$instrumentationsmali"

$engineGetCertMethod = Escape-ForRegex ($keystoreContent | Select-String "engineGetCertificateChain\(" | Select-Object -First 1).Line.Trim()
$newAppMethod1 = Escape-ForRegex ($instrumentationContent | Select-String "newApplication\(Ljava/lang/ClassLoader;" | Select-Object -First 1).Line.Trim()
$newAppMethod2 = Escape-ForRegex ($instrumentationContent | Select-String "newApplication\(Ljava/lang/Class;" | Select-Object -First 1).Line.Trim()

# Extract and remove methods from keystore file
$inMethod = $false
$tmp_keystore = @()
$newKeystoreContent = @()

foreach ($line in $keystoreContent) {
    if ($line.Trim() -match "^$engineGetCertMethod") {
        $inMethod = $true
        $tmp_keystore += $line
    }
    elseif ($inMethod) {
        $tmp_keystore += $line
        if ($line.Trim() -eq ".end method") {
            $inMethod = $false
        }
    }
    else {
        $newKeystoreContent += $line
    }
}

Set-Content "tmp_keystore" $tmp_keystore
Set-Content "frmwrk\$keystorespiclassfile" $newKeystoreContent

# Extract and remove first instrumentation method
$inMethod = $false
$inst1 = @()
$newInstContent = @()

$instrumentationContent = Get-Content "frmwrk\$instrumentationsmali"
foreach ($line in $instrumentationContent) {
    if ($line.Trim() -match "^$newAppMethod1") {
        $inMethod = $true
        $inst1 += $line
    }
    elseif ($inMethod) {
        $inst1 += $line
        if ($line.Trim() -eq ".end method") {
            $inMethod = $false
        }
    }
    else {
        $newInstContent += $line
    }
}

Set-Content "inst1" $inst1
Set-Content "frmwrk\$instrumentationsmali" $newInstContent

# Extract and remove second instrumentation method
$inMethod = $false
$inst2 = @()
$newInstContent2 = @()

$instrumentationContent = Get-Content "frmwrk\$instrumentationsmali"
foreach ($line in $instrumentationContent) {
    if ($line.Trim() -match "^$newAppMethod2") {
        $inMethod = $true
        $inst2 += $line
    }
    elseif ($inMethod) {
        $inst2 += $line
        if ($line.Trim() -eq ".end method") {
            $inMethod = $false
        }
    }
    else {
        $newInstContent2 += $line
    }
}

Set-Content "inst2" $inst2
Set-Content "frmwrk\$instrumentationsmali" $newInstContent2

# Patch inst1
$inst1Content = Get-Content "inst1"
$inst1_insert = $inst1Content.Count - 2
$instreg = ($inst1Content | Select-String "Landroid/app/Application;->attach\(Landroid/content/Context;\)V").Line -replace '.*\{([^}]+)\}.*', '$1'
$instline = [int](($inst1Content | Select-String "\.line" | Select-Object -Last 1).Line -replace '.*\.line\s+(\d+).*', '$1') + 1
$instrumentationPatch = Get-InstrumentationPatch $instreg $instline

$inst1Content = @($inst1Content[0..($inst1_insert-1)]) + $instrumentationPatch.Split("`n") + @($inst1Content[$inst1_insert..($inst1Content.Count-1)])
Set-Content "inst1" $inst1Content

# Patch inst2
$inst2Content = Get-Content "inst2"
$inst2_insert = $inst2Content.Count - 2
$instreg = ($inst2Content | Select-String "Landroid/app/Application;->attach\(Landroid/content/Context;\)V").Line -replace '.*\{([^}]+)\}.*', '$1'
$instline = [int](($inst2Content | Select-String "\.line" | Select-Object -Last 1).Line -replace '.*\.line\s+(\d+).*', '$1') + 1
$instrumentationPatch = Get-InstrumentationPatch $instreg $instline

$inst2Content = @($inst2Content[0..($inst2_insert-1)]) + $instrumentationPatch.Split("`n") + @($inst2Content[$inst2_insert..($inst2Content.Count-1)])
Set-Content "inst2" $inst2Content

# Patch keystore
$tmp_keystoreContent = Get-Content "tmp_keystore"
$kstoreline = [int](($tmp_keystoreContent | Select-String "\.line" | Select-Object -First 1).Line -replace '.*\.line\s+(\d+).*', '$1') - 2
$certificatechainPatch = Get-CertificateChainPatch $kstoreline

$tmp_keystoreContent = @($tmp_keystoreContent[0..3]) + $certificatechainPatch.Split("`n") + @($tmp_keystoreContent[4..($tmp_keystoreContent.Count-1)])
Set-Content "tmp_keystore" $tmp_keystoreContent

# Add bootloader spoof patch
$tmp_keystoreContent = Get-Content "tmp_keystore"
$lastaput = ($tmp_keystoreContent | Select-String "aput-object" | Select-Object -Last 1).Line
$leafcert = ($lastaput -replace '.*aput-object\s+([^,]+).*', '$1').Trim()
$blspoof_insert = ($tmp_keystoreContent | Select-String -Pattern ([regex]::Escape($lastaput)) | Select-Object -First 1).LineNumber

$tmp_keystoreContent = @($tmp_keystoreContent[0..($blspoof_insert-1)]) + (Get-BlSpoofPatch $leafcert).Split("`n") + @($tmp_keystoreContent[$blspoof_insert..($tmp_keystoreContent.Count-1)])
Set-Content "tmp_keystore" $tmp_keystoreContent

# Append patched methods back
Add-Content "frmwrk\$instrumentationsmali" (Get-Content "inst1")
Add-Content "frmwrk\$instrumentationsmali" (Get-Content "inst2")
Add-Content "frmwrk\$keystorespiclassfile" (Get-Content "tmp_keystore")

# Cleanup temporary files
Remove-Item inst1, inst2, tmp_keystore -Force

Write-Host "repacking framework.jar classes"

Invoke-APKEditor -- b -i frmwrk | Out-Null

# Extract classes*.dex from the output APK using Java's jar command
& $jarCmd xf frmwrk_out.apk
Move-Item classes*.dex frmwrk\ -Force

# Remove cache and add PIF classes
if (Test-Path "frmwrk\.cache") {
    Remove-Item "frmwrk\.cache" -Recurse -Force
}

$patchclass = (Get-ChildItem "frmwrk\classes*.dex").Count + 1
Copy-Item "PIF\classes.dex" "frmwrk\classes${patchclass}.dex"

# Create the JAR file
Push-Location frmwrk
Write-Host "zipping class"

# Use Java's jar command to create the archive with store compression
& $jarCmd -cfM0 "$dirnow\frmwrk.jar" classes*.dex

Pop-Location

Write-Host "zipaligning framework.jar"

# Check if zipalign is available
try {
    & zipalign -v 4 frmwrk.jar framework.jar | Out-Null
} catch {
    Write-Host "Warning: zipalign not found. Skipping alignment step." -ForegroundColor Yellow
    Move-Item frmwrk.jar framework.jar -Force
}

# Cleanup
Remove-Item frmwrk.jar, frmwrk_out.apk -Force -ErrorAction SilentlyContinue
Remove-Item frmwrk -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Done! framework.jar has been patched successfully." -ForegroundColor Green
