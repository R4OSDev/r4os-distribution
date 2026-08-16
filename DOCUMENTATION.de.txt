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
    Build.bat headless Test

Ein uebergeordneter Workspace-Build darf diese Aktionen aufrufen, erzeugt
Images oder QEMU-Aufrufe aber nicht selbst. Damit bleibt dieses `Build.bat`
die einzige Implementierung fuer Planmontage, Image, Verifikation und QEMU.

Die QEMU-Software selbst liegt ausschliesslich im DevKit unter dem durch
`QEMU_ROOT` gemappten `Emulation/QEMU`. Dieses Repository enthaelt unter
`QEMU/` nur R4OS-spezifische Konfiguration. `qemu` startet ein Profil mit
GUI; `headless Test` erzeugt vor jedem Lauf ein frisches Datenimage, schreibt
serielle Logs unter `Artifacts/Distribution/Logs`, wertet die verbindlichen
Boot-/API-Marker aus und verlangt ein geordnetes Gast-Poweroff.

`Build.bat test` baut alle sieben Hosttools und prueft die Slim-, Full- und
Test-Imageplaene bytegenau, mit einem negativen Kollisionstest und mit dem
Selbsttest der Headless-Markerauswertung. Der echte Gastlauf ist die getrennte
Aktion `headless Test`. Unter Linux und macOS stehen Hosttool-Build, Tests und
Plangenerierung ueber `Build.sh` bereit; der 0.64-Umbau wird praktisch auf
Windows abgenommen.

Die Quellen fuer die 14 installierten R4OS-Systemfonts liegen unter
`Assets/SystemFonts`; der Distribution-Build erzeugt daraus Hostartefakte,
der Workspace nimmt diese explizit in `Common.plan` auf. Der bekannte
synthetische Schluessel-/Zertifikatpaar unter `TestInjection` ist eine
oeffentliche, nicht vertrauenswuerdige Testfixture. Nur das Testprofil ordnet
es als `R4TLSDEV.KEY`, `R4TLSDEV.CRT` und Test-Trust-Anchor zu. Es ist nicht
bytegleich mit dem lokalen Entwicklungsschluessel; normale Images erhalten
keinen privaten Schluessel aus dem Repository.

Private Dateien
---------------

Private Injection-Dateien liegen ausschliesslich im durch `Settings.R4S`
gemappten lokalen `PrivateInjection`-Ordner. Ein dortiger Pfad ueberschreibt
denselben relativen Pfad aus `Injection` beziehungsweise `TestInjection`.
Schluesseldateien werden durch `.gitignore` nie versioniert.

Herkunft und Transfergrenzen stehen in `PROVENANCE.txt`.
