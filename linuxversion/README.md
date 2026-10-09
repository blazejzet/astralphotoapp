# AstralStack – wersja na Linuksa

Offline'owa wersja pipeline'u AstralCamera: bierze folder krótkich naświetleń nieba zrobionych ze statywu
i składa je tak jak aplikacja na iPhonie – rejestruje niebo na jego obrocie, prowadzi osobny stos
pierwszego planu i łączy oba automatyczną maską nieba. Matematyka to port `AstralCore` na NumPy/SciPy
(nazwy modułów odpowiadają plikom Swift), bo `AstralCore` zależy od `simd`, `Accelerate` i `ImageIO`,
których na Linuksie nie ma.

## Instalacja

Python ≥ 3.9:

```sh
cd linuxversion
python3 -m venv .venv && . .venv/bin/activate
pip install ".[fits,fast]"        # fits = astropy (pliki FITS), fast = OpenCV (szybszy warp)
```

Albo w kontenerze:

```sh
docker build -t astralstack linuxversion
docker run --rm -v /ścieżka/do/klatek:/data astralstack /data
```

## Użycie

```sh
astralstack ~/noc/klatki                      # wynik w ~/noc/klatki/astral_<data>_<godzina>/
astralstack ~/noc/klatki -o wynik --darks ~/noc/darki
astralstack ~/noc/klatki --fov 72 --diag      # znane pole widzenia, zapis stosów diag_*
astralstack --help
```

Wejście: jeden folder z klatkami, a w nim pliki jednego rodzaju (przy RAW+JPEG wygrywa RAW):

- **RAW/DNG** (rawpy/LibRaw: DNG z iPhone'a, CR2/CR3, NEF, ARW, RAF, ORF, RW2…): odjęcie czerni,
  filtr gorących pikseli i 2×2 super‑pixel bez demozaikowania, jak kernel `binBayer`; sensory
  inne niż Bayer (X‑Trans) przechodzą przez demozaikowanie LibRaw i binning 2×2;
- **TIFF/PNG/JPEG**: 8‑bit traktowane jako sRGB i linearyzowane, 16‑bit/float jako liniowe (`--gamma`);
  powyżej 16 MP domyślnie binning 2×2 (`--bin`);
- **FITS** (z `astropy`): RGB albo mozaika z nagłówkiem `BAYERPAT`.

Kolejność klatek bierze się z czasu EXIF, a gdy go brak, z nazw plików. Klatki z innym czasem naświetlania
niż mediana (np. przypadkowe darki) są pomijane.

Wyjście (ten sam zestaw co w aplikacji):

| plik | zawartość |
|---|---|
| `astral.jpg` | gotowe zdjęcie, obrócone do pionu |
| `astral_linear.tif` | 32‑bit liniowy RGB po kalibracji, do Siril / PixInsight, obrócony do pionu |
| `mask.png` | maska nieba (biały = stos nieba), na siatce sensora z orientacją EXIF – jak w aplikacji |
| `session.txt` | log w formacie aplikacji (Frames, Sky drift, EXIF orientation…) |
| `diag_*.tif` | z `--diag`: surowe stosy dla narzędzi z `Tools/` (Refinish, MaskLab, Analyze) |

## Jak to działa

1. **Przebieg 1 (równolegle)**: każda klatka → luma → detekcja gwiazd (`StarDetector`), tło i szum;
   model szumu σ²(μ) = λ_s·μ + λ_r z kilku par kolejnych klatek.
2. **Rejestracja** na samych listach gwiazd. Aplikacja przewiduje ruch z czasu i bieguna
   (H(Δt) = K·R_p(−ωΔt)·K⁻¹ plus sztywna korekta dryfu). Offline nie ma czujników ani dokładnych
   znaczników czasu, ale model jest ten sam: dla nieruchomego aparatu każda klatka to czysty obrót 3‑D
   względem referencji, G_k = K·R_k·K⁻¹, a R_k zawiera i ruch nieba, i osiadanie statywu. R_k liczy się
   wprost z gwiazd (Kabsch, 3 parametry na klatkę) z przycinaniem odstających par. Dopasowanie
   bramkowane przewidywaniem z sąsiedniej klatki, awaryjnie trójkąty jak w astroalign (`TriangleMatcher`).
3. **Obiektyw**: ogniskowa z EXIF (ekwiwalent 35 mm albo mm + rozdzielczość płaszczyzny ogniskowej),
   z `--fov`/`--focal-px`/`--focal-mm`, a bez tego szukana na gwiazdach. Gdy niebo przesunie się
   o ≥ 10 px, ogniskowa (±25 % przy wartości z EXIF) i dystorsja radialna k1 (model podziałowy) są
   dopasowywane do gwiazd z klatek o największym ruchu i sekwencja jest rejestrowana ponownie.
   Aplikacja bierze dystorsję z LUT Apple, którego tu nie ma.
4. **Przebieg 2: stackowanie** od klatki referencyjnej (domyślnie środkowej – najmniejszy dryf do obu
   końców) na zewnątrz, dokładnie jak pętla w aplikacji: warp u_k = D(G_k·D⁻¹(u)), seed z mediany
   3 klatek, wagi Wronskiego w = clamp(s·exp(−z²/κ²) − t, 0, 1), Welford, nieważone statystyki do maski
   w oknie dryfu < 15 px, co 30 klatek tymczasowa maska okluzji.
5. **Finalizacja** (`Finisher`): maska nieba (linia horyzontu z kierunkiem grawitacji z orientacji EXIF),
   winieta, neutralizacja tła, gradient, PSF + Richardson–Lucy, balans bieli z gwiazd, neutralizacja
   przepaleń, stretch asinh.

### Różnice względem aplikacji

To, czego offline da się zrobić lepiej, bo wszystkie klatki są na dysku:

- **Statyczne detekcje** (gorące piksele, światła na ziemi), które stoją w tym samym miejscu sensora
  w ponad połowie klatek, nie biorą udziału w rejestracji. Bez tego sekwencja może „przykleić się” do
  sensora i wyjść z dryfem 0 px.
- **Smugi** (satelity, samoloty) o wydłużeniu > 2 są pomijane przy detekcji do rejestracji, inaczej
  wypełniają listę 150 najjaśniejszych źródeł i wypychają gwiazdy.
- **Średnia pierwszego planu jest odporna** (te same wagi, bez warpu). W aplikacji to zwykła średnia:
  satelita zostaje w niej ostry, a w odpornym stosie nieba go nie ma, więc maska brała go za krajobraz
  i wycinała prostokąt „ziemi” w niebie. Wariancja pierwszego planu, czyli dowód czasowy dla maski,
  zostaje nieważona.
- **RMS dopasowania** liczony jest po zbiorze po przycinaniu, nie po wszystkich parach w promieniu 12 px,
  więc kilka statycznych świateł nie odrzuca dobrej klatki.

Bez zmian: maska nieba, winieta, gradient, dekonwolucja, kolor i stretch. Na stosach `diag_*.tif`
z `tests/fourth` maska wychodzi identyczna co do piksela ze Swiftem, a obraz końcowy różni się średnio
o 0,01–0,02 poziomu 8‑bit (splot przez FFT zamiast vImage).

## Ograniczenia

- Statyw musi stać w miejscu: model to czysty obrót aparatu, więc przesunięcie (inna pozycja
  aparatu) nie jest modelowane.
- Dystorsja to jeden parametr radialny. Przy rybim oku i bardzo szerokim kącie resztki na brzegach
  mogą przekraczać 1 px; wtedy pomaga `--max-frames`, żeby skrócić sesję, albo wcześniejsza korekcja
  obiektywu (np. w darktable z lensfun) i eksport do 16‑bit TIFF.
- Gwiazdy wyraźnie poruszone w pojedynczej klatce (wydłużenie > 2) nie są używane do rejestracji;
  przy długich ogniskowych trzeba skrócić czas klatki.
- Brak flatów: spadek jasności na brzegach koryguje model winiety dopasowany do tła nieba.
- Kolor to surowe RGB kamery z balansem bieli z gwiazd (jak w aplikacji), bez macierzy kolorów aparatu.

## Testy

```sh
pip install ".[test]"
python -m pytest
```

`tests/test_pipeline.py` generuje syntetyczną noc (`tests/synthetic.py`): obracające się niebo,
krajobraz z linią drzew i masztem, dystorsję beczkową, winietę, gorące piksele i satelitę w jednej
klatce. Sprawdza rejestrację, maskę względem prawdziwego horyzontu, ostrość gwiazd w stosie
i odrzucenie satelity.
