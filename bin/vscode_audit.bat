@echo off

REM Script: vscode_audit.bat
REM Author: zuykn.io
REM
REM zuykn Private Commercial Use License Version 1.0
REM Copyright (c) 2023–2025 zuykn — https://zuykn.io
REM
REM Use of this file is governed by the zuykn Private Commercial Use License
REM included in the LICENSE file in the project root.

SETLOCAL ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

REM Config
set "SCRIPT_NAME=%~nx0"
set "USERNAME=%USERNAME%"
if "%USERNAME%"=="" set "USERNAME=unknown"
set "CHUNK_SIZE=5"

REM ISO8601 timestamp
set "dt=%DATE%"
set "tm=%TIME: =0%"

set "dt=%dt:Mon =%"
set "dt=%dt:Tue =%"
set "dt=%dt:Wed =%"
set "dt=%dt:Thu =%"
set "dt=%dt:Fri =%"
set "dt=%dt:Sat =%"
set "dt=%dt:Sun =%"

for /f "tokens=1-3 delims=/-. " %%a in ("%dt%") do (
    set "p1=%%a" & set "p2=%%b" & set "p3=%%c"
)

if !p3! GTR 100 (
    if !p1! GTR 12 (
        set "DD=!p1!" & set "MM=!p2!" & set "YYYY=!p3!"
    ) else (
        set "MM=!p1!" & set "DD=!p2!" & set "YYYY=!p3!"
    )
) else (
    set "YYYY=!p1!" & set "MM=!p2!" & set "DD=!p3!"
)

if "!MM:~1,1!"=="" set "MM=0!MM!"
if "!DD:~1,1!"=="" set "DD=0!DD!"

set "HH=%tm:~0,2%"
set "MIN=%tm:~3,2%"
set "SS=%tm:~6,2%"

REM Timezone offset
set "TZ_BIAS="
for /f "tokens=3" %%a in ('reg query "HKLM\System\CurrentControlSet\Control\TimeZoneInformation" /v Bias 2^>nul ^| findstr "REG_DWORD"') do (
    set "TZ_HEX=%%a"
)

if defined TZ_HEX (
    set "TZ_HEX=!TZ_HEX:0x=!"
    set /a "TZ_BIAS=0x!TZ_HEX!" 2>nul
    if errorlevel 1 set "TZ_BIAS=0"
) else (
    set "TZ_BIAS=0"
)

if not defined TZ_BIAS set "TZ_BIAS=0"
if "!TZ_BIAS!"=="" set "TZ_BIAS=0"
set /a "TZ_HOURS=TZ_BIAS / -60" 2>nul || set "TZ_HOURS=0"
set /a "TZ_MINS=(TZ_BIAS %% 60) * -1" 2>nul || set "TZ_MINS=0"
if !TZ_MINS! LSS 0 set /a "TZ_MINS=TZ_MINS * -1" 2>nul
if !TZ_HOURS! GEQ 0 (
    set "TZ_SIGN=+"
) else (
    set "TZ_SIGN=-"
    set /a "TZ_HOURS=TZ_HOURS * -1"
)
if !TZ_HOURS! LSS 10 set "TZ_HOURS=0!TZ_HOURS!"
if !TZ_MINS! LSS 10 set "TZ_MINS=0!TZ_MINS!"

set "TIMESTAMP=!YYYY!-!MM!-!DD!T!HH!:!MIN!:!SS!!TZ_SIGN!!TZ_HOURS!!TZ_MINS!"

set "CHUNK_SET_ID=%RANDOM%%RANDOM%-%HH%%MIN%%SS%"
set "CHUNK_SET_ID_EXTENSIONS=%CHUNK_SET_ID%"
set "CHUNK_SET_ID_SESSIONS=%RANDOM%%RANDOM%-%HH%%MIN%%SS%"

REM Paths
set "VSCODE_USER_DIR="
set "VSCODE_EXTENSIONS_DIR="

REM Variant tracking
set "CURRENT_VARIANT="
set "CURRENT_PRODUCT_NAME="
set "COLLECT_FULL_DATA=1"

REM Collection flags
set "COLLECT_SETTINGS=1"
set "COLLECT_ARGV=1"
set "COLLECT_WORKSPACE_SETTINGS=1"
set "COLLECT_TASKS=1"
set "COLLECT_LAUNCH=1"
set "COLLECT_DEVCONTAINER=1"
set "COLLECT_INSTALLATION=1"
set "COLLECT_EXTENSIONS=1"
set "COLLECT_ACTIVE_SESSION=1"
set "COLLECT_EXTENSION_METADATA=1"
set "GRANT_SSH_ACCESS=0"
set "CUSTOM_USER_DIR="
set "CUSTOM_EXTENSIONS_DIR="
set "MAX_WORKSPACE_DEPTH=5"
set "WORKSPACE_SEARCH_PATHS="
set "COLLECT_ALL_USERS=1"
set "TARGET_USER="

call :parse_args %*
if errorlevel 2 exit /b 0
if errorlevel 1 exit /b 1

goto main_execution

:log_error
echo ERROR: %~1 1>&2
exit /b 0

:usage
echo Usage: %SCRIPT_NAME% [options]
echo.
echo Description: VS Code Security Audit Script - Collects VS Code data for security monitoring
echo             Produces exactly 9 sourcetypes in NDJSON format for Splunk ingestion:
echo             - vscode:settings          (user settings.json)
echo             - vscode:argv              (startup arguments)
echo             - vscode:workspace_settings (project-level settings)
echo             - vscode:tasks             (project-level tasks.json)
echo             - vscode:launch            (project-level launch.json)
echo             - vscode:devcontainer      (project-level devcontainer.json)
echo             - vscode:installation      (VS Code client/server installations)
echo             - vscode:extensions        (installed extensions inventory)
echo             - vscode:sessions          (active, recent, and historical SSH sessions)
echo.
echo Options:
echo     -user ^<name^>               Collect only for specific user (default: all users)
echo     -user-dir ^<path^>           Override VS Code user directory path
echo     -extensions-dir ^<path^>     Override extensions directory path
echo     -workspace-paths ^<paths^>   Custom workspace search paths (comma-separated)  
echo     -max-workspace-depth ^<num^> Maximum directory depth for workspace search (default: 5)
echo.
echo Disable Collections:
echo     -no-settings                Skip settings.json collection
echo     -no-argv                    Skip argv.json collection
echo     -no-workspace-settings      Skip workspace-level settings.json
echo     -no-tasks                   Skip workspace-level tasks.json
echo     -no-launch                  Skip workspace-level launch.json
echo     -no-devcontainer            Skip workspace-level devcontainer.json
echo     -no-installation            Skip VS Code installation collection
echo     -no-extensions              Skip extensions collection
echo     -no-sessions                Skip session collection (includes active, recent, and historical)
echo.
echo SSH Config SYSTEM Read Access:
echo     -grant-ssh-config-read      Grant SYSTEM read access to each user's .ssh\config (enables SSH username detection)
echo.
echo Examples:
echo     %SCRIPT_NAME%                    # Collect all 9 sourcetypes for all users
echo     %SCRIPT_NAME% -user admin        # Collect only for admin user
echo     %SCRIPT_NAME% -no-extensions     # Skip extensions collection
exit /b %~1

:parse_args
:parse_loop
if "%~1"=="" goto parse_done
set "ARG=%~1"
if /I "%ARG%"=="-h" goto usage_ok
if /I "%ARG%"=="-help" goto usage_ok
if /I "%ARG%"=="--help" goto usage_ok

if /I "%ARG%"=="-user" (
    if "%~2"=="" (
        call :log_error "-user requires a username argument. Example: -user admin"
        exit /b 1
    )
    set "TARGET_USER=%~2"
    set "COLLECT_ALL_USERS=0"
    shift
    shift
    goto parse_loop
)

if /I "%ARG%"=="-user-dir" (
    if "%~2"=="" (
        call :log_error "-user-dir requires a path argument"
        exit /b 1
    )
    set "CUSTOM_USER_DIR=%~2"
    shift
    shift
    goto parse_loop
)

if /I "%ARG%"=="-extensions-dir" (
    if "%~2"=="" (
        call :log_error "-extensions-dir requires a path argument"
        exit /b 1
    )
    set "CUSTOM_EXTENSIONS_DIR=%~2"
    shift
    shift
    goto parse_loop
)

if /I "%ARG%"=="-workspace-paths" (
    if "%~2"=="" (
        call :log_error "-workspace-paths requires comma-separated paths"
        exit /b 1
    )
    set "WORKSPACE_SEARCH_PATHS=%~2"
    shift
    shift
    goto parse_loop
)

if /I "%ARG%"=="-max-workspace-depth" (
    if "%~2"=="" (
        call :log_error "-max-workspace-depth requires a number argument"
        exit /b 1
    )
    set "MAX_WORKSPACE_DEPTH=%~2"
    shift
    shift
    goto parse_loop
)


if /I "%ARG%"=="-no-settings" (
    set "COLLECT_SETTINGS=0"
    shift
    goto parse_loop
)

if /I "%ARG%"=="-no-extensions" (
    set "COLLECT_EXTENSIONS=0"
    shift
    goto parse_loop
)

if /I "%ARG%"=="-no-argv" (
    set "COLLECT_ARGV=0"
    shift
    goto parse_loop
)

if /I "%ARG%"=="-no-workspace-settings" (
    set "COLLECT_WORKSPACE_SETTINGS=0"
    shift
    goto parse_loop
)

if /I "%ARG%"=="-no-tasks" (
    set "COLLECT_TASKS=0"
    shift
    goto parse_loop
)

if /I "%ARG%"=="-no-launch" (
    set "COLLECT_LAUNCH=0"
    shift
    goto parse_loop
)

if /I "%ARG%"=="-no-devcontainer" (
    set "COLLECT_DEVCONTAINER=0"
    shift
    goto parse_loop
)

if /I "%ARG%"=="-no-installation" (
    set "COLLECT_INSTALLATION=0"
    shift
    goto parse_loop
)

if /I "%ARG%"=="-no-sessions" (
    set "COLLECT_ACTIVE_SESSION=0"
    shift
    goto parse_loop
)

if /I "%ARG%"=="-grant-ssh-config-read" (
    set "GRANT_SSH_ACCESS=1"
    shift
    goto parse_loop
)

if "%ARG:~0,1%"=="-" (
    call :log_error "Unknown flag: %ARG%"
    exit /b 1
)

call :log_error "Unexpected argument: %ARG%"
exit /b 1

:usage_ok
call :usage 0
exit /b 2

:parse_done
exit /b 0

:get_users_to_process
if "%COLLECT_ALL_USERS%"=="0" (
    if not "%TARGET_USER%"=="" (
        set "USERS_LIST=%TARGET_USER%"
        exit /b 0
    )
)

set "USERS_LIST="

call :get_existing_drives
for %%d in (!EXISTING_DRIVES!) do (
    if exist "%%d\Users\" (
        for /d %%u in ("%%d\Users\*") do (
            set "user_name=%%~nxu"
            REM Exclude system accounts
            set "last_char=!user_name:~-1!"
            if not "!last_char!"=="$" (
                if /i not "!user_name!"=="Public" if /i not "!user_name!"=="Default" if /i not "!user_name!"=="Default User" if /i not "!user_name!"=="All Users" (
                    REM Check if in list
                    echo !USERS_LIST! | findstr /i /c:"!user_name!" >nul 2>nul
                    if errorlevel 1 (
                        REM Add user
                        if "!USERS_LIST!"=="" (
                            set "USERS_LIST=!user_name!"
                        ) else (
                            set "USERS_LIST=!USERS_LIST! !user_name!"
                        )
                    )
                )
            )
        )
    )
)

if "!USERS_LIST!"=="" (
    set "USERS_LIST=%USERNAME%"
) else (
    REM Check if already in list
    echo " !USERS_LIST! " | findstr /i /c:" %USERNAME% " >nul 2>nul
    if errorlevel 1 (
        set "USERS_LIST=!USERS_LIST! %USERNAME%"
    )
)

exit /b 0

:get_user_home
set "target_user=%~1"

if "%target_user%"=="%USERNAME%" (
    if defined USERPROFILE (
        set "USER_HOME_RESULT=%USERPROFILE%"
        exit /b 0
    )
)

call :get_existing_drives
for %%d in (!EXISTING_DRIVES!) do (
    if exist "%%d\Users\%target_user%" (
        set "USER_HOME_RESULT=%%d\Users\%target_user%"
        exit /b 0
    )
)

for /f "tokens=*" %%k in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" 2^>nul ^| findstr "HKEY"') do (
    for /f "tokens=3" %%v in ('reg query "%%k" /v ProfileImagePath 2^>nul ^| findstr "ProfileImagePath"') do (
        set "profile_path=%%v"
        for %%p in ("!profile_path!") do (
            set "profile_user=%%~nxp"
            if /I "!profile_user!"=="%target_user%" (
                set "USER_HOME_RESULT=!profile_path!"
                exit /b 0
            )
        )
    )
)

exit /b 1

:get_variant_config
REM Variant configuration
REM Args: variant_id
REM Returns: Sets VARIANT_USER_DIR_SUFFIX, VARIANT_EXTENSIONS_DIR_SUFFIX, COLLECT_FULL_DATA
set "gvc_variant=%~1"
set "VARIANT_USER_DIR_SUFFIX="
set "VARIANT_EXTENSIONS_DIR_SUFFIX="
set "COLLECT_FULL_DATA=0"

if "!gvc_variant!"=="stable" (
    set "VARIANT_USER_DIR_SUFFIX=Code"
    set "VARIANT_EXTENSIONS_DIR_SUFFIX=.vscode"
    set "COLLECT_FULL_DATA=1"
    exit /b 0
)
if "!gvc_variant!"=="insiders" (
    set "VARIANT_USER_DIR_SUFFIX=Code - Insiders"
    set "VARIANT_EXTENSIONS_DIR_SUFFIX=.vscode-insiders"
    set "COLLECT_FULL_DATA=0"
    exit /b 0
)
if "!gvc_variant!"=="vscodium" (
    set "VARIANT_USER_DIR_SUFFIX=VSCodium"
    set "VARIANT_EXTENSIONS_DIR_SUFFIX=.vscode-oss"
    set "COLLECT_FULL_DATA=0"
    exit /b 0
)
if "!gvc_variant!"=="cursor" (
    set "VARIANT_USER_DIR_SUFFIX=Cursor"
    set "VARIANT_EXTENSIONS_DIR_SUFFIX=.cursor"
    set "COLLECT_FULL_DATA=0"
    exit /b 0
)
if "!gvc_variant!"=="code-oss" (
    set "VARIANT_USER_DIR_SUFFIX=Code - OSS"
    set "VARIANT_EXTENSIONS_DIR_SUFFIX=.vscode-oss"
    set "COLLECT_FULL_DATA=0"
    exit /b 0
)
if "!gvc_variant!"=="windsurf" (
    set "VARIANT_USER_DIR_SUFFIX=Windsurf"
    set "VARIANT_EXTENSIONS_DIR_SUFFIX=.windsurf"
    set "COLLECT_FULL_DATA=0"
    exit /b 0
)
exit /b 1

:get_product_name
REM Get official product name for a variant
REM Args: variant_id
REM Returns: PRODUCT_NAME_RESULT
set "gpn_variant=%~1"
set "PRODUCT_NAME_RESULT=Unknown"
if "!gpn_variant!"=="stable" set "PRODUCT_NAME_RESULT=Visual Studio Code"
if "!gpn_variant!"=="insiders" set "PRODUCT_NAME_RESULT=Visual Studio Code - Insiders"
if "!gpn_variant!"=="vscodium" set "PRODUCT_NAME_RESULT=VSCodium"
if "!gpn_variant!"=="cursor" set "PRODUCT_NAME_RESULT=Cursor"
if "!gpn_variant!"=="code-oss" set "PRODUCT_NAME_RESULT=Code - OSS"
if "!gpn_variant!"=="windsurf" set "PRODUCT_NAME_RESULT=Windsurf"
exit /b 0

:detect_variant_paths
REM Detect paths for a specific VS Code variant
REM Args: target_user variant_id
REM Sets: VSCODE_USER_DIR, VSCODE_EXTENSIONS_DIR, CURRENT_VARIANT, CURRENT_PRODUCT_NAME, COLLECT_FULL_DATA
set "dvp_user=%~1"
set "dvp_variant=%~2"

call :get_user_home "%dvp_user%"
if errorlevel 1 exit /b 1
set "user_home=!USER_HOME_RESULT!"

REM Get variant configuration
call :get_variant_config "!dvp_variant!"
if errorlevel 1 exit /b 1

set "CURRENT_VARIANT=!dvp_variant!"
call :get_product_name "!dvp_variant!"
set "CURRENT_PRODUCT_NAME=!PRODUCT_NAME_RESULT!"

REM Set user directory path
if not "%CUSTOM_USER_DIR%"=="" (
    set "VSCODE_USER_DIR=%CUSTOM_USER_DIR%"
) else (
    set "VSCODE_USER_DIR=!user_home!\AppData\Roaming\!VARIANT_USER_DIR_SUFFIX!\User"
)

REM Set extensions directory path
if not "%CUSTOM_EXTENSIONS_DIR%"=="" (
    set "VSCODE_EXTENSIONS_DIR=%CUSTOM_EXTENSIONS_DIR%"
) else (
    set "VSCODE_EXTENSIONS_DIR=!user_home!\!VARIANT_EXTENSIONS_DIR_SUFFIX!\extensions"
)

exit /b 0

:detect_vscode_paths
REM Legacy function - detects paths for VS Code Stable only
REM Kept for backward compatibility
set "target_user=%~1"
call :detect_variant_paths "!target_user!" "stable"
exit /b !errorlevel!

:check_file
set "file_path=%~1"
if exist "%file_path%" (
    exit /b 0
) else (
    exit /b 1
)

:get_existing_drives
set "EXISTING_DRIVES="
if "!EXISTING_DRIVES!"=="" (
    for %%d in (A: B: C: D: E: F: G: H: I: J: K: L: M: N: O: P: Q: R: S: T: U: V: W: X: Y: Z:) do (
        if exist "%%d\" (
            if "!EXISTING_DRIVES!"=="" (
                set "EXISTING_DRIVES=%%d"
            ) else (
                set "EXISTING_DRIVES=!EXISTING_DRIVES! %%d"
            )
        )
    )
)
exit /b 0

:capitalize_drive_letter
set "input_path=%~1"
if not "!input_path:~1,1!"==":" (
    REM Not a drive pattern, normalize slashes and return
    set "input_path=!input_path:/=\!"
    set "CAPITALIZED_PATH_RESULT=!input_path!"
    exit /b 0
)

set "drive_letter=!input_path:~0,1!"

for %%U in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if "!drive_letter!"=="%%U" (
        set "input_path=!input_path:/=\!"
        set "CAPITALIZED_PATH_RESULT=!input_path!"
        exit /b 0
    )
)

for %%D in (!EXISTING_DRIVES!) do (
    set "enum_letter=%%D"
    set "enum_letter=!enum_letter:~0,1!"
    if /i "!drive_letter!"=="!enum_letter!" (
        set "lowercase=abcdefghijklmnopqrstuvwxyz"
        set "uppercase=ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        for /l %%i in (0,1,25) do (
            if /i "!drive_letter!"=="!lowercase:~%%i,1!" (
                set "input_path=!uppercase:~%%i,1!!input_path:~1!"
                goto capitalize_done
            )
        )
    )
)

:capitalize_done
set "input_path=!input_path:/=\!"
set "CAPITALIZED_PATH_RESULT=!input_path!"
exit /b 0

:check_security_patterns
set "file_path=%~1"
if not exist "%file_path%" exit /b 0

findstr /C:"BEGIN RSA PRIVATE KEY" /C:"BEGIN OPENSSH PRIVATE KEY" /C:"BEGIN PRIVATE KEY" /C:"password.*:" /C:"privateKey" /C:"passphrase" "%file_path%" >nul 2>&1
if not errorlevel 1 exit /b 1

exit /b 0

:process_json_file
set "json_file_path=%~1"
set "target_user=%~2"

call :check_file "%json_file_path%"
if errorlevel 1 exit /b 0

call :check_security_patterns "%json_file_path%"
if errorlevel 1 exit /b 0

set "escaped_content="
set "first_line=1"

for /f "delims=" %%l in ('findstr /r ".*" "%json_file_path%" 2^>nul') do (
    set "line=%%l"
    
    REM Remove UTF-8 BOM from first line if present
    REM BOM (EF BB BF) displays as ∩╗┐ in Windows console
    if !first_line!==1 (
        REM Strip BOM by checking if line starts with { after position 3
        REM This handles the common case of JSON files with BOM
        set "char_at_3=!line:~3,1!"
        set "char_at_0=!line:~0,1!"
        if "!char_at_3!"=="{" if not "!char_at_0!"=="{" set "line=!line:~3!"
        if "!char_at_3!"=="[" if not "!char_at_0!"=="[" set "line=!line:~3!"
    )
    
    REM Escape characters for JSON output
    set "line=!line:\=\\!"
    set "line=!line:"=\"!"
    set "line=!line:	=\t!"
    
    if !first_line!==1 (
        set "escaped_content=!line!"
        set "first_line=0"
    ) else (
        set "escaped_content=!escaped_content!\n!line!"
    )
)

if not defined escaped_content set "escaped_content={}"

call :capitalize_drive_letter "!json_file_path!"
set "json_file_path=!CAPITALIZED_PATH_RESULT!"
set "safe_file_path=!json_file_path:\=\\!"

echo {"timestamp":"!TIMESTAMP!","product_name":"!CURRENT_PRODUCT_NAME!","user":"!target_user!","file_path":"!safe_file_path!","content":"!escaped_content!"}
exit /b 0

:output_extensions_chunk
set "chunk_user=%~1"
set "chunk_number=%~2"

set "extensions_array=!extensions_array!]"

echo {"timestamp":"!TIMESTAMP!","product_name":"!CURRENT_PRODUCT_NAME!","user":"!chunk_user!","chunk_set_id_extensions":"!CHUNK_SET_ID_EXTENSIONS!","chunk":!chunk_number!,"items":!extensions_array!}

exit /b 0

:reset_extensions_chunk
set /a "current_chunk+=1"
set "extensions_in_chunk=0"
set "extensions_array=["
set "first_in_chunk=1"
exit /b 0

:get_search_paths
set "user_home=%~1"
REM All paths scanned at MAX_WORKSPACE_DEPTH (default 5)
set "SEARCH_PATHS=!user_home!\workspace,!user_home!\projects,!user_home!\code,!user_home!\dev,!user_home!\developer,!user_home!\src,!user_home!\git,!user_home!\www,!user_home!\sites,!user_home!\source\repos,!user_home!\documents,!user_home!\desktop,!user_home!\downloads"

if not "%WORKSPACE_SEARCH_PATHS%"=="" (
    set "SEARCH_PATHS=%WORKSPACE_SEARCH_PATHS%"
)

set "SEARCH_PATHS_RESULT=!SEARCH_PATHS!"
exit /b 0

:find_workspace_vscode_dirs
REM Depth-limited recursive scan for .vscode directories
REM Uses recursive calls with depth tracking to avoid full dir /s
set "fwvd_path=%~1"
set "fwvd_user=%~2"

if not exist "!fwvd_path!" exit /b 0

REM Start recursive scan at depth 0
call :scan_dir_for_vscode "!fwvd_path!" "!fwvd_user!" 0
exit /b 0

:scan_dir_for_vscode
REM Recursive function to scan for .vscode directories with depth limiting
REM IMPORTANT: Only use parameters %~1, %~2, %~3 and for variable %%d
REM Do NOT store to intermediate variables - they get corrupted by recursion

REM Check for .vscode and .devcontainer in this directory
call :check_vscode_dir "%~1\.vscode" "%~2"
call :check_devcontainer_dir "%~1\.devcontainer" "%~2"

REM Stop if we've reached max depth
if %~3 GEQ %MAX_WORKSPACE_DEPTH% exit /b 0

REM Calculate next depth using temp var that's immediately used
set /a "sdv_nd=%~3+1"

REM Scan subdirectories - use %%d directly, never store path to variable
for /f "delims=" %%d in ('dir /b /ad "%~1" 2^>nul') do (
    REM Skip hidden directories (start with .) - check first char of %%d
    set "sdv_fc=%%d"
    setlocal enabledelayedexpansion
    set "sdv_fc=!sdv_fc:~0,1!"
    if not "!sdv_fc!"=="." (
        if /i not "%%d"=="node_modules" (
            endlocal
            call :scan_dir_for_vscode "%~1\%%d" "%~2" !sdv_nd!
        ) else (
            endlocal
        )
    ) else (
        endlocal
    )
)
exit /b 0

:check_vscode_dir
REM Check a .vscode directory and process files if it exists
REM Uses SEEN_WORKSPACE_FILES for deduplication (prevents duplicates from workspaceStorage + directory scan)
set "cvd_vscode_path=%~1"
set "cvd_user=%~2"
if not exist "!cvd_vscode_path!" exit /b 0
if "%COLLECT_WORKSPACE_SETTINGS%"=="1" (
    if exist "!cvd_vscode_path!\settings.json" (
        set "cvd_file=!cvd_vscode_path!\settings.json"
        call :check_seen_file "!cvd_file!"
        if not defined CVD_FILE_SEEN (
            call :process_json_file "!cvd_file!" "!cvd_user!"
            set "SEEN_WORKSPACE_FILES=!SEEN_WORKSPACE_FILES!|!cvd_file!|"
        )
    )
)
if "%COLLECT_TASKS%"=="1" (
    if exist "!cvd_vscode_path!\tasks.json" (
        set "cvd_file=!cvd_vscode_path!\tasks.json"
        call :check_seen_file "!cvd_file!"
        if not defined CVD_FILE_SEEN (
            call :process_json_file "!cvd_file!" "!cvd_user!"
            set "SEEN_WORKSPACE_FILES=!SEEN_WORKSPACE_FILES!|!cvd_file!|"
        )
    )
)
if "%COLLECT_LAUNCH%"=="1" (
    if exist "!cvd_vscode_path!\launch.json" (
        set "cvd_file=!cvd_vscode_path!\launch.json"
        call :check_seen_file "!cvd_file!"
        if not defined CVD_FILE_SEEN (
            call :process_json_file "!cvd_file!" "!cvd_user!"
            set "SEEN_WORKSPACE_FILES=!SEEN_WORKSPACE_FILES!|!cvd_file!|"
        )
    )
)
exit /b 0

:check_devcontainer_dir
REM Check a .devcontainer directory and process devcontainer.json if it exists
REM Uses SEEN_WORKSPACE_FILES for deduplication
set "cdd_path=%~1"
set "cdd_user=%~2"
if not exist "!cdd_path!" exit /b 0
if "%COLLECT_DEVCONTAINER%"=="1" (
    if exist "!cdd_path!\devcontainer.json" (
        set "cdd_file=!cdd_path!\devcontainer.json"
        call :check_seen_file "!cdd_file!"
        if not defined CVD_FILE_SEEN (
            call :process_json_file "!cdd_file!" "!cdd_user!"
            set "SEEN_WORKSPACE_FILES=!SEEN_WORKSPACE_FILES!|!cdd_file!|"
        )
    )
)
exit /b 0

:check_seen_file
REM Check if file path is in SEEN_WORKSPACE_FILES
REM Sets CVD_FILE_SEEN if found, clears it otherwise
set "csf_file=%~1"
set "CVD_FILE_SEEN="
if not defined SEEN_WORKSPACE_FILES exit /b 0
REM Use string substitution to check - if replacing the path changes the string, it was found
set "csf_test=!SEEN_WORKSPACE_FILES:|%csf_file%|=!"
if not "!csf_test!"=="!SEEN_WORKSPACE_FILES!" set "CVD_FILE_SEEN=1"
exit /b 0

:output_session_chunk
set "session_chunk_user=%~1"
set "session_chunk_number=%~2"

set "session_items=!active_sessions_array!]"

echo {"timestamp":"!TIMESTAMP!","product_name":"!CURRENT_PRODUCT_NAME!","user":"!session_chunk_user!","chunk_set_id_sessions":"!CHUNK_SET_ID_SESSIONS!","chunk":!session_chunk_number!,"items":!session_items!}
exit /b 0

:reset_session_chunk
set /a "current_chunk+=1"
set "sessions_in_chunk=0"
set "active_sessions_array=["
set "active_sessions_first=1"
exit /b 0

:process_installation
REM Process installation for the CURRENT variant only
REM Uses CURRENT_VARIANT global set by detect_variant_paths()
set "target_user=%~1"
if "%COLLECT_INSTALLATION%"=="0" exit /b 0

call :get_user_home "%target_user%"
if errorlevel 1 exit /b 0
set "user_home=!USER_HOME_RESULT!"

set "installations_array="
set "array_first=1"
set "SEEN_INSTALL_PATHS="

REM Get variant-specific installation paths based on CURRENT_VARIANT
if "!CURRENT_VARIANT!"=="stable" (
    REM System-wide installations (Program Files)
    call :get_existing_drives
    for %%d in (!EXISTING_DRIVES!) do (
        call :process_variant_installation "%%d\Program Files\Microsoft VS Code\bin\code.cmd" "%%d\Program Files\Microsoft VS Code" "Visual Studio Code" "!target_user!" "!user_home!"
        call :process_variant_installation "%%d\Program Files (x86)\Microsoft VS Code\bin\code.cmd" "%%d\Program Files (x86)\Microsoft VS Code" "Visual Studio Code" "!target_user!" "!user_home!"
    )
    REM User installation
    call :process_variant_installation "!user_home!\AppData\Local\Programs\Microsoft VS Code\bin\code.cmd" "!user_home!\AppData\Local\Programs\Microsoft VS Code" "Visual Studio Code" "!target_user!" "!user_home!"
    
    REM VS Code Server installations (only for stable variant)
    set "server_base_dir=!user_home!\.vscode-server"
    if exist "!server_base_dir!" (
        REM Check for CLI-based server installations
        if exist "!server_base_dir!\cli\servers" (
            for /d %%s in ("!server_base_dir!\cli\servers\Stable-*") do (
                set "server_dir=%%s"
                set "product_json=!server_dir!\server\product.json"
                if exist "!product_json!" (
                    call :process_server_installation "!server_dir!" "!product_json!" "!target_user!"
                )
            )
        )
        REM Check for legacy server installations (older format)
        if exist "!server_base_dir!\bin" (
            for /d %%s in ("!server_base_dir!\bin\*") do (
                set "server_dir=%%s"
                set "product_json=!server_dir!\product.json"
                if exist "!product_json!" (
                    call :process_server_installation "!server_dir!" "!product_json!" "!target_user!"
                )
            )
        )
    )
)
if "!CURRENT_VARIANT!"=="insiders" (
    REM System-wide installations (Program Files)
    call :get_existing_drives
    for %%d in (!EXISTING_DRIVES!) do (
        call :process_variant_installation "%%d\Program Files\Microsoft VS Code Insiders\bin\code-insiders.cmd" "%%d\Program Files\Microsoft VS Code Insiders" "Visual Studio Code - Insiders" "!target_user!" "!user_home!"
        call :process_variant_installation "%%d\Program Files (x86)\Microsoft VS Code Insiders\bin\code-insiders.cmd" "%%d\Program Files (x86)\Microsoft VS Code Insiders" "Visual Studio Code - Insiders" "!target_user!" "!user_home!"
    )
    REM User installation
    call :process_variant_installation "!user_home!\AppData\Local\Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd" "!user_home!\AppData\Local\Programs\Microsoft VS Code Insiders" "Visual Studio Code - Insiders" "!target_user!" "!user_home!"
)
if "!CURRENT_VARIANT!"=="vscodium" (
    REM System-wide installations (Program Files)
    call :get_existing_drives
    for %%d in (!EXISTING_DRIVES!) do (
        call :process_variant_installation "%%d\Program Files\VSCodium\bin\codium.cmd" "%%d\Program Files\VSCodium" "VSCodium" "!target_user!" "!user_home!"
        call :process_variant_installation "%%d\Program Files (x86)\VSCodium\bin\codium.cmd" "%%d\Program Files (x86)\VSCodium" "VSCodium" "!target_user!" "!user_home!"
    )
    REM User installation
    call :process_variant_installation "!user_home!\AppData\Local\Programs\VSCodium\bin\codium.cmd" "!user_home!\AppData\Local\Programs\VSCodium" "VSCodium" "!target_user!" "!user_home!"
)
if "!CURRENT_VARIANT!"=="cursor" (
    REM System-wide installations (Program Files)
    call :get_existing_drives
    for %%d in (!EXISTING_DRIVES!) do (
        call :process_variant_installation "%%d\Program Files\Cursor\resources\app\bin\cursor.cmd" "%%d\Program Files\Cursor" "Cursor" "!target_user!" "!user_home!"
        call :process_variant_installation "%%d\Program Files (x86)\Cursor\resources\app\bin\cursor.cmd" "%%d\Program Files (x86)\Cursor" "Cursor" "!target_user!" "!user_home!"
    )
    REM User installation
    call :process_variant_installation "!user_home!\AppData\Local\Programs\cursor\resources\app\bin\cursor.cmd" "!user_home!\AppData\Local\Programs\cursor" "Cursor" "!target_user!" "!user_home!"
)
if "!CURRENT_VARIANT!"=="code-oss" (
    REM System-wide installations (Program Files)
    call :get_existing_drives
    for %%d in (!EXISTING_DRIVES!) do (
        call :process_variant_installation "%%d\Program Files\Code - OSS\bin\code-oss.cmd" "%%d\Program Files\Code - OSS" "Code - OSS" "!target_user!" "!user_home!"
        call :process_variant_installation "%%d\Program Files (x86)\Code - OSS\bin\code-oss.cmd" "%%d\Program Files (x86)\Code - OSS" "Code - OSS" "!target_user!" "!user_home!"
    )
)
if "!CURRENT_VARIANT!"=="windsurf" (
    REM System-wide installations (Program Files)
    call :get_existing_drives
    for %%d in (!EXISTING_DRIVES!) do (
        call :process_variant_installation "%%d\Program Files\Windsurf\bin\windsurf.cmd" "%%d\Program Files\Windsurf" "Windsurf" "!target_user!" "!user_home!"
        call :process_variant_installation "%%d\Program Files (x86)\Windsurf\bin\windsurf.cmd" "%%d\Program Files (x86)\Windsurf" "Windsurf" "!target_user!" "!user_home!"
    )
    REM User installation
    call :process_variant_installation "!user_home!\AppData\Local\Programs\Windsurf\bin\windsurf.cmd" "!user_home!\AppData\Local\Programs\Windsurf" "Windsurf" "!target_user!" "!user_home!"
)

REM Only output if we found at least one installation
if defined installations_array (
    echo {"timestamp":"!TIMESTAMP!","product_name":"!CURRENT_PRODUCT_NAME!","user":"!target_user!","items":[!installations_array!]}
)
exit /b 0

:process_variant_installation
REM Args: executable_path install_dir product_name target_user user_home
set "pvi_executable=%~1"
set "pvi_install_dir=%~2"
set "pvi_product_name=%~3"
set "pvi_user=%~4"
set "pvi_user_home=%~5"

REM Fast exit if executable doesn't exist
if not exist "!pvi_executable!" exit /b 0

REM Fast exit if install directory doesn't exist (prevents symlink duplicates)
if not exist "!pvi_install_dir!" exit /b 0

REM Deduplication: Skip if we've already processed this install_path
if not "!SEEN_INSTALL_PATHS!"=="" (
    echo !SEEN_INSTALL_PATHS! | findstr /C:"|!pvi_install_dir!|" > nul
    if !errorlevel! == 0 exit /b 0
)
set "SEEN_INSTALL_PATHS=!SEEN_INSTALL_PATHS!|!pvi_install_dir!|"

REM Build installation info
set "vscode_info={"
set "first=1"

REM Get version info
set "pvi_version="
set "pvi_commit="
set "pvi_architecture="
set "line_num=0"
for /f "tokens=* usebackq" %%v in (`"!pvi_executable!" --version 2^>nul`) do (
    set /a "line_num+=1"
    if !line_num!==1 set "pvi_version=%%v"
    if !line_num!==2 set "pvi_commit=%%v"
    if !line_num!==3 set "pvi_architecture=%%v"
)

if defined pvi_version (
    set "vscode_info=!vscode_info!"version":"!pvi_version!""
    set "first=0"
    
    if defined pvi_commit (
        set "vscode_info=!vscode_info!,"commit_id":"!pvi_commit!""
    )
    
    if defined pvi_architecture (
        set "vscode_info=!vscode_info!,"architecture":"!pvi_architecture!""
    )
)

REM Add executable path
if "!first!"=="0" set "vscode_info=!vscode_info!,"
call :capitalize_drive_letter "!pvi_executable!"
set "safe_exe_path=!CAPITALIZED_PATH_RESULT:\=\\!"
set "vscode_info=!vscode_info!"executable_path":"!safe_exe_path!""
set "first=0"

REM Add target
set "vscode_info=!vscode_info!,"target":"client""

REM Add install path if directory exists
if exist "!pvi_install_dir!" (
    call :capitalize_drive_letter "!pvi_install_dir!"
    set "safe_install_dir=!CAPITALIZED_PATH_RESULT:\=\\!"
    set "vscode_info=!vscode_info!,"install_path":"!safe_install_dir!""
)

REM Determine install type
set "pvi_install_type=user"
if not "!pvi_install_dir:Program Files=!"=="!pvi_install_dir!" set "pvi_install_type=system"
set "vscode_info=!vscode_info!,"install_type":"!pvi_install_type!""

REM Add product name
set "vscode_info=!vscode_info!,"product_name":"!pvi_product_name!""

REM Extract update_url from product.json (dynamic detection)
set "pvi_update_url=unknown"
set "pvi_product_json=!pvi_install_dir!\resources\app\product.json"
if exist "!pvi_product_json!" (
    for /f "usebackq delims=" %%u in (`findstr /C:"\"updateUrl\"" "!pvi_product_json!" 2^>nul`) do (
        set "pvi_url_line=%%u"
        set "pvi_url_line=!pvi_url_line:*updateUrl":=!"
        set "pvi_url_line=!pvi_url_line:~2!"
        for /f "tokens=1 delims=," %%v in ("!pvi_url_line!") do (
            set "pvi_update_url=%%v"
            set "pvi_update_url=!pvi_update_url:"=!"
        )
    )
)
set "vscode_info=!vscode_info!,"update_url":"!pvi_update_url!""

REM Add user data and extensions directories (variant-specific)
set "pvi_user_data_dir="
set "pvi_extensions_dir="
if "!pvi_product_name!"=="Visual Studio Code" (
    set "pvi_user_data_dir=!pvi_user_home!\AppData\Roaming\Code\User"
    set "pvi_extensions_dir=!pvi_user_home!\.vscode\extensions"
)
if "!pvi_product_name!"=="Visual Studio Code - Insiders" (
    set "pvi_user_data_dir=!pvi_user_home!\AppData\Roaming\Code - Insiders\User"
    set "pvi_extensions_dir=!pvi_user_home!\.vscode-insiders\extensions"
)
if "!pvi_product_name!"=="VSCodium" (
    set "pvi_user_data_dir=!pvi_user_home!\AppData\Roaming\VSCodium\User"
    set "pvi_extensions_dir=!pvi_user_home!\.vscode-oss\extensions"
)
if "!pvi_product_name!"=="Code - OSS" (
    set "pvi_user_data_dir=!pvi_user_home!\AppData\Roaming\Code - OSS\User"
    set "pvi_extensions_dir=!pvi_user_home!\.vscode-oss\extensions"
)
if "!pvi_product_name!"=="Cursor" (
    set "pvi_user_data_dir=!pvi_user_home!\AppData\Roaming\Cursor\User"
    set "pvi_extensions_dir=!pvi_user_home!\.cursor\extensions"
)
if "!pvi_product_name!"=="Windsurf" (
    set "pvi_user_data_dir=!pvi_user_home!\AppData\Roaming\Windsurf\User"
    set "pvi_extensions_dir=!pvi_user_home!\.windsurf\extensions"
)

if defined pvi_user_data_dir (
    call :capitalize_drive_letter "!pvi_user_data_dir!"
    set "safe_user_dir=!CAPITALIZED_PATH_RESULT:\=\\!"
    set "vscode_info=!vscode_info!,"user_data_dir":"!safe_user_dir!""
)

if defined pvi_extensions_dir (
    call :capitalize_drive_letter "!pvi_extensions_dir!"
    set "safe_ext_dir=!CAPITALIZED_PATH_RESULT:\=\\!"
    set "vscode_info=!vscode_info!,"extensions_dir":"!safe_ext_dir!""
)

set "vscode_info=!vscode_info!}"

REM Add to installations array
if "!array_first!"=="0" set "installations_array=!installations_array!,"
set "installations_array=!installations_array!!vscode_info!"
set "array_first=0"

exit /b 0

:process_server_installation
set "server_path=%~1"
set "product_json_path=%~2"
set "server_user=%~3"

REM Parse product.json
set "server_version="
set "server_commit="
set "server_quality="

REM Extract version
for /f "usebackq tokens=2 delims=:, " %%v in (`findstr /C:"\"version\"" "%product_json_path%" 2^>nul`) do (
    set "server_version=%%v"
    set "server_version=!server_version:"=!"
)

REM Extract commit
for /f "usebackq tokens=2 delims=:, " %%c in (`findstr /C:"\"commit\"" "%product_json_path%" 2^>nul`) do (
    set "server_commit=%%c"
    set "server_commit=!server_commit:"=!"
)

REM Extract quality
for /f "usebackq tokens=2 delims=:, " %%q in (`findstr /C:"\"quality\"" "%product_json_path%" 2^>nul`) do (
    set "server_quality=%%q"
    set "server_quality=!server_quality:"=!"
)

REM Extract updateUrl
set "server_update_url="
for /f "usebackq delims=" %%u in (`findstr /C:"\"updateUrl\"" "%product_json_path%" 2^>nul`) do (
    set "update_line=%%u"
    set "update_line=!update_line:*updateUrl":=!"
    set "update_line=!update_line:~2!"
    for /f "tokens=1 delims=," %%v in ("!update_line!") do (
        set "server_update_url=%%v"
        set "server_update_url=!server_update_url:"=!"
    )
)

REM Build server item
set "server_info={"
set "server_first=1"

if defined server_version (
    set "server_info=!server_info!"version":"!server_version!""
    set "server_first=0"
)

if defined server_commit (
    if "!server_first!"=="0" set "server_info=!server_info!,"
    set "server_info=!server_info!"commit_id":"!server_commit!""
    set "server_first=0"
)

REM Add target field
if "!server_first!"=="0" set "server_info=!server_info!,"
set "server_info=!server_info!"target":"server""
set "server_first=0"

REM Add install path
if "!server_first!"=="0" set "server_info=!server_info!,"
call :capitalize_drive_letter "!server_path!"
set "safe_server_path=!CAPITALIZED_PATH_RESULT:\=\\!"
set "server_info=!server_info!"install_path":"!safe_server_path!""

REM Add server exe path
set "server_executable="
if exist "!server_path!\server\bin\code-server.cmd" (
    set "server_executable=!server_path!\server\bin\code-server.cmd"
) else if exist "!server_path!\server\bin\code-server" (
    set "server_executable=!server_path!\server\bin\code-server"
) else if exist "!server_path!\bin\code-server.cmd" (
    set "server_executable=!server_path!\bin\code-server.cmd"
) else if exist "!server_path!\bin\code-server" (
    set "server_executable=!server_path!\bin\code-server"
)
if defined server_executable (
    call :capitalize_drive_letter "!server_executable!"
    set "safe_server_executable=!CAPITALIZED_PATH_RESULT:\=\\!"
    set "server_info=!server_info!,"executable_path":"!safe_server_executable!""
)

REM Determine product name (uses client name; target field indicates server)
set "server_product=Visual Studio Code"
if defined server_quality (
    if "!server_quality!"=="insider" (
        set "server_product=Visual Studio Code - Insiders"
    )
)
if not "!server_path:Insiders=!"=="!server_path!" (
    set "server_product=Visual Studio Code - Insiders"
)

set "server_info=!server_info!,"product_name":"!server_product!""

REM Add install type
set "server_info=!server_info!,"install_type":"user""

REM Add update_url
if defined server_update_url (
    set "server_info=!server_info!,"update_url":"!server_update_url!""
)

REM Detect server extensions directory
set "server_ext_dir="
if exist "!user_home!\.vscode-server\extensions" (
    set "server_ext_dir=!user_home!\.vscode-server\extensions"
) else if exist "!server_path!\extensions" (
    set "server_ext_dir=!server_path!\extensions"
)

if defined server_ext_dir (
    call :capitalize_drive_letter "!server_ext_dir!"
    set "safe_server_ext_dir=!CAPITALIZED_PATH_RESULT:\=\\!"
    set "server_info=!server_info!,"extensions_dir":"!safe_server_ext_dir!""
)

set "server_info=!server_info!}"

REM Add to array
if "!array_first!"=="0" set "installations_array=!installations_array!,"
set "installations_array=!installations_array!!server_info!"
set "array_first=0"

exit /b 0



:process_settings
set "user_param=%~1"
if "%COLLECT_SETTINGS%"=="0" exit /b 0

REM Skip if no dir
if not exist "!VSCODE_USER_DIR!" exit /b 0

set "settings_json_file=!VSCODE_USER_DIR!\settings.json"
call :process_json_file "!settings_json_file!" "!user_param!"
exit /b 0



:process_argv
set "target_user=%~1"
if "%COLLECT_ARGV%"=="0" exit /b 0

REM Skip if VS Code user directory doesn't exist
if not exist "!VSCODE_USER_DIR!" exit /b 0

set "argv_file=!VSCODE_USER_DIR!\argv.json"
call :process_json_file "!argv_file!" "!target_user!"
exit /b 0

:process_workspace_files
REM Consolidated function: replaces process_workspace_settings, process_tasks, process_launch
REM Uses optimized approach: workspaceStorage enumeration (primary) + targeted directory scan
set "pwf_user=%~1"
set "pwf_user_home=%~2"

REM Skip if all workspace collection is disabled
if "%COLLECT_WORKSPACE_SETTINGS%"=="0" (
    if "%COLLECT_TASKS%"=="0" (
        if "%COLLECT_LAUNCH%"=="0" exit /b 0
    )
)

REM Initialize deduplication tracking for this user
set "SEEN_WORKSPACE_FILES="

REM Primary: Process workspaceStorage paths (VS Code's authoritative workspace registry)
REM This finds all workspaces VS Code has ever opened - the most reliable and complete source
call :process_workspacestorage_paths "!pwf_user_home!" "!pwf_user!"

REM Secondary: Scan common developer paths for projects not yet opened in VS Code
call :get_search_paths "!pwf_user_home!"
for %%p in ("!SEARCH_PATHS:,=" "!") do (
    if exist "%%~p" (
        call :find_workspace_vscode_dirs "%%~p" "!pwf_user!"
    )
)

exit /b 0

:process_workspacestorage_paths
REM Process workspaceStorage paths inline (handles paths with spaces correctly)
set "pwsp_user_home=%~1"
set "pwsp_user=%~2"
set "pwsp_storage_dir=!pwsp_user_home!\AppData\Roaming\Code\User\workspaceStorage"

if not exist "!pwsp_storage_dir!" exit /b 0

for /d %%d in ("!pwsp_storage_dir!\*") do (
    if exist "%%d\workspace.json" (
        REM Extract folder path from workspace.json - look for "folder" lines containing file:///
        for /f "tokens=*" %%f in ('findstr /r /c:"folder.*file:///" "%%d\workspace.json" 2^>nul') do (
            set "pwsp_line=%%f"
            REM Extract path between file:/// and closing quote
            set "pwsp_line=!pwsp_line:*file:///=!"
            REM Remove quotes by string replacement (avoids for /f delimiter issues)
            set "pwsp_path=!pwsp_line:"=!"
            REM Decode URL encoding: %3A -> :, %20 -> space
            set "pwsp_path=!pwsp_path:%%3A=:!"
            set "pwsp_path=!pwsp_path:%%3a=:!"
            set "pwsp_path=!pwsp_path:%%20= !"
            REM Convert forward slashes to backslashes
            set "pwsp_path=!pwsp_path:/=\!"
            REM Process if is a DIRECTORY (not a file)
            if not "!pwsp_path!"=="" (
                if exist "!pwsp_path!\*" (
                    call :find_workspace_vscode_dirs "!pwsp_path!" "!pwsp_user!"
                )
            )
        )
    )
)
exit /b 0

REM Legacy functions removed - now consolidated in :process_workspace_files
REM :process_workspace_settings - merged
REM :process_tasks - merged
REM :process_launch - merged

:extract_url_from_line
REM Extract URL from JSON
set "temp_line=!url_line!"
REM Remove everything before and including first quote-colon-quote sequence
set "temp_line=!temp_line:*":=!"
for /f "tokens=*" %%a in ("!temp_line!") do set "temp_line=%%a"
set "temp_line=!temp_line:"=!"
set "temp_line=!temp_line:,=!"
for /f "tokens=*" %%a in ("!temp_line!") do set "ext_repository=%%a"
exit /b 0

:get_extension_installation_metadata
set "ext_source=unknown"
set "ext_timestamp=unknown"
set "ext_prerelease=false"
set "ext_pinned=false"
REM Lookup from pre-parsed metadata array (set by parse_extensions_json)
if defined meta_!ext_name!_source set "ext_source=!meta_%ext_name%_source!"
if defined meta_!ext_name!_timestamp set "ext_timestamp=!meta_%ext_name%_timestamp!"
if defined meta_!ext_name!_prerelease set "ext_prerelease=!meta_%ext_name%_prerelease!"
if defined meta_!ext_name!_pinned set "ext_pinned=!meta_%ext_name%_pinned!"
exit /b 0

:parse_extensions_json
set "ejf=%~1"
if not exist "!ejf!" exit /b 0

set "pej_buffer="
set "pej_eof=0"

call :parse_ext_json_chunks < "!ejf!"
exit /b 0

:parse_ext_json_chunks
:pej_read
if !pej_eof!==1 exit /b 0
set "pej_chunk="
set /p pej_chunk=
if not defined pej_chunk (
    set "pej_eof=1"
    if defined pej_buffer goto :pej_scan
    exit /b 0
)
set "pej_buffer=!pej_buffer!!pej_chunk!"

:pej_scan
set "pej_test=!pej_buffer:*relativeLocation=!"
if "!pej_test!"=="!pej_buffer!" (
    if !pej_eof!==1 exit /b 0
    if not "!pej_buffer:~700!"=="" set "pej_buffer=!pej_buffer:~-600!"
    goto :pej_read
)
REM Check if we have enough data for metadata (~400 chars after relativeLocation)
if "!pej_test:~400!"=="" (
    if !pej_eof!==1 goto :pej_process
    goto :pej_read
)

:pej_process
REM Skip to value after ":"
set "pej_test=!pej_test:*":"=!"
if "!pej_test!"=="!pej_buffer!" (
    if !pej_eof!==1 exit /b 0
    goto :pej_read
)

REM Extract extension name
set "pej_tmp=!pej_test:"=@!"
for /f "tokens=1 delims=@" %%V in ("!pej_tmp!") do set "pej_extname=%%V"

REM Find entry boundary (next },{ pattern)
set "pej_entry=!pej_test!"
set "pej_nextrel=!pej_test:*},{=!"
if not "!pej_nextrel!"=="!pej_test!" (
    for /l %%i in (0,1,500) do (
        if "!pej_test:~%%i,3!"=="},{" (
            set "pej_entry=!pej_test:~0,%%i!"
            goto :pej_got_entry
        )
    )
)
:pej_got_entry
if not defined pej_entry set "pej_entry=!pej_test:~0,500!"

REM Extract source
set "pej_source=unknown"
set "pej_mtest=!pej_entry:*"source":"=!"
if not "!pej_mtest!"=="!pej_entry!" (
    set "pej_mtmp=!pej_mtest:"=@!"
    for /f "tokens=1 delims=@,}" %%S in ("!pej_mtmp!") do set "pej_source=%%S"
)

REM Extract installedTimestamp
set "pej_timestamp=unknown"
set "pej_mtest=!pej_entry:*"installedTimestamp":=!"
if not "!pej_mtest!"=="!pej_entry!" (
    for /f "tokens=1 delims=,}" %%T in ("!pej_mtest!") do set "pej_timestamp=%%T"
)

REM Check for isPreReleaseVersion:true
set "pej_prerelease=false"
set "pej_prcheck=!pej_entry:"isPreReleaseVersion":true=FOUND!"
if not "!pej_prcheck!"=="!pej_entry!" set "pej_prerelease=true"

REM Check for pinned:true (version pinning - auto-update disabled)
set "pej_pinned=false"
set "pej_pncheck=!pej_entry:"pinned":true=FOUND!"
if not "!pej_pncheck!"=="!pej_entry!" set "pej_pinned=true"

REM Store in meta_* variables
set "meta_!pej_extname!_source=!pej_source!"
set "meta_!pej_extname!_timestamp=!pej_timestamp!"
set "meta_!pej_extname!_prerelease=!pej_prerelease!"
set "meta_!pej_extname!_pinned=!pej_pinned!"

REM Continue scanning
set "pej_buffer=!pej_test:~1!"
goto :pej_scan


:extract_multiline_array
REM Extract JSON array (supports multi-line arrays common in package.json)
REM Input: %1 = file path, %2 = field name (e.g., "activationEvents")
REM Output: MULTILINE_ARRAY_RESULT = JSON array string (e.g., ["onStartupFinished","onLanguage:python"])
set "ema_file=%~1"
set "ema_field=%~2"
set "MULTILINE_ARRAY_RESULT=[]"
REM Store quote in variable for comparison
set "EMA_QUOTE=""

if not exist "!ema_file!" exit /b 0

REM Single findstr with line numbers - decide single vs multi-line
for /f "tokens=1,* delims=:" %%N in ('findstr /N /C:"\"!ema_field!\"" "!ema_file!" 2^>nul') do (
    set "ema_linenum=%%N"
    set "ema_check_line=%%O"
    REM Test for both [ and ] on same line (single-line array - fast path)
    set "ema_has_open=!ema_check_line:[=!"
    set "ema_has_close=!ema_check_line:]=!"
    if not "!ema_has_open!"=="!ema_check_line!" if not "!ema_has_close!"=="!ema_check_line!" (
        REM Single-line array - extract content between [ and ]
        set "ema_temp=!ema_check_line:*[=!"
        for /f "tokens=1 delims=]" %%A in ("!ema_temp!") do set "ema_content=%%A"
        if defined ema_content (
            set "ema_content=!ema_content: =!"
            REM Escape special batch characters to prevent echo issues
            set "ema_content=!ema_content:&=\u0026!"
            set "ema_content=!ema_content:|=\u007c!"
            set "ema_content=!ema_content:<=\u003c!"
            set "ema_content=!ema_content:>=\u003e!"
            if not "!ema_content!"=="" if not "!ema_content!"=="," (
                if "!ema_content:~0,1!"=="," set "ema_content=!ema_content:~1!"
                if "!ema_content:~-1!"=="," set "ema_content=!ema_content:~0,-1!"
                if not "!ema_content!"=="" set "MULTILINE_ARRAY_RESULT=[!ema_content!]"
            )
        )
        exit /b 0
    )
    REM Has [ but no ] - need multi-line parsing, we already have line number
    goto :ema_multiline
)
REM Field not found
exit /b 0

:ema_multiline
REM Use more +N to skip to array start, then read until ]
set "ema_items="
set "ema_done=0"

for /f "delims=" %%L in ('more +!ema_linenum! "!ema_file!"') do (
    if !ema_done!==0 (
        set "ema_line=%%L"
        REM Remove all whitespace for checking
        set "ema_check=!ema_line: =!"
        set "ema_check=!ema_check:	=!"
        set "ema_first=!ema_check:~0,1!"
        REM Stop at closing bracket
        if "!ema_first!"=="]" set "ema_done=1"
        REM Add quoted strings (use variable for quote comparison)
        if !ema_done!==0 if "!ema_first!"=="!EMA_QUOTE!" (
            set "ema_item=!ema_check!"
            if "!ema_item:~-1!"=="," set "ema_item=!ema_item:~0,-1!"
            REM Escape special batch characters to prevent echo issues
            set "ema_item=!ema_item:&=\u0026!"
            set "ema_item=!ema_item:|=\u007c!"
            set "ema_item=!ema_item:<=\u003c!"
            set "ema_item=!ema_item:>=\u003e!"
            if not "!ema_items!"=="" set "ema_items=!ema_items!,"
            set "ema_items=!ema_items!!ema_item!"
        )
    )
)

if not "!ema_items!"=="" set "MULTILINE_ARRAY_RESULT=[!ema_items!]"
exit /b 0


:check_contains_executables
REM Check if extension directory contains executable files
REM Input: %1 = extension directory path
REM Output: ext_contains_executables = "true" or "false"
set "cce_dir=%~1"
set "ext_contains_executables=false"

if not exist "!cce_dir!" exit /b 0

REM Use dir /s /b with findstr to find executable file extensions (case-insensitive)
REM ALL 24 executable extensions per spec - DO NOT REDUCE
REM Native/Compiled binaries: .exe .dll .so .dylib .node .a .lib
REM Bytecode/Intermediate: .wasm .jar .class .pyc .pyo
REM Scripts: .ps1 .bat .cmd .sh .bash .py .rb .pl .lua .vbs .fish
dir /s /b "!cce_dir!\*.*" 2>nul | findstr /i /r "\.exe \.dll \.so \.dylib \.node \.a \.lib \.wasm \.jar \.class \.pyc \.pyo \.ps1 \.bat \.cmd \.sh \.bash \.py \.rb \.pl \.lua \.vbs \.fish" >nul 2>&1
if not errorlevel 1 (
    set "ext_contains_executables=true"
)
exit /b 0


:parse_extension_package_json
REM OPTIMIZED: Single-pass parsing - reads file once, extracts all fields
REM Previous version: 9+ findstr calls per extension (~15s for 33 extensions)
REM Optimized version: 1 findstr call + in-memory parsing + multi-line array support
set "ext_internal_name=unknown"
set "ext_display_name=unknown"
set "publisher_name=unknown"
set "ext_version=unknown"
set "ext_repository=unknown"
set "ext_vscode_engine=unknown"
set "ext_activation_events=[]"
set "ext_workspace_trust_mode=unknown"
set "ext_dependencies=[]"

for /f "tokens=1,2 delims=-" %%x in ("!ext_name!") do (
    set "publisher_and_name=%%x"
    set "fallback_version=%%y"
    for /f "tokens=1,2 delims=." %%a in ("!publisher_and_name!") do (
        set "fallback_publisher=%%a"
        set "fallback_name=%%b"
    )
)

if not exist "!package_json_file!" goto :pepj_fallback

REM Extract multi-line arrays using optimized function (removed redundant findstr existence check)
call :extract_multiline_array "!package_json_file!" "activationEvents"
set "ext_activation_events=!MULTILINE_ARRAY_RESULT!"
call :extract_multiline_array "!package_json_file!" "extensionDependencies"
set "ext_dependencies=!MULTILINE_ARRAY_RESULT!"

REM Single findstr call to get all relevant lines at once
REM Pipe to for loop for in-memory processing
for /f "usebackq delims=" %%L in (`findstr /C:"\"name\"" /C:"\"displayName\"" /C:"\"publisher\"" /C:"\"version\"" /C:"\"url\"" /C:"\"vscode\"" /C:"untrustedWorkspaces" /C:"\"supported\"" "!package_json_file!" 2^>nul`) do (
    set "pj_line=%%L"
    
    REM Check each field type based on line content
    
    REM name field (exact match to avoid matching displayName)
    if "!ext_internal_name!"=="unknown" (
        set "pj_test=!pj_line:"name":=FOUND!"
        if not "!pj_test!"=="!pj_line!" (
            for /f "tokens=2 delims=:, " %%v in ("!pj_line!") do (
                set "ext_internal_name=%%v"
                set "ext_internal_name=!ext_internal_name:"=!"
            )
        )
    )
    
    REM displayName field
    if "!ext_display_name!"=="unknown" (
        set "pj_test=!pj_line:"displayName":=FOUND!"
        if not "!pj_test!"=="!pj_line!" (
            for /f "tokens=2* delims=:, " %%v in ("!pj_line!") do (
                set "ext_display_name=%%v %%w"
                set "ext_display_name=!ext_display_name:"=!"
                set "ext_display_name=!ext_display_name:,=!"
                for /f "tokens=* delims= " %%a in ("!ext_display_name!") do set "ext_display_name=%%a"
                for /l %%a in (1,1,5) do if "!ext_display_name:~-1!"==" " set "ext_display_name=!ext_display_name:~0,-1!"
            )
        )
    )
    
    REM publisher field
    if "!publisher_name!"=="unknown" (
        set "pj_test=!pj_line:"publisher":=FOUND!"
        if not "!pj_test!"=="!pj_line!" (
            for /f "tokens=2 delims=:, " %%v in ("!pj_line!") do (
                set "publisher_name=%%v"
                set "publisher_name=!publisher_name:"=!"
            )
        )
    )
    
    REM version field
    if "!ext_version!"=="unknown" (
        set "pj_test=!pj_line:"version":=FOUND!"
        if not "!pj_test!"=="!pj_line!" (
            for /f "tokens=2 delims=:, " %%v in ("!pj_line!") do (
                set "ext_version=%%v"
                set "ext_version=!ext_version:"=!"
            )
        )
    )
    
    REM url field (for repository)
    if "!ext_repository!"=="unknown" (
        set "pj_test=!pj_line:"url":=FOUND!"
        if not "!pj_test!"=="!pj_line!" (
            set "url_line=!pj_line!"
            call :extract_url_from_line
        )
    )
    
    REM vscode engine field
    if "!ext_vscode_engine!"=="unknown" (
        set "pj_test=!pj_line:"vscode":=FOUND!"
        if not "!pj_test!"=="!pj_line!" (
            for /f "tokens=2 delims=:, " %%v in ("!pj_line!") do (
                set "ext_vscode_engine=%%v"
                set "ext_vscode_engine=!ext_vscode_engine:"=!"
                set "ext_vscode_engine=!ext_vscode_engine:}=!"
            )
        )
    )
    
    REM workspace trust - check for supported field with true/false/limited
    set "pj_test=!pj_line:"supported":=FOUND!"
    if not "!pj_test!"=="!pj_line!" (
        set "pj_check=!pj_line:true=TRUEVAL!"
        if not "!pj_check!"=="!pj_line!" set "ext_workspace_trust_mode=supported"
        set "pj_check=!pj_line:false=FALSEVAL!"
        if not "!pj_check!"=="!pj_line!" set "ext_workspace_trust_mode=unsupported"
        set "pj_check=!pj_line:limited=LIMITEDVAL!"
        if not "!pj_check!"=="!pj_line!" set "ext_workspace_trust_mode=limited"
    )
)

:pepj_fallback
if "!ext_internal_name!"=="unknown" if defined fallback_name set "ext_internal_name=!fallback_name!"
if "!ext_display_name!"=="unknown" set "ext_display_name=!ext_internal_name!"
if "!publisher_name!"=="unknown" if defined fallback_publisher set "publisher_name=!fallback_publisher!"
if "!ext_version!"=="unknown" if defined fallback_version set "ext_version=!fallback_version!"

if "!ext_display_name:~0,1!"=="%%" (
    if not "!ext_internal_name!"=="unknown" (
        set "ext_display_name=!ext_internal_name!"
    ) else (
        set "ext_display_name=!ext_name!"
    )
)
exit /b 0

:process_extensions_new
set "target_user=%~1"
if "%COLLECT_EXTENSIONS%"=="0" exit /b 0

call :get_user_home "!target_user!"
if errorlevel 1 exit /b 0
set "user_home=!USER_HOME_RESULT!"
set "ext_dir=!user_home!\.vscode\extensions"
if not exist "!ext_dir!" exit /b 0

REM Pre-parse extensions.json files for metadata lookup (install_source, timestamp, prerelease)
call :parse_extensions_json "!user_home!\.vscode\extensions\extensions.json"
call :parse_extensions_json "!user_home!\.vscode-server\extensions\extensions.json"

set "chunk_size=!CHUNK_SIZE!"
set "current_chunk=0"
set "extensions_in_chunk=0"
set "total_extensions_processed=0"
set "extensions_array=["
set "first_in_chunk=1"

for /d %%d in ("!VSCODE_EXTENSIONS_DIR!\*") do (
    set "ext_dir=%%d"
    set "ext_name=%%~nxd"
    
    if not "!ext_name:~0,1!"=="." (
        REM Add extension to current chunk
        if !first_in_chunk!==0 set "extensions_array=!extensions_array!,"
        set "first_in_chunk=0"
        
        REM Parse package.json
        set "package_json_file=!ext_dir!\package.json"
        call :parse_extension_package_json
        
        REM Get installation metadata
        call :get_extension_installation_metadata
        
        REM Check for executable files
        call :check_contains_executables "!ext_dir!"
        
        REM Build extension entry
        call :capitalize_drive_letter "!package_json_file!"
        set "safe_package_json_path=!CAPITALIZED_PATH_RESULT:\=\\!"
        
        set "extensions_array=!extensions_array!{"target":"client","extension_id":"!ext_name!","name":"!ext_internal_name!","display_name":"!ext_display_name!","version":"!ext_version!","publisher":"!publisher_name!","repository":"!ext_repository!","vscode_engine":"!ext_vscode_engine!","package_json_path":"!safe_package_json_path!","install_type":"user","install_source":"!ext_source!","installed_timestamp":"!ext_timestamp!","is_prerelease":!ext_prerelease!,"is_pinned_version":!ext_pinned!,"activation_events":!ext_activation_events!,"workspace_trust_mode":"!ext_workspace_trust_mode!","contains_executables":!ext_contains_executables!,"extension_dependencies":!ext_dependencies!}"
        
        set /a "extensions_in_chunk+=1"
        set /a "total_extensions_processed+=1"
        
        REM Output chunk when we reach chunk_size
        if !extensions_in_chunk! EQU !chunk_size! (
            call :output_extensions_chunk "!target_user!" !current_chunk!
            call :reset_extensions_chunk
        )
    )
)

if exist "!user_home!\.vscode-server\extensions" (
    for /d %%d in ("!user_home!\.vscode-server\extensions\*") do (
        set "ext_dir=%%d"
        set "ext_name=%%~nxd"
        
        if not "!ext_name:~0,1!"=="." (
            REM Add extension to current chunk
            if !first_in_chunk!==0 set "extensions_array=!extensions_array!,"
            set "first_in_chunk=0"
            
            REM Parse package.json
            set "package_json_file=!ext_dir!\package.json"
            call :parse_extension_package_json
            
            REM Get installation metadata (server extensions use same extensions.json)
            call :get_extension_installation_metadata
            
            REM Check for executable files
            call :check_contains_executables "!ext_dir!"
            
            REM Build extension entry with target="server"
            call :capitalize_drive_letter "!package_json_file!"
            set "safe_package_json_path=!CAPITALIZED_PATH_RESULT:\=\\!"
            
            set "extensions_array=!extensions_array!{"target":"server","extension_id":"!ext_name!","name":"!ext_internal_name!","display_name":"!ext_display_name!","version":"!ext_version!","publisher":"!publisher_name!","repository":"!ext_repository!","vscode_engine":"!ext_vscode_engine!","package_json_path":"!safe_package_json_path!","install_type":"user","install_source":"!ext_source!","installed_timestamp":"!ext_timestamp!","is_prerelease":!ext_prerelease!,"is_pinned_version":!ext_pinned!,"activation_events":!ext_activation_events!,"workspace_trust_mode":"!ext_workspace_trust_mode!","contains_executables":!ext_contains_executables!,"extension_dependencies":!ext_dependencies!}"
            
            set /a "extensions_in_chunk+=1"
            set /a "total_extensions_processed+=1"
            
            REM Output chunk when we reach chunk_size
            if !extensions_in_chunk! EQU !chunk_size! (
                call :output_extensions_chunk "!target_user!" !current_chunk!
                call :reset_extensions_chunk
            )
        )
    )
)

if !extensions_in_chunk! GTR 0 (
    call :output_extensions_chunk "!target_user!" !current_chunk!
)
exit /b 0

:active_session_func
set "target_user=%~1"
if "%COLLECT_ACTIVE_SESSION%"=="0" exit /b 0

set "storage_file=!VSCODE_USER_DIR!\globalStorage\storage.json"
if not exist "!storage_file!" exit /b 0

findstr /C:"BEGIN RSA PRIVATE KEY" /C:"BEGIN OPENSSH PRIVATE KEY" /C:"BEGIN PRIVATE KEY" "!storage_file!" >nul 2>&1
if not errorlevel 1 exit /b 0

set "VSCODE_RUNNING=0"
tasklist /FI "IMAGENAME eq Code.exe" 2>nul | findstr /I "Code.exe" >nul
if not errorlevel 1 set "VSCODE_RUNNING=1"

REM Init session tracking
call :capitalize_drive_letter "!storage_file!"
set "storage_file=!CAPITALIZED_PATH_RESULT!"
set "safe_storage_path=!storage_file:\=\\!"
set "chunk_size=!CHUNK_SIZE!"
set "current_chunk=0"
set "sessions_in_chunk=0"
set "total_sessions=0"
set "active_sessions_array=["
set "active_sessions_first=1"
set "processed_sessions=;"

set "in_windows_state=0"
set "in_last_active=0"
set "in_opened_windows=0"
set "in_window_obj=0"
set "brace_depth=0"
set "last_active_workspace="
set "last_active_remote="
set "window_remote="
set "window_workspace="
set "temp_storage_file=!storage_file!"
for /f "usebackq delims=" %%L in ("!temp_storage_file!") do (
    set "line=%%L"
    
    REM Track brace depth
    if not "!line:{=!"=="!line!" set /a brace_depth+=1
    if not "!line:}=!"=="!line!" set /a brace_depth-=1
    
    REM Enter windowsState context
    if not "!line:windowsState=!"=="!line!" set "in_windows_state=1"
    
    REM Within windowsState, find lastActiveWindow
    if "!in_windows_state!"=="1" (
        if not "!line:lastActiveWindow=!"=="!line!" set "in_last_active=1"
    )
    
    REM Parse lastActiveWindow fields
    if "!in_last_active!"=="1" (
        if not "!line:remoteAuthority=!"=="!line!" (
            set "temp_line=!line!"
            set "temp_line=!temp_line:*remoteAuthority": "=!"
            for /f "tokens=1 delims=," %%V in ("!temp_line!") do set "parsed_remote=%%V"
            set "val=!parsed_remote!"
            set "val=!val:"=!"
            set "val=!val: =!"
            set "last_active_remote=!val!"
        )
        
        if not "!line:folder=!"=="!line!" (
            set "val=!line:*folder":=!"
            set "val=!val:~1!"
            set "val=!val:"=!"
            set "val=!val:,=!"
            REM Remove any stray control characters or encoding artifacts
            set "val=!val: =!"
            for /f "tokens=*" %%c in ("!val!") do set "val=%%c"
            REM Handle remote URI paths - clean protocol prefixes
            if not "!val:vscode-remote://=!"=="!val!" (
                set "val=!val:vscode-remote://=!"
                REM Remove ssh-remote+ prefix and extract path
                if not "!val:ssh-remote+=!"=="!val!" (
                    set "val=!val:ssh-remote+=!"
                    for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                ) else if not "!val:wsl=!"=="!val!" (
                    REM Remove wsl prefix (wslInstanceName) and extract path  
                    for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                ) else if not "!val:attached-container+=!"=="!val!" (
                    REM Remove attached-container+hex prefix and extract path
                    set "val=!val:attached-container+=!"
                    for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                ) else if not "!val:dev-container+=!"=="!val!" (
                    REM Remove dev-container+hex prefix and extract path
                    set "val=!val:dev-container+=!"
                    for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                ) else (
                    REM Fallback for other remote types
                    for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                )
            )
            set "last_active_workspace=!val!"
        )
        
        if !brace_depth! LEQ 2 if not "!line:}=!"=="!line!" set "in_last_active=0"
    )
    
    REM Section 2: Opened windows for active sessions (within windowsState)
    if "!in_windows_state!"=="1" (
        if not "!line:openedWindows=!"=="!line!" set "in_opened_windows=1"
    )
    
    if "!in_opened_windows!"=="1" (
        if not "!line:{=!"=="!line!" (
            if "!in_window_obj!"=="0" (
                set "in_window_obj=1"
                set "window_remote="
                set "window_workspace="
            )
        )
        
        if "!in_window_obj!"=="1" (
            if not "!line:remoteAuthority=!"=="!line!" (
                set "temp_line=!line!"
                set "temp_line=!temp_line:*remoteAuthority": "=!"
                for /f "tokens=1 delims=," %%V in ("!temp_line!") do set "parsed_remote=%%V"
                set "val=!parsed_remote!"
                set "val=!val:"=!"
                if "!val:~0,1!"==" " set "val=!val:~1!"
                set "window_remote=!val!"
            )
            
            if not "!line:folder=!"=="!line!" (
                REM Extract the entire URL value after "folder": "
                set "temp_line=!line!"
                set "temp_line=!temp_line:*folder": "=!"
                REM Remove trailing quote and comma by finding the first comma
                for /f "tokens=1 delims=," %%V in ("!temp_line!") do set "parsed_folder=%%V"
                set "val=!parsed_folder!"
                set "val=!val:"=!"
                if "!val:~0,1!"==" " set "val=!val:~1!"
                
                REM Clean any encoding artifacts or control characters
                for /f "tokens=*" %%c in ("!val!") do set "cleaned_val=%%c"
                set "val=!cleaned_val!"
                
                REM Handle remote URI paths - clean protocol prefixes
                if not "!val:vscode-remote://=!"=="!val!" (
                    set "val=!val:vscode-remote://=!"
                    REM Remove ssh-remote+ prefix and extract path
                    if not "!val:ssh-remote+=!"=="!val!" (
                        set "val=!val:ssh-remote+=!"
                        for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                    ) else if not "!val:wsl=!"=="!val!" (
                        REM Remove wsl prefix (wslInstanceName) and extract path  
                        for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                    ) else if not "!val:attached-container+=!"=="!val!" (
                        REM Remove attached-container+hex prefix and extract path
                        set "val=!val:attached-container+=!"
                        for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                    ) else if not "!val:dev-container+=!"=="!val!" (
                        REM Remove dev-container+hex prefix and extract path
                        set "val=!val:dev-container+=!"
                        for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                    ) else (
                        REM Fallback for other remote types
                        for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                    )
                )
                
                REM Handle path processing based on path type
                if not "!val:file:///=!"=="!val!" (
                    REM Decode file:// URLs for local Windows paths
                    set "val=!val:file:///=!"
                    set "val=!val:%%3A=:!"
                    set "val=!val:%%20= !"
                    set "val=!val:%%2B=+!"
                    set "val=!val:/=\!"
                    REM Capitalize drive letters for Windows paths
                    call :capitalize_drive_letter "!val!"
                    set "val=!CAPITALIZED_PATH_RESULT!"
                ) else if "!val:~1,1!"==":" (
                    REM Local Windows paths (any drive letter): apply capitalization
                    call :capitalize_drive_letter "!val!"
                    set "val=!CAPITALIZED_PATH_RESULT!"
                )
                REM For remote paths (starting with / or already processed), leave as-is
                
                set "window_workspace=!val!"
            )
            
            if not "!line:}=!"=="!line!" (
                REM Simplified - just check if we have window data
                if "!in_window_obj!"=="1" (
                    REM Add session entry
                    if not "!window_remote!"=="" (
                        call :add_active_session_to_array "!window_remote!" "!window_workspace!" "!target_user!"
                    ) else if not "!window_workspace!"=="" (
                        call :add_active_session_to_array "local" "!window_workspace!" "!target_user!"
                    )
                    
                    set "in_window_obj=0"
                    set "window_remote="
                    set "window_workspace="
                )
            )
        )
        
        if !brace_depth! LEQ 1 set "in_opened_windows=0"
    )
    
    REM Exit windowsState context when brace depth returns to top level
    if "!in_windows_state!"=="1" if !brace_depth! LEQ 0 set "in_windows_state=0"
)

REM Section 3: Add lastActiveWindow to sessions (the focused/active window)
REM This is the currently focused VS Code window
if not "!last_active_workspace!"=="" (
    REM Decode file:// URLs for local Windows paths
    set "law_workspace=!last_active_workspace!"
    if not "!law_workspace:file:///=!"=="!law_workspace!" (
        set "law_workspace=!law_workspace:file:///=!"
        set "law_workspace=!law_workspace:%%3A=:!"
        set "law_workspace=!law_workspace:%%20= !"
        set "law_workspace=!law_workspace:%%2B=+!"
        set "law_workspace=!law_workspace:/=\!"
        call :capitalize_drive_letter "!law_workspace!"
        set "law_workspace=!CAPITALIZED_PATH_RESULT!"
    )
    if not "!last_active_remote!"=="" (
        call :add_active_session_to_array "!last_active_remote!" "!law_workspace!" "!target_user!"
    ) else (
        call :add_active_session_to_array "local" "!law_workspace!" "!target_user!"
    )
)

REM Parse backupWorkspaces
set "in_backup_workspaces=0"
set "backup_remote="
set "backup_workspace="

set "temp_storage_file=!storage_file!"
for /f "usebackq delims=" %%L in ("!temp_storage_file!") do (
    set "line=%%L"
    
    REM Track brace depth for backup workspaces
    if not "!line:{=!"=="!line!" set /a brace_depth+=1
    if not "!line:}=!"=="!line!" set /a brace_depth-=1
    
    REM Backup workspaces section for recent folders
    if not "!line:backupWorkspaces=!"=="!line!" set "in_backup_workspaces=1"
    
    if "!in_backup_workspaces!"=="1" (
        REM Extract backup folder URI
        if not "!line:folderUri=!"=="!line!" (
            REM Extract the entire URL value after "folderUri": "
            set "temp_line=!line!"
            set "temp_line=!temp_line:*folderUri": "=!"
            REM Remove trailing quote and comma
            for /f "tokens=1 delims=," %%V in ("!temp_line!") do set "parsed_folder=%%V"
            set "val=!parsed_folder!"
            set "val=!val:"=!"
            set "val=!val: =!"
            if not "!val!"=="" (
                REM Clean any encoding artifacts before processing
                for /f "tokens=*" %%c in ("!val!") do set "val=%%c"
                
                REM Handle remote URI paths - clean protocol prefixes
                if not "!val:vscode-remote://=!"=="!val!" (
                    set "val=!val:vscode-remote://=!"
                    REM Remove ssh-remote+ prefix and extract path
                    if not "!val:ssh-remote+=!"=="!val!" (
                        set "val=!val:ssh-remote+=!"
                        for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                    ) else if not "!val:wsl=!"=="!val!" (
                        REM Remove wsl prefix (wslInstanceName) and extract path  
                        for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                    ) else (
                        REM Fallback for other remote types
                        for /f "tokens=1* delims=/" %%a in ("!val!") do set "val=/%%b"
                    )
                ) else (
                    REM Convert URI to path - decode URL encoding and remove file:/// prefix
                    set "val=!val:%%3A=:!"
                    set "val=!val:%%20= !"
                    set "val=!val:%%2B=+!"
                    set "val=!val:file:///=!"
                    set "val=!val:/=\!"
                )
                set "backup_workspace=!val!"
            )
        )
        
        REM Extract remote authority for backup 
        if not "!line:remoteAuthority=!"=="!line!" (
            set "temp_line=!line!"
            set "temp_line=!temp_line:*remoteAuthority": "=!"
            for /f "tokens=1 delims=," %%V in ("!temp_line!") do set "parsed_remote=%%V"
            set "val=!parsed_remote!"
            set "val=!val:"=!"
            set "val=!val: =!"
            if not "!val!"=="" set "backup_remote=!val!"
        )
        
        REM When we reach the end of a backup workspace entry
        if not "!line:}=!"=="!line!" (
            if not "!backup_workspace!"=="" (
                if not "!backup_remote!"=="" (
                    REM Parse remote authority using same logic as active sessions
                    if not "!backup_remote:wsl=!"=="!backup_remote!" (
                        REM WSL remote authority format: wsl+InstanceName or wslInstanceName
                        set "backup_conn_type=wsl"
                        set "backup_host=!backup_remote:wsl=!"
                        REM URL decode %2B back to + (handles wsl%2Bdist -> wsl+dist)
                        set "backup_host=!backup_host:%%2B=+!"
                        REM Handle malformed B substitution (wslBdist -> wsl+dist)
                        if "!backup_host:~0,1!"=="B" set "backup_host=+!backup_host:~1!"
                        REM Remove leading + if present (wsl+dist -> dist)
                        if "!backup_host:~0,1!"=="+" set "backup_host=!backup_host:~1!"
                    ) else if not "!backup_remote:attached-container=!"=="!backup_remote!" (
                        REM Attached container format: attached-container+hexdata
                        set "backup_conn_type=attached-container"
                        for /f "tokens=2 delims=+" %%h in ("!backup_remote!") do set "backup_host=%%h"
                        if "!backup_host!"=="" set "backup_host=!backup_remote!"
                    ) else if not "!backup_remote:dev-container=!"=="!backup_remote!" (
                        REM Dev container format: dev-container+hexdata
                        set "backup_conn_type=dev-container"
                        for /f "tokens=2 delims=+" %%h in ("!backup_remote!") do set "backup_host=%%h"
                        if "!backup_host!"=="" set "backup_host=!backup_remote!"
                    ) else (
                        REM SSH remote authority format: ssh-remote+hostname
                        for /f "tokens=1,2 delims=+" %%a in ("!backup_remote!") do (
                            set "backup_conn_type=%%a"
                            set "backup_host=%%b"
                        )
                        
                        if "!backup_host!"=="" (
                            set "backup_conn_type=ssh-remote"
                            set "backup_host=!backup_remote!"
                        )
                    )
                    call :add_recent_session_to_array "!backup_workspace!" "!backup_conn_type!" "!backup_host!" "!target_user!"
                ) else (
                    REM Check if it's a remote URI that wasn't parsed
                    if not "!backup_workspace:vscode-remote=!"=="!backup_workspace!" (
                        REM Handle different remote URI types
                        if not "!backup_workspace:attached-container=!"=="!backup_workspace!" (
                            REM attached-container URI: extract hex and workspace path
                            set "backup_uri=!backup_workspace:vscode-remote://attached-container=!"
                            set "backup_uri=!backup_uri:%%2B=+!"
                            for /f "tokens=1 delims=/" %%h in ("!backup_uri!") do set "backup_hex=%%h"
                            set "backup_hex=!backup_hex:+=!"
                            REM Extract workspace path after hex
                            for /f "tokens=1* delims=/" %%a in ("!backup_uri!") do set "backup_path=/%%b"
                            call :add_recent_session_to_array "!backup_path!" "attached-container" "!backup_hex!" "!target_user!"
                        ) else if not "!backup_workspace:dev-container=!"=="!backup_workspace!" (
                            REM dev-container URI: extract hex and workspace path
                            set "backup_uri=!backup_workspace:vscode-remote://dev-container=!"
                            set "backup_uri=!backup_uri:%%2B=+!"
                            for /f "tokens=1 delims=/" %%h in ("!backup_uri!") do set "backup_hex=%%h"
                            set "backup_hex=!backup_hex:+=!"
                            REM Extract workspace path after hex
                            for /f "tokens=1* delims=/" %%a in ("!backup_uri!") do set "backup_path=/%%b"
                            call :add_recent_session_to_array "!backup_path!" "dev-container" "!backup_hex!" "!target_user!"
                        ) else if not "!backup_workspace:ssh-remote=!"=="!backup_workspace!" (
                            REM Extract from vscode-remote://ssh-remote%2Bhost/path format
                            for /f "tokens=2 delims=%%" %%h in ("!backup_workspace!") do (
                                set "remote_host=%%h"
                                set "remote_host=!remote_host:2B=!"
                                for /f "tokens=1 delims=/" %%p in ("!remote_host!") do (
                                    set "clean_host=%%p"
                                    for /f "tokens=2 delims=/" %%r in ("!backup_workspace!") do (
                                        call :add_recent_session_to_array "%%r" "ssh-remote" "!clean_host!" "!target_user!"
                                    )
                                )
                            )
                        ) else if not "!backup_workspace:wsl=!"=="!backup_workspace!" (
                            REM WSL URI: extract instance and path
                            set "backup_uri=!backup_workspace:vscode-remote://wsl=!"
                            set "backup_uri=!backup_uri:%%2B=+!"
                            for /f "tokens=1 delims=/" %%h in ("!backup_uri!") do set "backup_host=%%h"
                            set "backup_host=!backup_host:+=!"
                            for /f "tokens=1* delims=/" %%a in ("!backup_uri!") do set "backup_path=/%%b"
                            call :add_recent_session_to_array "!backup_path!" "wsl" "!backup_host!" "!target_user!"
                        )
                    ) else (
                        REM Local workspace
                        call :add_recent_session_to_array "!backup_workspace!" "local" "" "!target_user!"
                    )
                )
            )
            set "backup_remote="
            set "backup_workspace="
        )
        
        if !brace_depth! LEQ 1 set "in_backup_workspaces=0"
    )
)

REM Historical SSH hosts
set "temp_storage_file=!storage_file!"
for /f "usebackq delims=" %%L in ("!temp_storage_file!") do (
    set "line=%%L"
    REM Check for vscode-remote://ssh-remote pattern using batch string replacement
    if not "!line:vscode-remote://ssh-remote=!"=="!line!" (
        REM Extract the part after ssh-remote
        set "uri_part=!line:*ssh-remote=!"
        REM Remove %2B encoding and get host
        set "uri_part=!uri_part:%%2B=+!"
        REM Extract host before the / 
        for /f "tokens=1 delims=/" %%H in ("!uri_part!") do (
            set "remote_host=%%H"
            REM Remove any remaining characters after host and leading +
            for /f "tokens=1 delims=:" %%C in ("!remote_host!") do set "remote_host=%%C"
            if "!remote_host:~0,1!"=="+" set "remote_host=!remote_host:~1!"
            
            REM Create session key for this historical SSH host (no workspace path)
            set "session_key=ssh-remote:!remote_host!:"
            
            REM Check if already processed (would have workspace data if in sessions)
            echo !processed_sessions! | findstr /C:";!session_key!;" >nul 2>nul
            if errorlevel 1 (
                REM This is a historical connection - never found in active/recent sessions
                set "processed_sessions=!processed_sessions!!session_key!;"
                
                REM Retrieve SSH configuration
                call :lookup_ssh_info_simple "!remote_host!" "!target_user!"
                
                REM Add to sessions array as historical entry
                if "!active_sessions_first!"=="0" set "active_sessions_array=!active_sessions_array!,"
                set "active_sessions_array=!active_sessions_array!{"storage_file_path":"!safe_storage_path!","connection_type":"ssh-remote","remote_host":"!remote_host!","user":"!SSH_USER_RESULT!","auth_method":"!SSH_AUTH_RESULT!","window_type":"empty","workspace_path":"","is_active":false}"
                set "active_sessions_first=0"
                set /a "sessions_in_chunk+=1"
                set /a "total_sessions+=1"
                
                REM Output chunk when limit reached
                if !sessions_in_chunk! EQU !chunk_size! (
                    call :output_session_chunk "!target_user!" !current_chunk!
                    call :reset_session_chunk
                )
            )
        )
    )
)

REM No temp file cleanup needed - using direct file processing

REM Output remaining sessions if any
if !sessions_in_chunk! GTR 0 (
    call :output_session_chunk "!target_user!" !current_chunk!
)
exit /b 0

:add_active_session_to_array
set "remote_authority=%~1"
set "workspace_path=%~2"
set "target_user=%~3"

REM Normalize path
if "!remote_authority!"=="local" (
    if not "!workspace_path!"=="" (
        call :capitalize_drive_letter "!workspace_path!"
        set "workspace_path=!CAPITALIZED_PATH_RESULT!"
    )
)

REM Pre-decode container names for session key consistency
set "decoded_container_name="
set "decoded_host_path="
if not "!remote_authority:attached-container=!"=="!remote_authority!" (
    for /f "tokens=2 delims=+" %%h in ("!remote_authority!") do (
        call :get_container_name_from_hex "%%h"
        set "decoded_container_name=!CONTAINER_NAME_RESULT!"
    )
) else if not "!remote_authority:dev-container=!"=="!remote_authority!" (
    for /f "tokens=2 delims=+" %%h in ("!remote_authority!") do (
        call :get_devcontainer_hostpath_from_hex "%%h"
        set "decoded_host_path=!DEVCONTAINER_HOSTPATH_RESULT!"
    )
)

REM Clean workspace path
set "clean_workspace=!workspace_path!"
REM Remove artifacts
for /f "tokens=*" %%c in ("!clean_workspace!") do set "clean_workspace=%%c"

REM Create session key
set "session_key=local:!clean_workspace!"
if not "!remote_authority!"=="local" (
    REM Extract connection type and normalized host
    if not "!remote_authority:wsl=!"=="!remote_authority!" (
        set "norm_host=!remote_authority:wsl=!"
        REM URL decode and handle malformed substitution 
        set "norm_host=!norm_host:%%2B=+!"
        if "!norm_host:~0,1!"=="B" set "norm_host=+!norm_host:~1!"
        if "!norm_host:~0,1!"=="+" set "norm_host=!norm_host:~1!"
        set "session_key=wsl:!norm_host!:!clean_workspace!"
    ) else if not "!remote_authority:attached-container=!"=="!remote_authority!" (
        REM Use pre-decoded container name for session key
        if not "!decoded_container_name!"=="" (
            set "session_key=attached-container:!decoded_container_name!:!clean_workspace!"
        ) else (
            REM Fallback to hex if decode failed
            for /f "tokens=2 delims=+" %%h in ("!remote_authority!") do set "norm_host=%%h"
            set "session_key=attached-container:!norm_host!:!clean_workspace!"
        )
    ) else if not "!remote_authority:dev-container=!"=="!remote_authority!" (
        REM Use pre-decoded hostPath for dev-container session key
        if not "!decoded_host_path!"=="" (
            set "session_key=dev-container:!decoded_host_path!:!clean_workspace!"
        ) else (
            REM Fallback to hex if decode failed
            for /f "tokens=2 delims=+" %%h in ("!remote_authority!") do set "norm_host=%%h"
            set "session_key=dev-container:!norm_host!:!clean_workspace!"
        )
    ) else (
        REM SSH format: ssh-remote+hostname
        for /f "tokens=2 delims=+" %%h in ("!remote_authority!") do set "norm_host=%%h"
        set "session_key=ssh-remote:!norm_host!:!clean_workspace!"
    )
)

REM Check if processed
echo !processed_sessions! | findstr /C:";!session_key!;" >nul 2>&1
if not errorlevel 1 exit /b 0
set "processed_sessions=!processed_sessions!!session_key!;"

REM Handle local
if "!remote_authority!"=="local" (
    set "connection_type=local"
    set "remote_user=%target_user%"
    set "auth_method=local"
    
    REM Determine window_type
    set "window_type=folder"
    if "!workspace_path!"=="" (
        set "window_type=empty"
    ) else if not "!workspace_path:.code-workspace=!"=="!workspace_path!" (
        set "window_type=workspace"
    )
    
    REM Validate and clean workspace path before processing
    set "clean_workspace_path=!workspace_path!"
    if not "!workspace_path!"=="" (
        REM Remove any corruption markers or invalid characters
        set "clean_workspace_path=!clean_workspace_path:0Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:1Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:2Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:3Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:4Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:5Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:6Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:7Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:8Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:9Files=Files!"
        set "workspace_path=!clean_workspace_path!"
    )
    
    REM Escape backslashes for JSON (drive letter already capitalized)
    set "safe_workspace_path="
    if not "!workspace_path!"=="" (
        set "safe_workspace_path=!workspace_path:\=\\!"
    )
    
    REM Determine is_active based on VS Code process state
    if "!VSCODE_RUNNING!"=="1" (
        set "session_is_active=true"
    ) else (
        set "session_is_active=false"
    )
    
    REM Add to sessions array (no remote_host for local)
    if "!active_sessions_first!"=="0" set "active_sessions_array=!active_sessions_array!,"
    set "active_sessions_array=!active_sessions_array!{"storage_file_path":"!safe_storage_path!","connection_type":"!connection_type!","user":"!remote_user!","auth_method":"!auth_method!","window_type":"!window_type!","workspace_path":"!safe_workspace_path!","is_active":!session_is_active!}"
    set "active_sessions_first=0"
    set /a "sessions_in_chunk+=1"
    set /a "total_sessions+=1"
    
    REM Output chunk when limit reached
    if !sessions_in_chunk! EQU !chunk_size! (
        call :output_session_chunk "!target_user!" !current_chunk!
        call :reset_session_chunk
    )
) else (
    REM Parse remote connection details
    if not "!remote_authority:wsl=!"=="!remote_authority!" (
        REM WSL remote authority format: wsl+InstanceName or wslInstanceName
        set "connection_type=wsl"
        set "remote_host=!remote_authority:wsl=!"
        REM URL decode %2B back to + (handles wsl%2Bdist -> wsl+dist)
        set "remote_host=!remote_host:%%2B=+!"
        REM Handle malformed B substitution (wslBdist -> wsl+dist)
        if "!remote_host:~0,1!"=="B" set "remote_host=+!remote_host:~1!"
        REM Remove leading + if present (wsl+dist -> dist)
        if "!remote_host:~0,1!"=="+" set "remote_host=!remote_host:~1!"
    ) else if not "!remote_authority:attached-container=!"=="!remote_authority!" (
        REM Attached container format: attached-container+hexdata
        set "connection_type=attached-container"
        for /f "tokens=2 delims=+" %%h in ("!remote_authority!") do set "remote_host=%%h"
        if "!remote_host!"=="" set "remote_host=!remote_authority!"
    ) else if not "!remote_authority:dev-container=!"=="!remote_authority!" (
        REM Dev container format: dev-container+hexdata (contains hostPath)
        set "connection_type=dev-container"
        for /f "tokens=2 delims=+" %%h in ("!remote_authority!") do set "remote_host=%%h"
        if "!remote_host!"=="" set "remote_host=!remote_authority!"
    ) else (
        REM SSH remote authority format: ssh-remote+hostname
        for /f "tokens=1,2 delims=+" %%a in ("!remote_authority!") do (
            set "connection_type=%%a"
            set "remote_host=%%b"
        )
        
        if "!remote_host!"=="" (
            set "connection_type=ssh-remote"
            set "remote_host=!remote_authority!"
        )
    )
    
    REM Special handling for WSL and Docker container connections
    if "!connection_type!"=="wsl" (
        REM WSL sessions always use "unknown" for user field
        REM (Script runs as LocalSystem and cannot query per-user WSL context)
        set "SSH_USER_RESULT=unknown"
        set "SSH_AUTH_RESULT=local"
    ) else if "!connection_type!"=="attached-container" (
        REM Docker container: decode hex to get container name
        call :get_container_name_from_hex "!remote_host!"
        set "container_name=!CONTAINER_NAME_RESULT!"
        
        REM Use container name as remote_host for cleaner output
        if not "!container_name!"=="unknown" (
            set "remote_host=!container_name!"
        )
        set "SSH_USER_RESULT=unknown"
        set "SSH_AUTH_RESULT=docker"
    ) else if "!connection_type!"=="dev-container" (
        REM Dev container: decode hex to get hostPath
        call :get_devcontainer_hostpath_from_hex "!remote_host!"
        set "host_path=!DEVCONTAINER_HOSTPATH_RESULT!"
        
        REM Use hostPath as remote_host for cleaner output
        if not "!host_path!"=="unknown" (
            REM Escape backslashes for JSON output
            set "remote_host=!host_path:\=\\!"
        )
        REM Dev containers use docker auth method, user unknown (runs inside container)
        set "SSH_USER_RESULT=unknown"
        set "SSH_AUTH_RESULT=docker"
    ) else (
        REM Retrieve SSH configuration for SSH remotes
        call :lookup_ssh_info_simple "!remote_host!" "%target_user%"
    )
    
    REM Determine window_type
    set "window_type=folder"
    if "!workspace_path!"=="" (
        set "window_type=empty"
    ) else if not "!workspace_path:.code-workspace=!"=="!workspace_path!" (
        set "window_type=workspace"
    )
    
    REM Validate and clean workspace path before processing
    set "clean_workspace_path=!workspace_path!"
    if not "!workspace_path!"=="" (
        REM Remove any corruption markers or invalid characters
        set "clean_workspace_path=!clean_workspace_path:0Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:1Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:2Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:3Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:4Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:5Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:6Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:7Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:8Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:9Files=Files!"
        set "workspace_path=!clean_workspace_path!"
    )
    
    REM Handle path escaping based on connection type
    set "safe_workspace_path="
    if not "!workspace_path!"=="" (
        if "!connection_type!"=="local" (
            REM Local Windows paths: capitalize drive letters and normalize backslashes
            call :capitalize_drive_letter "!workspace_path!"
            set "workspace_path=!CAPITALIZED_PATH_RESULT!"
            set "safe_workspace_path=!workspace_path:\=\\!"
        ) else (
            REM Remote paths (WSL/SSH): keep forward slashes for Unix paths
            set "safe_workspace_path=!workspace_path!"
        )
    )
    
    REM Determine is_active based on VS Code process state
    if "!VSCODE_RUNNING!"=="1" (
                set "session_is_active=true"
    ) else (
                set "session_is_active=false"
    )
    
    REM Add to sessions array (include remote_host)
    if "!active_sessions_first!"=="0" set "active_sessions_array=!active_sessions_array!,"
    set "active_sessions_array=!active_sessions_array!{"storage_file_path":"!safe_storage_path!","connection_type":"!connection_type!","remote_host":"!remote_host!","user":"!SSH_USER_RESULT!","auth_method":"!SSH_AUTH_RESULT!","window_type":"!window_type!","workspace_path":"!safe_workspace_path!","is_active":!session_is_active!}"
    set "active_sessions_first=0"
    set /a "sessions_in_chunk+=1"
    set /a "total_sessions+=1"
    
    REM Output chunk when limit reached
    if !sessions_in_chunk! EQU !chunk_size! (
        call :output_session_chunk "!target_user!" !current_chunk!
        call :reset_session_chunk
    )
)
exit /b 0

:add_recent_session_to_array
set "workspace_path=%~1"
set "connection_type=%~2" 
set "remote_host=%~3"
set "target_user=%~4"

REM Normalize workspace path for consistent keying (capitalize drive letters for local paths)
if "!connection_type!"=="local" (
    if not "!workspace_path!"=="" (
        call :capitalize_drive_letter "!workspace_path!"
        set "workspace_path=!CAPITALIZED_PATH_RESULT!"
    )
)

REM Create unique session key to prevent duplicates - use SAME logic as add_active_session_to_array
set "session_key=local:!workspace_path!"
if not "!connection_type!"=="local" (
    REM Normalize remote host for consistent keying (match active session logic)
    set "norm_host=!remote_host!"
    if "!connection_type!"=="wsl" (
        REM URL decode and handle malformed substitution (same as active sessions)
        set "norm_host=!norm_host:%%2B=+!"
        if "!norm_host:~0,1!"=="B" set "norm_host=+!norm_host:~1!"
        if "!norm_host:~0,1!"=="+" set "norm_host=!norm_host:~1!"
    ) else if "!connection_type!"=="attached-container" (
        REM For containers, decode hex to get consistent key
        call :get_container_name_from_hex "!remote_host!"
        if not "!CONTAINER_NAME_RESULT!"=="unknown" set "norm_host=!CONTAINER_NAME_RESULT!"
    ) else if "!connection_type!"=="dev-container" (
        REM For dev-containers, decode hex to get hostPath for consistent key
        call :get_devcontainer_hostpath_from_hex "!remote_host!"
        if not "!DEVCONTAINER_HOSTPATH_RESULT!"=="unknown" set "norm_host=!DEVCONTAINER_HOSTPATH_RESULT!"
    )
    set "session_key=!connection_type!:!norm_host!:!workspace_path!"
)

REM Check if session already processed using findstr for reliability
echo !processed_sessions! | findstr /C:";!session_key!;" >nul 2>&1
if not errorlevel 1 exit /b 0
set "processed_sessions=!processed_sessions!!session_key!;"

REM Handle local/remote
if "!connection_type!"=="local" (
    set "auth_method=local"
    set "session_user=!target_user!"
    
    REM Determine window_type
    set "window_type=folder"
    if "!workspace_path!"=="" (
        set "window_type=empty"
    ) else if not "!workspace_path:.code-workspace=!"=="!workspace_path!" (
        set "window_type=workspace"
    )
    
    REM Validate and clean workspace path before processing 
    set "clean_workspace_path=!workspace_path!"
    if not "!workspace_path!"=="" (
        REM Remove any corruption markers or invalid characters
        set "clean_workspace_path=!clean_workspace_path:0Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:1Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:2Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:3Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:4Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:5Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:6Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:7Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:8Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:9Files=Files!"
        set "workspace_path=!clean_workspace_path!"
    )
    
    REM Escape backslashes for JSON (drive letter already capitalized)
    set "safe_workspace_path="
    if not "!workspace_path!"=="" (
        set "safe_workspace_path=!workspace_path:\=\\!"
    )
    
    REM Add to sessions array (no remote_host for local, recent session)
    if "!active_sessions_first!"=="0" set "active_sessions_array=!active_sessions_array!,"
    set "active_sessions_array=!active_sessions_array!{"storage_file_path":"!safe_storage_path!","connection_type":"!connection_type!","user":"!session_user!","auth_method":"!auth_method!","window_type":"!window_type!","workspace_path":"!safe_workspace_path!","is_active":false}"
    set "active_sessions_first=0"
) else (
    REM Remote connection - handle WSL, Docker, and SSH differently
    if "!connection_type!"=="wsl" (
        REM WSL sessions always use "unknown" for user field
        REM (Script runs as LocalSystem and cannot query per-user WSL context)
        set "SSH_USER_RESULT=unknown"
        set "SSH_AUTH_RESULT=local"
    ) else if "!connection_type!"=="attached-container" (
        REM Docker container: decode hex to get container name
        call :get_container_name_from_hex "!remote_host!"
        set "container_name=!CONTAINER_NAME_RESULT!"
        
        REM Use container name as remote_host for cleaner output
        if not "!container_name!"=="unknown" (
            set "remote_host=!container_name!"
        )
        
        set "SSH_USER_RESULT=unknown"
        set "SSH_AUTH_RESULT=docker"
    ) else if "!connection_type!"=="dev-container" (
        REM Dev container: decode hex to get hostPath
        call :get_devcontainer_hostpath_from_hex "!remote_host!"
        set "host_path=!DEVCONTAINER_HOSTPATH_RESULT!"
        
        REM Use hostPath as remote_host for cleaner output
        if not "!host_path!"=="unknown" (
            REM Escape backslashes for JSON output
            set "remote_host=!host_path:\=\\!"
        )
        
        REM Dev containers use docker auth method
        set "SSH_USER_RESULT=unknown"
        set "SSH_AUTH_RESULT=docker"
    ) else (
        REM Get SSH info for SSH remotes
        call :lookup_ssh_info_simple "!remote_host!" "!target_user!"
    )
    
    REM Determine window_type
    set "window_type=folder" 
    if "!workspace_path!"=="" (
        set "window_type=empty"
    ) else if not "!workspace_path:.code-workspace=!"=="!workspace_path!" (
        set "window_type=workspace"
    )
    
    REM Validate and clean workspace path before processing
    set "clean_workspace_path=!workspace_path!"
    if not "!workspace_path!"=="" (
        REM Remove any corruption markers or invalid characters
        set "clean_workspace_path=!clean_workspace_path:0Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:1Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:2Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:3Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:4Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:5Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:6Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:7Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:8Files=Files!"
        set "clean_workspace_path=!clean_workspace_path:9Files=Files!"
        set "workspace_path=!clean_workspace_path!"
    )
    
    REM Handle path escaping based on connection type
    set "safe_workspace_path="
    if not "!workspace_path!"=="" (
        if "!connection_type!"=="local" (
            REM Local Windows paths: capitalize drive letters and normalize backslashes
            call :capitalize_drive_letter "!workspace_path!"
            set "workspace_path=!CAPITALIZED_PATH_RESULT!"
            set "safe_workspace_path=!workspace_path:\=\\!"
        ) else (
            REM Remote paths (WSL/SSH): keep forward slashes for Unix paths
            set "safe_workspace_path=!workspace_path!"
        )
    )
    
    REM Add to sessions array (include remote_host, recent session)
    if "!active_sessions_first!"=="0" set "active_sessions_array=!active_sessions_array!,"
    set "active_sessions_array=!active_sessions_array!{"storage_file_path":"!safe_storage_path!","connection_type":"!connection_type!","remote_host":"!remote_host!","user":"!SSH_USER_RESULT!","auth_method":"!SSH_AUTH_RESULT!","window_type":"!window_type!","workspace_path":"!safe_workspace_path!","is_active":false}"
    set "active_sessions_first=0"
    set /a "sessions_in_chunk+=1"
    set /a "total_sessions+=1"
    
    REM Output chunk when limit reached
    if !sessions_in_chunk! EQU !chunk_size! (
        call :output_session_chunk "!target_user!" !current_chunk!
        call :reset_session_chunk
    )
)
exit /b 0

:get_container_name_from_hex
set "hex_input=%~1"
set "CONTAINER_NAME_RESULT=unknown"

REM Hex: {"containerName":"/name","settings":{...}}
REM Search for 222f (":/) pattern which comes right before the container name
REM This is more robust than hardcoded position

REM Search for 222f pattern (quote-slash: ":"/ before name)
set "search_pos=0"
set "name_start=-1"

:hex_search_loop
set "test_chunk=!hex_input:~%search_pos%,4!"
if "!test_chunk!"==" " goto hex_search_done
if "!test_chunk!"=="222f" (
    REM Found quote-slash, name starts after it
    set /a "name_start=search_pos + 4"
    goto hex_search_done
)
set /a "search_pos+=2"
if !search_pos! LSS 200 goto hex_search_loop

:hex_search_done
if !name_start! LSS 0 exit /b 0

REM Extract and decode the name
set "name_hex=!hex_input:~%name_start%,100!"
set "name_decoded="
set "char_pos=0"

:decode_name_char
set "hex_char=!name_hex:~%char_pos%,2!"
if "!hex_char!"==" " goto name_done
if "!hex_char!"=="22" goto name_done
if "!hex_char!"=="2c" goto name_done

REM Decode common container name characters
if "!hex_char!"=="2d" set "name_decoded=!name_decoded!-"
if "!hex_char!"=="2e" set "name_decoded=!name_decoded!."
if "!hex_char!"=="30" set "name_decoded=!name_decoded!0"
if "!hex_char!"=="31" set "name_decoded=!name_decoded!1"
if "!hex_char!"=="32" set "name_decoded=!name_decoded!2"
if "!hex_char!"=="33" set "name_decoded=!name_decoded!3"
if "!hex_char!"=="34" set "name_decoded=!name_decoded!4"
if "!hex_char!"=="35" set "name_decoded=!name_decoded!5"
if "!hex_char!"=="36" set "name_decoded=!name_decoded!6"
if "!hex_char!"=="37" set "name_decoded=!name_decoded!7"
if "!hex_char!"=="38" set "name_decoded=!name_decoded!8"
if "!hex_char!"=="39" set "name_decoded=!name_decoded!9"
if "!hex_char!"=="5f" set "name_decoded=!name_decoded!_"
if "!hex_char!"=="61" set "name_decoded=!name_decoded!a"
if "!hex_char!"=="62" set "name_decoded=!name_decoded!b"
if "!hex_char!"=="63" set "name_decoded=!name_decoded!c"
if "!hex_char!"=="64" set "name_decoded=!name_decoded!d"
if "!hex_char!"=="65" set "name_decoded=!name_decoded!e"
if "!hex_char!"=="66" set "name_decoded=!name_decoded!f"
if "!hex_char!"=="67" set "name_decoded=!name_decoded!g"
if "!hex_char!"=="68" set "name_decoded=!name_decoded!h"
if "!hex_char!"=="69" set "name_decoded=!name_decoded!i"
if "!hex_char!"=="6a" set "name_decoded=!name_decoded!j"
if "!hex_char!"=="6b" set "name_decoded=!name_decoded!k"
if "!hex_char!"=="6c" set "name_decoded=!name_decoded!l"
if "!hex_char!"=="6d" set "name_decoded=!name_decoded!m"
if "!hex_char!"=="6e" set "name_decoded=!name_decoded!n"
if "!hex_char!"=="6f" set "name_decoded=!name_decoded!o"
if "!hex_char!"=="70" set "name_decoded=!name_decoded!p"
if "!hex_char!"=="71" set "name_decoded=!name_decoded!q"
if "!hex_char!"=="72" set "name_decoded=!name_decoded!r"
if "!hex_char!"=="73" set "name_decoded=!name_decoded!s"
if "!hex_char!"=="74" set "name_decoded=!name_decoded!t"
if "!hex_char!"=="75" set "name_decoded=!name_decoded!u"
if "!hex_char!"=="76" set "name_decoded=!name_decoded!v"
if "!hex_char!"=="77" set "name_decoded=!name_decoded!w"
if "!hex_char!"=="78" set "name_decoded=!name_decoded!x"
if "!hex_char!"=="79" set "name_decoded=!name_decoded!y"
if "!hex_char!"=="7a" set "name_decoded=!name_decoded!z"

set /a "char_pos+=2"
goto decode_name_char

:name_done
if not "!name_decoded!"==" " (
    set "CONTAINER_NAME_RESULT=!name_decoded!"
)
exit /b 0

:get_devcontainer_hostpath_from_hex
REM Extract hostPath from dev-container hex blob
REM Format: {"hostPath":"c:\\Users\\...","localDocker":...}
REM "hostPath":" = 22686f737450617468223a22
set "hex_input=%~1"
set "DEVCONTAINER_HOSTPATH_RESULT=unknown"

REM Search for hostPath pattern: 22686f737450617468223a22
set "search_pos=0"
set "path_start=-1"

:devcontainer_hex_search_loop
call set "test_chunk=%%hex_input:~!search_pos!,24%%"
if "!test_chunk!"=="" goto devcontainer_hex_search_done
REM Check for "hostPath":" pattern (22686f737450617468223a22)
if "!test_chunk!"=="22686f737450617468223a22" (
    REM Found hostPath, value starts after this 24-char pattern
    set /a "path_start=!search_pos! + 24"
    goto devcontainer_hex_search_done
)
set /a "search_pos+=2"
if !search_pos! LSS 200 goto devcontainer_hex_search_loop

:devcontainer_hex_search_done
if !path_start! LSS 0 exit /b 0

REM Extract and decode the path value (until closing quote 22 or comma 2c)
call set "path_hex=%%hex_input:~!path_start!,400%%"
set "path_decoded="
set "char_pos=0"

:decode_devcontainer_path_char
call set "hex_char=%%path_hex:~!char_pos!,2%%"
if "!hex_char!"=="" goto devcontainer_path_done
if "!hex_char!"=="22" goto devcontainer_path_done
if "!hex_char!"=="2c" goto devcontainer_path_done

REM Skip escaped backslashes (5c5c = \\) - just output single backslash
if "!hex_char!"=="5c" (
    set /a "next_pos=!char_pos!+2"
    call set "next_char=%%path_hex:~!next_pos!,2%%"
    if "!next_char!"=="5c" (
        set "path_decoded=!path_decoded!\"
        set /a "char_pos+=4"
        goto decode_devcontainer_path_char
    )
    set "path_decoded=!path_decoded!\"
    set /a "char_pos+=2"
    goto decode_devcontainer_path_char
)

REM Decode path characters (a-z, A-Z, 0-9, and common path chars)
if "!hex_char!"=="2d" set "path_decoded=!path_decoded!-"
if "!hex_char!"=="2e" set "path_decoded=!path_decoded!."
if "!hex_char!"=="2f" set "path_decoded=!path_decoded!/"
if "!hex_char!"=="30" set "path_decoded=!path_decoded!0"
if "!hex_char!"=="31" set "path_decoded=!path_decoded!1"
if "!hex_char!"=="32" set "path_decoded=!path_decoded!2"
if "!hex_char!"=="33" set "path_decoded=!path_decoded!3"
if "!hex_char!"=="34" set "path_decoded=!path_decoded!4"
if "!hex_char!"=="35" set "path_decoded=!path_decoded!5"
if "!hex_char!"=="36" set "path_decoded=!path_decoded!6"
if "!hex_char!"=="37" set "path_decoded=!path_decoded!7"
if "!hex_char!"=="38" set "path_decoded=!path_decoded!8"
if "!hex_char!"=="39" set "path_decoded=!path_decoded!9"
if "!hex_char!"=="3a" set "path_decoded=!path_decoded!:"
if "!hex_char!"=="41" set "path_decoded=!path_decoded!A"
if "!hex_char!"=="42" set "path_decoded=!path_decoded!B"
if "!hex_char!"=="43" set "path_decoded=!path_decoded!C"
if "!hex_char!"=="44" set "path_decoded=!path_decoded!D"
if "!hex_char!"=="45" set "path_decoded=!path_decoded!E"
if "!hex_char!"=="46" set "path_decoded=!path_decoded!F"
if "!hex_char!"=="47" set "path_decoded=!path_decoded!G"
if "!hex_char!"=="48" set "path_decoded=!path_decoded!H"
if "!hex_char!"=="49" set "path_decoded=!path_decoded!I"
if "!hex_char!"=="4a" set "path_decoded=!path_decoded!J"
if "!hex_char!"=="4b" set "path_decoded=!path_decoded!K"
if "!hex_char!"=="4c" set "path_decoded=!path_decoded!L"
if "!hex_char!"=="4d" set "path_decoded=!path_decoded!M"
if "!hex_char!"=="4e" set "path_decoded=!path_decoded!N"
if "!hex_char!"=="4f" set "path_decoded=!path_decoded!O"
if "!hex_char!"=="50" set "path_decoded=!path_decoded!P"
if "!hex_char!"=="51" set "path_decoded=!path_decoded!Q"
if "!hex_char!"=="52" set "path_decoded=!path_decoded!R"
if "!hex_char!"=="53" set "path_decoded=!path_decoded!S"
if "!hex_char!"=="54" set "path_decoded=!path_decoded!T"
if "!hex_char!"=="55" set "path_decoded=!path_decoded!U"
if "!hex_char!"=="56" set "path_decoded=!path_decoded!V"
if "!hex_char!"=="57" set "path_decoded=!path_decoded!W"
if "!hex_char!"=="58" set "path_decoded=!path_decoded!X"
if "!hex_char!"=="59" set "path_decoded=!path_decoded!Y"
if "!hex_char!"=="5a" set "path_decoded=!path_decoded!Z"
if "!hex_char!"=="5f" set "path_decoded=!path_decoded!_"
if "!hex_char!"=="61" set "path_decoded=!path_decoded!a"
if "!hex_char!"=="62" set "path_decoded=!path_decoded!b"
if "!hex_char!"=="63" set "path_decoded=!path_decoded!c"
if "!hex_char!"=="64" set "path_decoded=!path_decoded!d"
if "!hex_char!"=="65" set "path_decoded=!path_decoded!e"
if "!hex_char!"=="66" set "path_decoded=!path_decoded!f"
if "!hex_char!"=="67" set "path_decoded=!path_decoded!g"
if "!hex_char!"=="68" set "path_decoded=!path_decoded!h"
if "!hex_char!"=="69" set "path_decoded=!path_decoded!i"
if "!hex_char!"=="6a" set "path_decoded=!path_decoded!j"
if "!hex_char!"=="6b" set "path_decoded=!path_decoded!k"
if "!hex_char!"=="6c" set "path_decoded=!path_decoded!l"
if "!hex_char!"=="6d" set "path_decoded=!path_decoded!m"
if "!hex_char!"=="6e" set "path_decoded=!path_decoded!n"
if "!hex_char!"=="6f" set "path_decoded=!path_decoded!o"
if "!hex_char!"=="70" set "path_decoded=!path_decoded!p"
if "!hex_char!"=="71" set "path_decoded=!path_decoded!q"
if "!hex_char!"=="72" set "path_decoded=!path_decoded!r"
if "!hex_char!"=="73" set "path_decoded=!path_decoded!s"
if "!hex_char!"=="74" set "path_decoded=!path_decoded!t"
if "!hex_char!"=="75" set "path_decoded=!path_decoded!u"
if "!hex_char!"=="76" set "path_decoded=!path_decoded!v"
if "!hex_char!"=="77" set "path_decoded=!path_decoded!w"
if "!hex_char!"=="78" set "path_decoded=!path_decoded!x"
if "!hex_char!"=="79" set "path_decoded=!path_decoded!y"
if "!hex_char!"=="7a" set "path_decoded=!path_decoded!z"
if "!hex_char!"=="20" set "path_decoded=!path_decoded! "

set /a "char_pos+=2"
if !char_pos! LSS 400 goto decode_devcontainer_path_char

:devcontainer_path_done
if not "!path_decoded!"=="" (
    set "DEVCONTAINER_HOSTPATH_RESULT=!path_decoded!"
)
exit /b 0

:lookup_ssh_info_simple
set "host=%~1"
set "target_user=%~2"

REM Defaults
set "SSH_USER_RESULT=unknown"
set "SSH_AUTH_RESULT=password"

call :get_user_home "%target_user%"
if errorlevel 1 exit /b 0
set "user_home=!USER_HOME_RESULT!"

set "user_ssh_config=!user_home!\.ssh\config"

REM Read SSH config - first matching Host block wins
if exist "!user_ssh_config!" (
    set "in_host=0"
    set "found_match=0"
    set "found_user="
    set "found_auth="
    for /f "usebackq tokens=*" %%l in ("!user_ssh_config!") do (
        set "line=%%l"
        REM Skip empty lines and comments
        if not "!line!"=="" if not "!line:~0,1!"=="#" (
            REM Check if line starts with Host or Match (new block)
            echo !line! | findstr /B /C:"Host " /C:"Match " >nul 2>nul
            if not errorlevel 1 (
                REM If we were in a matching block, we're done (first match wins)
                if "!in_host!"=="1" (
                    set "found_match=1"
                )
                set "in_host=0"
                REM Only check for new match if we haven't found one yet
                if "!found_match!"=="0" (
                    REM Check if this Host line matches our target exactly
                    for /f "tokens=1,*" %%a in ("!line!") do (
                        if /I "%%a"=="Host" (
                            for %%p in (%%b) do (
                                if "%%p"=="!host!" set "in_host=1"
                                if "%%p"=="*" set "in_host=1"
                            )
                        )
                    )
                )
            ) else if "!in_host!"=="1" if "!found_match!"=="0" (
                REM Extract User (only if not already found)
                if not defined found_user (
                    if not "!line:User =!"=="!line!" (
                        for /f "tokens=2" %%u in ("!line!") do (
                            if not "%%u"=="" set "found_user=%%u"
                        )
                    )
                )
                REM Extract auth from IdentityFile (only if not already found)
                if not defined found_auth (
                    if not "!line:IdentityFile =!"=="!line!" set "found_auth=publickey"
                )
                REM Extract PreferredAuthentications (overrides IdentityFile)
                if not "!line:PreferredAuthentications =!"=="!line!" (
                    for /f "tokens=2" %%a in ("!line!") do (
                        if not "%%a"=="" set "found_auth=%%a"
                    )
                )
            )
        )
    ) 2>nul
    REM Apply found values
    if defined found_user set "SSH_USER_RESULT=!found_user!"
    if defined found_auth set "SSH_AUTH_RESULT=!found_auth!"
)

exit /b 0

:main_execution

call :get_users_to_process

REM Define all supported variants
set "VARIANT_LIST=stable insiders vscodium cursor code-oss windsurf"

REM Grant SYSTEM read access to .ssh\config if requested (once per user)
set "SSH_ACCESS_GRANTED_USERS="

REM Process users
for %%u in (!USERS_LIST!) do (
    set "target_user=%%u"
    
    REM Grant SSH access if flag set and not already done for this user
    if "!GRANT_SSH_ACCESS!"=="1" (
        echo !SSH_ACCESS_GRANTED_USERS! | findstr /i /c:"!target_user!" >nul 2>nul
        if errorlevel 1 (
            call :get_user_home "!target_user!"
            if not errorlevel 1 (
                set "ssh_config_path=!USER_HOME_RESULT!\.ssh\config"
                if exist "!ssh_config_path!" (
                    REM Check if SYSTEM already has read access before granting
                    icacls "!ssh_config_path!" 2>nul | findstr /i /c:"NT AUTHORITY\SYSTEM" >nul 2>nul
                    if errorlevel 1 (
                        icacls "!ssh_config_path!" /grant "SYSTEM:R" >nul 2>nul
                    )
                )
            )
            if "!SSH_ACCESS_GRANTED_USERS!"=="" (
                set "SSH_ACCESS_GRANTED_USERS=!target_user!"
            ) else (
                set "SSH_ACCESS_GRANTED_USERS=!SSH_ACCESS_GRANTED_USERS! !target_user!"
            )
        )
    )
    
    REM Process each VS Code variant
    for %%v in (!VARIANT_LIST!) do (
        set "current_variant_loop=%%v"
        
        REM Detect paths for this variant
        call :detect_variant_paths "!target_user!" "!current_variant_loop!"
        if not errorlevel 1 (
            REM Always collect installation info for all variants (doesn't require user dir)
            if "%COLLECT_INSTALLATION%"=="1" (
                call :process_installation "!target_user!"
            )
            
            REM Skip remaining collections if user directory doesn't exist
            if exist "!VSCODE_USER_DIR!" (
                REM Full data collection for this variant
                if "!COLLECT_FULL_DATA!"=="1" (
                    if "%COLLECT_SETTINGS%"=="1" (
                        call :process_settings "!target_user!"
                    )

                    if "%COLLECT_ARGV%"=="1" (
                        call :process_argv "!target_user!"
                    )

                    REM Unified workspace processing - hybrid approach
                    call :get_user_home "!target_user!"
                    if not errorlevel 1 (
                        call :process_workspace_files "!target_user!" "!USER_HOME_RESULT!"
                    )

                    if "%COLLECT_EXTENSIONS%"=="1" (
                        call :process_extensions_new "!target_user!"
                    )

                    if "%COLLECT_ACTIVE_SESSION%"=="1" (
                        call :active_session_func "!target_user!"
                    )
                )
            )
        )
    )
)

exit /b 0
