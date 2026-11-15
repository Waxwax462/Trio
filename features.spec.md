# Feature-Spec: Therapieprofile (#21), Sport-Profile (#13), Geführte Tests (#24)

Arbeitsgrundlage für die Implementierung in diesem Fork (`Waxwax462/Trio`, Upstream `nightscout/Trio`, Stand v1.0.2).
Die Akzeptanzkriterien stehen in den Issues; diese Datei hält fest, **wie** sie in den vorhandenen Code passen.
Alles unter „Ist-Zustand" wurde am Code geprüft. Alles unter „Entwurf" ist ein Vorschlag und noch nicht umgesetzt.

- #21 https://github.com/Waxwax462/Trio/issues/21
- #13 https://github.com/Waxwax462/Trio/issues/13
- #24 https://github.com/Waxwax462/Trio/issues/24

---

## 1. Rahmenbedingungen

### 1.1 Bauen und Testen

- Die Entwicklungsumgebung ist Windows ohne Xcode. **Hier kann weder gebaut noch getestet werden.** Jede Änderung ist ungeprüft, bis sie auf einem Mac gebaut wurde. Das im Abschlussbericht immer so benennen.
- `.github/workflows/unit_tests.yml` läuft nur bei `github.repository_owner == 'nightscout'` und nur für den Branch `dev`. Im Fork laufen also keine Tests automatisch. `build_trio.yml` ist ebenfalls an `nightscout` gebunden.
- Tests nutzen Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), nicht XCTest. Vorlage: `TrioTests/AdjustmentsTests/AdjustmentManagerTests.swift` mit `CoreDataStack.createForTests()` und `TrioTests/CoreDataTests/TestAssembly.swift`.

### 1.2 Xcode-Projekt

- `Trio.xcodeproj/project.pbxproj` (objectVersion 70) synchronisiert nur die Ordner `Views` und `Preview Content` automatisch.
- **Jede andere neue Swift-Datei braucht vier Einträge in der `project.pbxproj`:** `PBXBuildFile`, `PBXFileReference`, Eintrag in der passenden `PBXGroup`, Eintrag in der `Sources`-Build-Phase des Targets. Das gilt auch für Testdateien (Target `TrioTests`).
- Vorgehen: einen vorhandenen Dateinamen aus demselben Ordner in der `project.pbxproj` suchen und dessen vier Stellen als Muster nehmen. IDs sind 24 Hex-Zeichen und müssen eindeutig sein.

### 1.3 Architektur-Muster

- **Modul** = `enum <Name>` als Namespace mit vier Dateien: `<Name>DataFlow.swift` (Namespace, Provider-Protokoll), `<Name>Provider.swift` (`BaseProvider`), `<Name>StateModel.swift` (`BaseStateModel<Provider>`), `View/<Name>RootView.swift` (`BaseView`, bekommt `resolver`). Kleinste Vorlage: `Trio/Sources/Modules/TargetsEditor/`.
- **Navigation:** neuer `case` in `Trio/Sources/Router/Screen.swift` plus Zuordnung zur `RootView` in derselben Datei. Eintrag für Einstellungen und Suche in `Trio/Sources/Modules/Settings/SettingItems.swift` (es gibt `SettingsSearchTests`).
- **Dependency Injection:** Swinject. Protokoll + `Base…`-Klasse mit `Injectable` und `@Injected()`, Registrierung in `Trio/Sources/Assemblies/` (`ServiceAssembly.swift`, `StorageAssembly.swift`).
- **Benachrichtigung über Änderungen:** `broadcaster.notify(<X>Observer.self, on: .main) { … }`. Vorhanden: `BasalProfileObserver`, `InsulinSensitivitiesObserver`, `CarbRatiosObserver`, `BGTargetsObserver`, `TempTargetsObserver`, `SettingsObserver`, `PreferencesObserver`.
- **Datei-Speicher:** `FileStorage` (`storage.retrieve(_:as:)`, `storage.save(_:as:)`), Pfade in `Trio/Sources/APS/OpenAPS/Constants.swift`. Typen sind `JSON`-konform.
- **Core Data:** ein einziges Modell ohne Versionen (`Model/TrioCoreDataPersistentContainer.xcdatamodeld`), automatische Lightweight-Migration ist an, Klassen liegen von Hand geschrieben in `Model/Classes+Properties/`. Upstream ändert das Modell direkt. Zugriff über `CoreDataStack.shared.newTaskContext()` und `fetchEntitiesAsync`.

### 1.4 Konventionen (aus `CONTRIBUTING.md`)

- Nur englische Quelltexte für UI-Strings, über `String(localized: "…", comment: "…")`. Übersetzungen laufen über Crowdin, nicht von Hand. `LocalizationTests` prüft Formatstrings auf einzelne `%`.
- Bestehende Formatierung beibehalten, keine reinen Formatierungs-Änderungen in fremden Dateien. `scripts/swiftformat.sh` ist vorhanden.
- Upstream entwickelt auf `dev`; dieser Fork hat nur `main`. Feature-Branches vorerst von `main`, ein Branch je Issue.

### 1.5 Sicherheitsregeln für alle drei Features

Die App dosiert Insulin. Daraus folgt:

1. Der Algorithmus (`Trio/Sources/APS/OpenAPSSwift/`, `AlgorithmPackage/`, `trio-oref/`) wird nicht verändert. Alle drei Features speisen nur die vorhandenen Eingänge.
2. Nichts ändert Therapie-Einstellungen ohne ausdrückliche Bestätigung des Nutzers.
3. Basalraten gehen immer zuerst an die Pumpe (`pump.syncBasalRateSchedule`) und erst bei Erfolg in die Datei. Schlägt die Pumpe fehl, bleibt alles beim Alten.
4. Werte, die die Editoren nicht zulassen, lässt auch kein neues Feature zu (Basal > 0 und in `pumpManager.supportedBasalRates`, Ziel 72–180 mg/dL wie in `TargetsEditorStateModel.rateValues`).
5. Intern wird in mg/dL gerechnet und gespeichert; mmol/L ist nur Anzeige.

---

## 2. Reihenfolge

1. **#21 Therapieprofile** – kleinster Eingriff, und #24 braucht später einen sauberen Weg, einen Vorschlag in die Einstellungen zu schreiben.
2. **#13 Sport-Profile** – baut auf dem vorhandenen `AdjustmentManager` auf.
3. **#24 Geführte Tests** – größter Analyse-Anteil; zuerst nur die rückblickende Basal-Auswertung.

Keines der drei Features braucht eine Änderung am Core-Data-Modell (siehe Entwürfe). Das ist Absicht: es vermeidet Migrationsrisiko auf einem Gerät mit echten Daten.

---

## 3. #21 Umschaltbare Therapieprofile

### Ist-Zustand

- Es gibt genau einen Satz Einstellungen, verteilt auf vier Dateien (`OpenAPS.Settings`):
  - `settings/basal_profile.json` → `[BasalProfileEntry]` (`start`, `minutes`, `rate`)
  - `settings/insulin_sensitivities.json` → `InsulinSensitivities` (`sensitivities: [sensitivity, offset, start]`)
  - `settings/carb_ratios.json` → `CarbRatios` (`schedule: [start, offset, ratio]`)
  - `settings/bg_targets.json` → `BGTargets` (`targets: [low, high, start, offset]`)
- Schreibende Stellen: die vier Editor-Provider (`BasalProfileEditor`, `ISFEditor`, `CarbRatioEditor`, `TargetsEditor`), außerdem `OnboardingStateModel`, `AutotuneConfigStateModel` und die mmol-Migration in `FileStorage`.
- Nur Basal geht an die Pumpe: `BasalProfileEditorProvider.saveProfile` ruft `pump.syncBasalRateSchedule(items:)` und schreibt die Datei erst im Erfolgsfall.
- Nach dem Speichern machen die StateModels jeweils: Observer benachrichtigen, `nightscout.uploadProfiles()`, `tidepoolManager.uploadSettings()`.
- `NightscoutManager.uploadProfiles()` lädt genau ein Profil mit dem festen Namen `"default"` hoch.
- `SettingsExportStateModel` liest die vier Dateien direkt.

### Entwurf

**Grundsatz:** Die vier Dateien bleiben die einzige Quelle für den Algorithmus und für alle bestehenden Bildschirme. Die Profil-Bibliothek liegt daneben und enthält Kopien.

- Modell `TherapyProfile: JSON, Identifiable` mit `id`, `name`, `basal`, `sensitivities`, `carbRatios`, `targets`, `updatedAt`.
- Speicher: neue Datei `freeaps/therapy_profiles.json` mit `{ activeProfileID, profiles: [TherapyProfile] }`. Konstante in `Constants.swift` unter `OpenAPS.FreeAPS`.
- Dienst `TherapyProfileManager` (Protokoll + `BaseTherapyProfileManager`, in `ServiceAssembly`):
  - `profiles()`, `activeProfile()`
  - `create(name:from:percentage:)`, `rename`, `delete` (aktives Profil nicht löschbar)
  - `diff(to:)` → Liste der Unterschiede zum aktiven Satz, für den Bestätigungs-Dialog
  - `activate(_ id:) async throws`
- Erster Start: Die Bibliothek ist leer → aus den vier Dateien ein Profil „Standard" anlegen und als aktiv markieren.
- **Ablauf `activate`:**
  1. Den aktuellen Inhalt der vier Dateien in den Eintrag des bisher aktiven Profils zurückschreiben. So bleiben die Editoren unverändert, und Änderungen dort gehen nicht verloren.
  2. Zielprofil validieren (Regeln aus 1.5).
  3. Basal an die Pumpe. Bei Fehler: abbrechen, nichts geschrieben, Fehler anzeigen.
  4. Alle vier Dateien schreiben, `activeProfileID` setzen.
  5. Die vier Observer benachrichtigen, `uploadProfiles()`, `uploadSettings()`, danach `apsManager.determineBasalSync()`.
- Schritt 1 deckt auch Onboarding, Autotune und Import ab, ohne dass diese Stellen angefasst werden müssen.
- „Duplizieren mit Prozent": Basal × p, ISF ÷ p, CR ÷ p, Ziele unverändert; Basal auf `supportedBasalRates` runden.
- Modul `TherapyProfiles` (Liste, Anlegen/Duplizieren, Diff + Bestätigen), erreichbar unter „Therapy Settings". Name des aktiven Profils im Home-Header.
- Shortcuts-Intent „Activate Therapy Profile" nach dem Muster in `Trio/Sources/Shortcuts/Override/`.
- Export: Profil-Bibliothek in `SettingsExportStateModel` ergänzen.

### Bewusst später

- Zeitgesteuertes Umschalten (von/bis). Braucht denselben Hintergrund-Takt wie #13 (Abschnitt 4).
- Eintrag in einer Änderungshistorie – die gibt es noch nicht (#20). Bis dahin nur `debug(.service, …)`.

### Offen

- Nightscout: Reicht es, das aktive Profil weiter als `"default"` hochzuladen, oder soll ein „Profile Switch"-Eintrag mit Profilnamen erzeugt werden? Der vorhandene Upload kennt nur `"default"`.
- Soll das Umschalten eine Authentifizierung (Face ID) verlangen? Prüfen, wie die Editoren das heute lösen (`Services/UnlockManager`).

### Tests

- `activate` schreibt bei Pumpenfehler nichts (Dateien und `activeProfileID` unverändert).
- Rückschreiben in Schritt 1: Editor-Änderung am aktiven Profil überlebt Hin- und Zurückschalten.
- Erster Start erzeugt genau ein Profil aus den vorhandenen Dateien.
- Prozent-Duplikat: Rundung, keine Rate ≤ 0.

---

## 4. #13 Mehrphasige Sport-Profile

### Ist-Zustand

- **Override** (`OverrideStored`): `percentage`, `target`, `duration`, `indefinite`, `smbIsOff`, `smbIsScheduledOff`/`start`/`end`, `isf`/`cr`/`isfAndCr`, `smbMinutes`, `uamMinutes`, `isPreset`, `enabled`, `date`. Der Algorithmus bekommt den ersten aktiven Override über `OpenAPS.prepareTrioCustomOrefVariables` (`TrioCustomOrefVariables`).
- **Temp Target** (`TempTargetStored`): `target`, `duration`, `halfBasalTarget`, `enabled`, `date`, `enteredBy`. Der Algorithmus liest den neuesten Eintrag aus `settings/temptargets.json`.
- **`AdjustmentManager`** (`Trio/Sources/Services/Adjustments/AdjustmentManager.swift`) ist der zentrale Weg für Aktivieren und Beenden: beendet alle aktiven Zeilen, schreibt `OverrideRunStored`/`TempTargetRunStored`, aktiviert die neue Zeile, stößt Nightscout-Upload und `determineBasalSync()` an, serialisiert über einen Actor. Aufrufer: Shortcuts, Remote Control, Watch. Adressierung über `AdjustmentRef` (`.objectID`, `.presetID`, `.presetName`), Herkunft über `AdjustmentSource`.
- Die In-App-Oberfläche (`AdjustmentsStateModel+Overrides.swift`, `+TempTargets.swift`) hat einen eigenen, älteren Weg direkt auf dem `viewContext`.
- Geplante Temp Targets warten per `Task.sleep`-Schleife im StateModel (`waitUntilDate`). Das funktioniert nur, solange dieses Objekt lebt. **Nicht als Vorlage für Phasenwechsel verwenden.**
- Das Adjustments-Modul hat zwei Tabs (`Adjustments.Tab`: `overrides`, `tempTargets`).
- Overrides werden als Nightscout-„Exercise"-Ereignisse hochgeladen; die tatsächliche Dauer kommt über die Run-Einträge.

### Entwurf

**Grundsatz:** Eine Phase ist ein gewöhnlicher Override. Das Sport-Profil ist nur der Ablaufplan, der nacheinander Overrides aktiviert. Der Algorithmus sieht nichts Neues.

- Modelle (JSON, keine Core-Data-Änderung):
  - `SportProfile`: `id`, `name`, `template`, `phases: [SportPhase]`
  - `SportPhase`: `kind` (`pre` | `during` | `recovery`), `durationMinutes` (`nil` = offen, nur bei `during`), `percentage`, `target` (optional), `smbIsOff`
  - `SportProfileRun`: `profileID`, `phaseIndex`, `phaseStartedAt`, `startedAt`, `overrideID` der gerade laufenden Phase
- Speicher: `freeaps/sport_profiles.json` (Definitionen) und `freeaps/sport_profile_run.json` (laufender Ablauf, sonst leer). Der Ablauf muss einen App-Neustart überleben.
- Dienst `SportProfileManager` (in `ServiceAssembly`):
  - `start(_ id:)`, `skipToNextPhase()`, `extendCurrentPhase(by:)`, `cancel()`
  - `tick(now:)` – prüft, ob die laufende Phase abgelaufen ist, und schaltet weiter
- **Phase starten:** eine nicht als Preset markierte `OverrideStored`-Zeile aus den Phasenwerten anlegen (`OverrideStorage.storeOverride`), dann `adjustmentManager.activateOverride(.objectID(…), source: .sportProfile)`. Neuer Fall `sportProfile` in `AdjustmentSource`. Name der Zeile: „<Profil> – <Phase>", damit Verlauf und Nightscout lesbar sind.
- **Phasenwechsel im Hintergrund:** `tick` wird aus dem Loop-Takt aufgerufen (`APSManager`, `heartbeat(date:)` bzw. `loop()`), vor der Berechnung. Genauigkeit damit etwa ±5 Minuten, was für Phasen von 30 Minuten aufwärts ausreicht. Die genaue Stelle beim Umsetzen am Code festlegen.
- **Fremdeingriff:** Ist beim `tick` nicht mehr der Override aus `overrideID` aktiv (Nutzer hat etwas anderes gesetzt oder abgebrochen), gilt der Ablauf als beendet. Manuelle Eingriffe gewinnen immer.
- **Ende:** Nach der letzten Phase `cancelOverride`, Ablauf-Datei leeren.
- Oberfläche: dritter Tab im Adjustments-Modul (`Adjustments.Tab.sportProfiles`) mit Liste, Editor (Phasen als Abschnitte) und Start. Auf dem Home-Bildschirm: aktuelle Phase, Restzeit, nächste Phase, Tasten „Nächste Phase" / „+15 min" / „Beenden".
- Vorlagen (Endurance, Intervals/HIIT, Strength, Competition, Long day) als fest hinterlegte Startwerte, die beim Anlegen kopiert und dann frei bearbeitet werden.
- Shortcuts-Intent „Start Sport Profile" nach dem Muster in `Trio/Sources/Shortcuts/Override/`.

### Bewusst später

- **Temp Target je Phase / Half-Basal-Target.** Der Override deckt Ziel, Prozent und SMB-aus bereits ab. Ein zusätzliches Temp Target je Phase verdoppelt die Fehlerquellen (zwei aktive Anpassungen, zwei Abläufe). Erst ergänzen, wenn es in der Praxis fehlt.
- Geplanter Start mit Vorlauf (das ist #15). In V1 startet „Pre" beim Antippen.
- Watch-Bedienung (`AppleWatchManager`, `OverridePresetWatch`).
- Automatisches Ende der „During"-Phase über Workout-Erkennung (#12). In V1 beendet der Nutzer sie von Hand.

### Offen

- Eine offene „During"-Phase braucht eine Obergrenze, damit ein vergessenes Profil nicht tagelang läuft. Vorschlag: einstellbar, Standard 6 Stunden, danach Wechsel in „Recovery" mit Mitteilung.
- Standardwerte der Vorlagen: müssen vom Nutzer kommen oder ausdrücklich als Platzhalter gekennzeichnet sein. Keine medizinischen Empfehlungen erfinden.

### Tests

- Ablauf über drei Phasen mit simulierter Zeit: je Phase genau ein aktiver Override, je Wechsel ein Run-Eintrag.
- Fremdeingriff beendet den Ablauf, ohne den fremden Override anzufassen.
- Neustart mitten in einer Phase: `tick` setzt korrekt fort; ist die Phase inzwischen abgelaufen, wird weitergeschaltet.
- Obergrenze der offenen Phase greift.

---

## 5. #24 Geführte Basal-, ISF- und CR-Tests

### Ist-Zustand (Datenquellen)

| Daten | Quelle |
|---|---|
| Glukose | `GlucoseStored` (`date`, `glucose`, `isManual`, `smoothedGlucose`) |
| Kohlenhydrate | `CarbEntryStored` (`date`, `carbs`, `fat`, `protein`, `isFPU`) |
| Boli | `PumpEventStored` → `BolusStored` (`amount`, `isSMB`, `isExternal`) |
| Temporäre Basalraten | `PumpEventStored` → `TempBasalStored` (`rate`, `duration`, `startDate`, `endDate`, `deliveredUnits`, `isScheduledBasal`) |
| Anpassungen im Zeitraum | `OverrideRunStored`, `TempTargetRunStored` (`startDate`, `endDate`) sowie aktuell aktive Zeilen |
| IOB / COB zum Zeitpunkt | `OrefDetermination` |
| Geplante Basalrate | `settings/basal_profile.json`; Hilfen in `ScheduledBasalInference.swift` und `TDDStorage` (`calculateTempBasalInsulin`, `calculateScheduledBasalInsulin`) |

Statistik-Auswertungen liegen im Modul `Stat` (`StatStateModel+Setup/`).

### Entwurf

**Grundsatz:** Die Auswertung ist reine, deterministische Rechnung über Wertetypen. Kein Core Data in der Rechenlogik, damit sie vollständig mit festen Eingabedaten testbar ist.

- Schicht 1 – `SettingsTestDataProvider`: liest einen Zeitraum aus Core Data und liefert Wertetypen (`[GlucosePoint]`, `[CarbEvent]`, `[BolusEvent]`, `[BasalSegment]`, `[AdjustmentInterval]`).
- Schicht 2 – `SettingsTestEvaluator` (ohne Abhängigkeiten): Fenster suchen, bewerten, Vorschlag bilden.
- Schicht 3 – Modul `SettingsTests`: Ergebnisliste, Detail, „Vorschlag übernehmen".
- Ergebnisse und Verlauf: `freeaps/settings_tests.json`.

**Stufe 1: Basal, rückblickend.** Zuerst nur das, ohne geführten Live-Test.

- Ein Fenster zählt, wenn darin und in der Vorlaufzeit gilt: keine Kohlenhydrate, kein manueller Bolus, keine aktive Anpassung (Override, Temp Target, Sport-Profil), COB = 0, lückenlose Glukosedaten, keine Behandlung einer Unterzuckerung. Vorlaufzeiten einstellbar (Vorschlag: 4 Stunden nach Essen/Bolus, 12 Stunden nach Sport – Letzteres erst prüfbar, wenn Sportdaten vorliegen; bis dahin über beendete Sport-Profile aus #13).
- Im geschlossenen Regelkreis gleicht der Loop eine falsche Basalrate aus. Deshalb wird nicht nur der Glukoseverlauf bewertet, sondern die **tatsächlich abgegebene** Insulinmenge (Temp-Basal plus SMB) gegen die geplante Basalrate gestellt:
  - `Bedarf ≈ abgegebene Rate + (Glukoseänderung pro Stunde ÷ ISF)`
- Ergebnis je Zeitblock des Basalprofils: geplante Rate, geschätzter Bedarf, Anzahl gültiger Fenster, Streuung.
- Ein Vorschlag entsteht erst ab einer Mindestzahl übereinstimmender Fenster (Vorschlag: 3), ist auf einen kleinen Schritt begrenzt (Vorschlag: höchstens ±10 % je Übernahme) und wird auf `supportedBasalRates` gerundet.
- Übernehmen läuft über denselben Weg wie der Basal-Editor (Pumpe zuerst). Mit #21 landet die Änderung im aktiven Profil.

**Stufe 2: ISF.** Korrekturbolus ohne Kohlenhydrate, beobachteter Abfall je Einheit, bereinigt um Abweichungen der Basalabgabe.

**Stufe 3: CR.** Mahlzeit mit bekannter Menge; setzt voraus, dass Basal und ISF als stimmig gelten.

**Stufe 4: Geführter Live-Test.** Vorbedingungen prüfen, Fortschritt anzeigen, Abbruch melden, wenn der Test ungültig wird.

### Offen

- Zahlenwerte (Vorlaufzeiten, Mindestzahl Fenster, Schrittgröße) sind Vorschläge und brauchen eine Entscheidung des Nutzers. Als einstellbare Werte mit konservativem Standard umsetzen.
- Umgang mit Autosens und dynamischem ISF: Der wirksame ISF im Fenster kann vom Profilwert abweichen. Für Stufe 1 den ISF aus `OrefDetermination` des Fensters verwenden, falls dort verfügbar – am Code prüfen.

### Tests

- Evaluator mit festen Datensätzen: stabile Nacht (kein Vorschlag), stetiger Anstieg bei Abgabe = Plan (Vorschlag nach oben), stabile Glukose bei dauerhaft reduzierter Abgabe (Vorschlag nach unten).
- Ausschlussgründe einzeln: Kohlenhydrate, Bolus, Anpassung, Datenlücke.
- Schrittbegrenzung und Rundung; kein Vorschlag unterhalb der Mindestzahl Fenster.

---

## 6. Checkliste je Änderung

- [ ] Neue Dateien in `project.pbxproj` eingetragen (vier Stellen, richtiges Target)
- [ ] Dienst in der passenden Assembly registriert
- [ ] `Screen.swift` und `SettingItems.swift` ergänzt, falls neuer Bildschirm
- [ ] UI-Texte englisch über `String(localized:comment:)`
- [ ] Glukosewerte intern in mg/dL
- [ ] Kein Schreiben von Therapie-Einstellungen ohne Bestätigung; Basal zuerst an die Pumpe
- [ ] Algorithmus-Code unverändert
- [ ] Tests geschrieben (Swift Testing) und in `TrioTests` eingetragen
- [ ] Im Bericht vermerkt: nicht gebaut, nicht getestet (kein Xcode auf diesem Rechner)

---

## 7. Stand der Umsetzung (Branch `feature/profiles-sport-tests`)

Umgesetzt wie in den Abschnitten 3–5 beschrieben, mit diesen Abweichungen und Lücken:

- **#21:** Zeitgesteuertes Umschalten, Shortcuts-Aktion, Anzeige des Profilnamens auf dem Home-Bildschirm, Aufnahme in den Einstellungs-Export und ein Nightscout-„Profile Switch" fehlen. Hochgeladen wird weiter das Profil `"default"`.
- **#13:** Erreichbar über eine Zeile oben im Adjustments-Bildschirm (kein eigener Tab). Die laufende Phase erscheint auf dem Home-Bildschirm als gewöhnlicher Override mit dem Namen „<Profil> – <Phase>"; Weiter / +15 min / Beenden liegen im Sport-Profile-Bildschirm. Jede Phase hat eine feste Dauer (höchstens 12 Stunden), es gibt keine offene Phase. Shortcuts, Watch und Mitteilungen beim Phasenwechsel fehlen. Der Phasenwechsel hängt an `DeterminationObserver`, nicht an `APSManager.loop()`.
- **#24:** Nur Stufe 1 (Basal, rückblickend über 14 Tage). Ergebnisse werden nicht gespeichert, sondern bei Bedarf neu berechnet. Als ISF dient der Profilwert, nicht der vom Algorithmus angepasste.

### Lokal prüfen ohne Mac

Die drei Logik-Dateien (`TherapyProfile.swift`, `SportProfile.swift`, `BasalTestEvaluator.swift`) hängen nur von Foundation ab und lassen sich unter Linux kompilieren. Ihre Tests liegen in `TrioTests/*LogicTests.swift` und `BasalTestEvaluatorTests.swift` und kommen ohne Simulator aus. Alles andere (Manager, Core Data, SwiftUI) braucht den Mac-Runner: `unit_tests.yml` hat dafür einen manuellen Start.
