echo "MINECRAFT BEDROCK SERVER UPDATE SCRIPT, v3.3 (2024/05/26)"

# Directories
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$updateDir = "$scriptDir\update"
$backupDir = "$scriptDir\backup"
$configFile = "$scriptDir\server_paths.conf"
$logFile = "$scriptDir\update_log.txt"

# Options
$startAfterUpdateProcess = $true

# Function to log messages to a file
function Log-Message {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp - $message"
    Write-Host $logEntry
    Add-Content -Path $logFile -Value $logEntry
}

# Initialize log file
Log-Message "=== Minecraft Bedrock Server Update Script Started ==="

# Ensure update and backup directories exist
if (!(Test-Path -Path $updateDir)) { 
    New-Item -ItemType Directory -Path $updateDir
    Log-Message "Created update directory: $updateDir"
}
if (!(Test-Path -Path $backupDir)) { 
    New-Item -ItemType Directory -Path $backupDir
    Log-Message "Created backup directory: $backupDir"
}

# Check if the config file exists, create if it doesn't
if (-Not (Test-Path $configFile)) {
    Log-Message "Config file not found. Creating default config file..."
    @"
# List of Minecraft Bedrock server paths Remove the "#" and change the directory to match your server/s
#C:\Games\Minecraft Bedrock\bedrock-server1
#C:\Games\Minecraft Bedrock\bedrock-server2
#C:\Games\Minecraft Bedrock\bedrock-server3
#Etc
"@ | Out-File $configFile
    Log-Message "Config file created at: $configFile"
    Log-Message "Please edit the file to add your server paths before running the script again."
    exit 0
}

cd $updateDir

[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"

# Always perform a backup
$serverPaths = Get-Content $configFile | Where-Object { $_ -and $_ -notlike '#*' }
foreach ($serverDir in $serverPaths) {
    $serverBackupDir = "$backupDir\$(Split-Path -leaf $serverDir)"
    if (!(Test-Path -Path $serverBackupDir)) { New-Item -ItemType Directory -Path $serverBackupDir }

    Log-Message "BACKING UP CONFIGS FOR $serverDir..."
    foreach ($file in @("server.properties", "allowlist.json", "permissions.json")) {
        if (Test-Path -Path "$serverDir\$file" -PathType Leaf) {
            Copy-Item -Path "$serverDir\$file" -Destination $serverBackupDir
            Log-Message "BACKED UP $file FOR $serverDir"
        } else {
            Log-Message "$file NOT FOUND FOR $serverDir"
        }
    }
}

# Web request and update logic
try {
    # Start web request session
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    $session.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/106.0.0.0 Safari/537.36'
    $InvokeWebRequestSplatt = @{
        UseBasicParsing = $true
        Uri             = 'https://www.minecraft.net/en-us/download/server/bedrock'
        WebSession      = $session
        TimeoutSec      = 10
        Headers         = @{
            "accept"          = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"
            "accept-encoding" = "gzip, deflate, br"
            "accept-language" = "en-US,en;q=0.8"
        }
    }

    # Get data from web
    $requestResult = Invoke-WebRequest @InvokeWebRequestSplatt
    if ($requestResult -and $requestResult.Links) {
        # Parse download link and file name
        $serverurl = $requestResult.Links | select href | where {$_.href -like "https://www.minecraft.net/bedrockdedicatedserver/bin-win/bedrock-server*"}
        if ($serverurl) {
            $url = $serverurl.href
            $filename = $url.Replace("https://www.minecraft.net/bedrockdedicatedserver/bin-win/", "")
            $output = "$updateDir\$filename"
            Log-Message "NEWEST UPDATE AVAILABLE: $filename"
        } else {
            Log-Message "ERROR: Failed to find the download link on the page."
            exit 1
        }
    } else {
        Log-Message "ERROR: Web request did not return expected content."
        exit 1
    }
} catch {
    Log-Message "WEB REQUEST ERROR: $($_.Exception.Message)"
    Start-Sleep -Seconds 3
    exit
}

# Check if file already downloaded
if (!(Test-Path -Path $output -PathType Leaf)) {
    # Stop the servers if running
    foreach ($serverDir in $serverPaths) {
        $serverProcess = Get-Process -Name "bedrock_server" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$serverDir\bedrock_server.exe" }
        if ($serverProcess) {
            Stop-Process -Id $serverProcess.Id -Force
            Log-Message "STOPPED SERVER: $serverDir"
        }
    }

    # Download updated server .zip file
    Log-Message "DOWNLOADING $filename..."
    Invoke-WebRequest -Uri $url -OutFile $output
    Log-Message "Downloaded update to: $output"

    # Unzip and update servers
    foreach ($serverDir in $serverPaths) {
        Log-Message "UPDATING SERVER FILES FOR $serverDir..."
        Expand-Archive -LiteralPath $output -DestinationPath $serverDir -Force

        # Restore configuration files
        $serverBackupDir = "$backupDir\$(Split-Path -leaf $serverDir)"
        Log-Message "RESTORING CONFIGS FOR $serverDir..."
        foreach ($file in @("server.properties", "allowlist.json", "permissions.json")) {
            if (Test-Path -Path "$serverBackupDir\$file" -PathType Leaf) {
                Copy-Item -Path "$serverBackupDir\$file" -Destination $serverDir
                Log-Message "RESTORED $file FOR $serverDir"
            }
        }
    }

    # Restart servers after update
    foreach ($serverDir in $serverPaths) {
        Start-Process -FilePath "$serverDir\bedrock_server.exe" -WindowStyle Hidden
        Log-Message "RESTARTED SERVER: $serverDir"
    }
} else {
    Log-Message "UPDATE ALREADY INSTALLED..."
}

# Function to start Minecraft server in a new minimized PowerShell window and then close the window
function Start-MinecraftServer {
    param (
        [string]$serverDir
    )

    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoExit -Command `"& {Start-Process -FilePath '$serverDir\bedrock_server.exe' -WindowStyle Hidden; exit}`"" -WindowStyle Minimized
    Log-Message "STARTED SERVER: $serverDir"
}

# Start the servers if they weren't running before the update
foreach ($serverDir in $serverPaths) {
    $serverRunning = Get-Process -Name "bedrock_server" -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$serverDir\bedrock_server.exe" }
    if ($startAfterUpdateProcess) {
        if (-not $serverRunning) {
            Start-MinecraftServer -serverDir $serverDir
        } else {
            Log-Message "Server at $serverDir is already running."
        }
    }
}

Log-Message "EXITING..."
Start-Sleep -Seconds 3
Log-Message "=== Minecraft Bedrock Server Update Script Ended ==="
exit
