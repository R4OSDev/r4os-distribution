R4OS Distribution
==================

Dieses Repository besitzt die reproduzierbare Image- und Releaseintegration
von R4OS. Es enthaelt die oeffentliche System-Injection, die Profile `Slim`,
`Full` und `Test`, QEMU-Konfiguration und distributionsspezifische Hosttools.

Repositorygrenze
----------------

Die Distribution konsumiert ausschliesslich fertige Kernel-, Library-,
Treiber-, Protokoll- und Softwareartefakte ueber explizite Plan-Dateien. Sie
baut keine fachliche Komponente aus deren Quellcode. Plattform-API und ABI
bleiben Eigentum von Contract und SDK.

Pfade und Inputs
----------------

`Settings.R4S` mappt Workspace, Repositories, SDK, Contract, DevKit sowie den
lokalen Artefaktbereich. Relative Pfade sind die portable Voreinstellung;
jeder Eintrag kann durch einen anderen relativen oder absoluten Pfad ersetzt
werden. Der genaue Inputvertrag steht in `INPUTS.txt`.

Build und Abnahme
-----------------

Unter Windows:

    Build.bat
    Build.bat test
    Build.bat plan Full
    Build.bat image Full
    Build.bat verify Full
    Build.bat qemu Full

Ein uebergeordneter Workspace-Build darf diese Aktionen aufrufen, erzeugt
Images oder QEMU-Aufrufe aber nicht selbst. Damit bleibt dieses `Build.bat`
die einzige Implementierung fuer Planmontage, Image, Verifikation und QEMU.

`Build.bat test` baut alle sieben Hosttools und prueft die Slim-, Full- und
Test-Imageplaene bytegenau sowie mit einem negativen Kollisionstest. Unter
Linux und macOS stehen Hosttool-Build, Tests und Plangenerierung ueber
`Build.sh` bereit; der 0.64-Umbau wird praktisch auf Windows abgenommen.

Private Dateien
---------------

Private Injection-Dateien liegen ausschliesslich im durch `Settings.R4S`
gemappten lokalen `PrivateInjection`-Ordner. Ein dortiger Pfad ueberschreibt
denselben relativen Pfad aus `Injection` beziehungsweise `TestInjection`.
Schluesseldateien werden durch `.gitignore` nie versioniert.

Herkunft und Transfergrenzen stehen in `PROVENANCE.txt`.
