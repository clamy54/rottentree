; Installeur Windows de Rottentree (Inno Setup 6).
; Prerequis: scripts\build.ps1 -Release (bin\rottentree.exe et ses DLL).
; Compilation: ISCC.exe dist\windows\rottentree.iss
;
; AppVersion vient de RT_VERSION (src\util\uVersion.pas), extrait a chaque
; compilation par make-version.ps1. Introuvable = erreur, jamais de version
; inventee: un installeur 1.0 qui pose un binaire 0.9 se debogue en production.

#define AppName "Rottentree"
#define AppPublisher "Cyril LAMY"
#define AppExe "rottentree.exe"

#define VerRC Exec("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File """ + SourcePath + "\make-version.ps1""", SourcePath, 1, 0)
#if VerRC != 0
  #error make-version.ps1 a echoue: version non extraite de src\util\uVersion.pas
#endif
#include "version.iss"

; Inno affiche le markdown tel quel: third-party.txt en est la version lisible,
; regeneree ici a chaque compilation pour ne jamais deriver de sa source.
#define NoticesRC Exec("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File """ + SourcePath + "\make-notices.ps1""", SourcePath, 1, 0)
#if NoticesRC != 0
  #error make-notices.ps1 a echoue: page des licences tierces non regeneree
#endif

[Setup]
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppSupportURL=https://github.com/clamy54/Rottentree
DefaultDirName={autopf}\Rottentree
DefaultGroupName=Rottentree
DisableProgramGroupPage=yes
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog commandline
UninstallDisplayIcon={app}\{#AppExe}
LicenseFile=..\..\LICENSE
InfoBeforeFile=third-party.txt
OutputDir=output
OutputBaseFilename=Rottentree-Setup-{#AppVersion}
SetupIconFile=..\..\app\rottentree.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\bin\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\app\rottentree.ico"; DestDir: "{app}"
; Les DLL vont A COTE de l'exe, pas dans un sous-dossier: le chargeur ne
; regarde que la, et c'est voulu. Une libcrypto trouvee au hasard du PATH n'a
; pas a signer les echanges TLS de l'annuaire.
Source: "..\..\bin\libldap.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\bin\liblber.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\bin\libsasl2-3.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\bin\libssl-3-x64.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\bin\libcrypto-3-x64.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\bin\libsodium-26.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\bin\libsqlite3-0.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\bin\libargon2.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"
Source: "..\..\licenses\*"; DestDir: "{app}\licenses"
Source: "..\..\rottenui\assets\licenses\*"; DestDir: "{app}\licenses"

[Icons]
Name: "{group}\Rottentree"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\rottentree.ico"
Name: "{group}\{cm:UninstallProgram,Rottentree}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Rottentree"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\rottentree.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,Rottentree}"; Flags: nowait postinstall skipifsilent
