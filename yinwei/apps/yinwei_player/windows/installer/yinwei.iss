; Yinwei Spatial Player — Windows installer for the Flutter desktop build.
; This is not a web/JS package. It installs yinwei_player.exe + native DLLs.
; Silent auto-update is not performed.

#define MyAppName "Yinwei Spatial Player"
#define MyAppNameZh "音围"
#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#define MyAppPublisher "Yinwei"
#define MyAppExeName "yinwei_player.exe"

#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist\windows"
#endif

[Setup]
AppId={{8F3C1A6E-4B2D-4F91-9C55-7A2E6D1B90C4}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppNameZh} {#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppCopyright=Copyright (C) 2026 Yinwei
DefaultDirName={autopf}\Yinwei
DefaultGroupName=Yinwei
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=YinweiSetup-{#MyAppVersion}-windows-x64
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
MinVersion=10.0
CloseApplications=yes
RestartApplications=no
ChangesAssociations=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Comment: "{#MyAppNameZh} Spatial Player"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
