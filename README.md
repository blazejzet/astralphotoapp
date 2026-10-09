# AstralCamera

Aparat iOS do bardzo długich (efektywnych) naświetleń nieba z telefonu na statywie. iOS daje
aplikacjom firm trzecich najwyżej ~1 s na pojedynczą klatkę, więc AstralCamera robi serię klatek
Bayer RAW i składa je na bieżąco, korygując ruch pozorny gwiazd. Podstawy i źródła są opisane
w raporcie [reports/Astrofotografia iOS korekcja ruchu gwiazd.md](reports/Astrofotografia%20iOS%20korekcja%20ruchu%20gwiazd.md).

## Model: J = M · I

Zarejestrowana klatka k to `J_k = M_k · I + n_k`, gdzie `M_k = B_k · S_k`:

- `S_k` – przesunięcie nieba po sferze, czyli rotacja wokół osi świata z prędkością syderyczną
  ω = 7,2921150·10⁻⁵ rad/s. W pikselach odpowiada jej homografia
  `H(Δt) = K · R_p(−ωΔt) · K⁻¹` (`SkyRotationModel`).
- `B_k` – rozmycie wewnątrz klatki. Przy 1 s to ~0,1–0,4 px, więc praktycznie tożsamość.
  Pozostałą PSF stosu usuwa Richardson–Lucy na końcu.
- Pierwszy plan nie podlega `M` (`J = M·I_sky + I_ground`), dlatego aplikacja prowadzi dwa stosy.

Odwrócenie `M`: każda klatka jest próbkowana wstecz, `u_k = D(C_k · H(Δt_k) · D⁻¹(u))`
(`D` to dystorsja z LUT Apple), i scalana odpornie.

## Pipeline (na każdą klatkę)

1. **RAW → GPU**: odjęcie czerni i 2×2 super‑pixel (bez demozaikowania), filtr gorących pikseli, master dark.
2. **Model szumu** σ²(μ) = λ_s·μ + λ_r, liczony z różnicy kolejnych klatek (`NoiseModelEstimator`).
3. **Detekcja gwiazd** w stylu SExtractora: tło z siatki, próg kσ, centroidy (`StarDetector`).
4. **Wyrównanie** (`AlignmentEngine`):
   - przewidywanie pozycji z modelu fizycznego, dopasowanie najbliższego sąsiada z bramką,
     a awaryjnie trójkąty jak w astroalign (`TriangleMatcher`);
   - sztywna korekta `C_k` na drift (OIS, statyw, refrakcja);
   - co 10 klatek globalny fit osi bieguna metodą Levenberga–Marquardta z funkcją Hubera,
     z ω ustaloną i opcjonalnie skalą ogniskowej (`PoleFitter`). Czujniki (CoreMotion
     + szerokość geograficzna) dają tylko punkt startowy, bo kompas myli się o 5–10°.
5. **Scalanie na GPU**:
   - średnia ważona `w = clamp(s·exp(−z²/κ²) − t, 0, 1)` (Wronski 2019), seed z mediany 3 klatek,
     Welford dla wariancji; odrzuca satelity, samoloty i gorące piksele;
   - równolegle stos pierwszego planu, bez warpu;
   - co 30 klatek tymczasowa maska ziemi: próbki nieba, które „weszły” za horyzont, są pomijane.
6. **Finalizacja** (`Finisher`):
   - maska nieba z porównania var(stos nieba) z var(stos pierwszego planu); przy znanej grawitacji
     ziemia to wszystko poniżej linii horyzontu wyznaczonej w każdej kolumnie, więc ciemny, jednolity
     krajobraz pod linią drzew jest wypełniony, a nie tylko obrysowany;
   - maska decyduje tylko o tym, z którego stosu pochodzi piksel i które piksele liczą się do statystyk;
     wszystkie korekty (winieta, neutralizacja tła, gradient wielomianem 2. stopnia, balans bieli) idą
     identycznie na oba stosy, więc pomyłka maski na jednolitym obszarze jest niewidoczna; przy dryfie
     nieba < 2 px maska nie jest w ogóle stosowana;
   - PSF ze zmierzonych gwiazd i Richardson–Lucy z maską szumu;
   - balans bieli z gwiazd, neutralizacja przepalonych świateł (inaczej wzmocnienia kanałów robią z nich
     magentę) i jeden wspólny stretch asinh (Lupton 2004) dla całego kadru;
   - zapis JPEG do Zdjęć oraz 32‑bit liniowego TIFF, `mask.png` i `session.txt` do aplikacji Pliki
     (Na iPhonie → AstralCamera).

## Struktura

- `AstralCore/` – Swift Package z całą matematyką, testowalny na Macu.
  - `swift test` uruchamia 17 testów, w tym end‑to‑end na syntetycznym niebie z horyzontem i satelitą.
  - `CPUStacker` jest referencją dla shaderów.
- `AstralCamera/` – aplikacja SwiftUI:
  - `CameraController` – pętla Bayer RAW z ręcznym ISO i ostrością, tryb `.speed`, wyłączona korekcja dystorsji;
    obiektywy ultraszeroki, szeroki i teleobiektyw (tylko te, które ma dany iPhone; mnożnik zoomu liczony z pól widzenia);
  - `MotionProvider` – CoreMotion i lokalizacja;
  - `FrameProcessor` – przetwarzanie klatek;
  - `MetalStacker` + `Shaders.metal` – część GPU;
  - `SessionModel` i widoki z czerwonym nocnym UI.

## Uruchomienie

```sh
open AstralCamera.xcodeproj           # wybierz swój Team w Signing & Capabilities, zmień bundle ID
# testy rdzenia:
cd AstralCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release
```

Schemat uruchamia aplikację w konfiguracji **Release**. Pętle CPU w `-Onone` byłyby za wolne
na klatki co 1 s.

W terenie:

1. Postaw telefon na statywie.
2. Naciśnij **Auto** przy suwaku ostrości (ok. 1,5 min). Aplikacja przejdzie przez zakres `lensPosition`
   i wybierze pozycję z najjaśniejszymi szczytami gwiazd; wynik zapamiętuje osobno dla każdego obiektywu.
   Pozycja 1,0 to nie jest nieskończoność, a wartość ≈ 0,8 z iPhone'a 13 nie pasuje do 17 Pro.
3. Opcjonalnie zrób darki z zakrytym obiektywem.
4. Naciśnij Start, a po skończeniu „Zakończ i zapisz”.

## Języki

Interfejs jest po angielsku (język bazowy) z polskim tłumaczeniem w `AstralCamera/Localizable.xcstrings`
(opisy uprawnień w `InfoPlist.xcstrings`). Język aplikacji zmienia się w Ustawienia → AstralCamera → Język.
Logi sesji (`session.txt`) i nazwy plików są zawsze po angielsku. Strona produktu jest w `website/`.

## Do zweryfikowania na urządzeniu

Wynika to z raportu i nie da się tego sprawdzić bez iPhone'a:

- jaki jest rzeczywisty `maxExposureDuration` i ile trwają przerwy między klatkami RAW;
- konwencja `CMAttitude` i macierz osi urządzenie→kamera (`DeviceAxes.backCameraFromDevice`);
  dopasowanie bieguna z gwiazd koryguje błąd, a UI pokazuje „Kompas Δ”;
- czy `AVCameraCalibrationData` jest dostępne dla pojedynczej kamery przy RAW;
  jeśli nie, aplikacja liczy K z pola widzenia (FOV) i dopasowuje skalę ogniskowej;
- pixel format Bayer: obsługiwane są `14Bayer_*`, a inne formaty idą awaryjnie przez `CIRAWFilter`
  (wolniej, kodowanie DNG dla każdej klatki);
- termika i bateria w sesji powyżej 30 minut;
- porównanie z trybem nocnym Apple.
