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

## Cofanie smug gwiazd (`astralstack-untrail`)

Osobne narzędzie do gotowego zdjęcia ze smugami gwiazd (jedno długie naświetlanie albo stos z „lighten”),
gdy pojedynczych klatek już nie ma. Usuwa smugi i stawia każdą gwiazdę z powrotem w jednym punkcie jej łuku.

```sh
astralstack-untrail smugi.jpg                         # wynik: smugi_untrailed.jpg
astralstack-untrail smugi.jpg --at start --diag diag/ # gwiazdy z początku naświetlania + diagnostyka
astralstack-untrail smugi.tif --pole 2186 981 --fov 75 -o wynik.tif
```

Jak to działa:

1. **Geometria.** Wszystkie smugi to łuki wokół bieguna niebieskiego. Biegun, ogniskowa i punkt główny
   (zdjęcia bywają przycięte) są dopasowywane tak, by smugi leżały na liniach stałej odległości od bieguna ρ.
   Przy obiektywie prostoliniowym to stożkowe, a nie okręgi: na zdjęciu testowym (FOV ≈ 79°) model
   okręgów wyjaśniał trzy razy mniej. Ocena idzie po sektorach φ, żeby niezwiązane smugi o tym samym ρ
   nie zlewały się w jeden pierścień.
2. **Współrzędne bieguna.** Obraz jest przepróbkowany na siatkę (ρ, φ): każda smuga to poziomy odcinek,
   wszystkie tej samej długości kątowej (15°/h).
3. **Jądro.** Profil jasności wzdłuż φ jest wspólny dla wszystkich gwiazd (to oś czasu naświetlania,
   z przerwami między klatkami). Wyznacza się go z mediany wyrównanych, odosobnionych smug; długość
   wychodzi przy okazji (na zdjęciu z Wikipedii 15,06° = 1,00 h).
4. **Detekcja.** Filtr dopasowany z tym jądrem wzdłuż φ, a położenie doprecyzowane na pochodnej (końce
   smugi). Dwie smugi nakładające się przy prawie tym samym ρ dają jedną: słabsza gwiazda przepada,
   choć jej smuga i tak jest usuwana.
5. **Krajobraz.** Ciemna sylwetka połączona z ziemią (kierunek grawitacji z EXIF, jak w `astralstack`,
   albo `--ground`) nie jest przemalowywana, a smuga znikająca za drzewem nie „kończy się” na nim.
6. **Niebo pod smugami.** Tło z niskiego percentyla poprawione gładkim przesunięciem mierzonym na
   pikselach, które zostają, plus szum o tej samej sigmie. Wąskie pasy między gęstymi smugami są
   przemalowywane razem z nimi, bo zostają w nich tylko frędzle.
7. **Gwiazdy.** Gaussian o szerokości smugi (albo `--star-fwhm`), z jasnością szczytową i średnim kolorem
   smugi, w środku (`--at middle`, domyślnie), na początku albo na końcu naświetlania; przy dwóch ostatnich
   kierunek obrotu wynika z `--hemisphere`.

Dekonwolucja wzdłuż φ celowo nie jest używana. Jądro to kilkanaście stopni prawie prostokąta z zerami
w widmie, a smugi są przepalone i po JPEG-u, więc odwrotny filtr daje głównie dzwonienie.

`--diag` zapisuje `polar.png` (obraz w (ρ, φ)), `trail_mask.png`, `sky_mask.png`, `kernel.csv`,
`stars.csv` (x, y, RGB) i `geometry.txt`. Zdjęcie 3543×2361 liczy się ok. 1,5 min.

Ograniczenia: gwiazdy blisko bieguna (smuga krótsza niż kilka pikseli) zostają jak były; przy pełnych
okręgach (smugi ≥ 360°) nie ma końców, więc położenia nie da się odtworzyć; jasność przepalonych smug
jest nieznana, więc takie gwiazdy wychodzą podobnie jasne.

## Testy

```sh
pip install ".[test]"
python -m pytest
```

`tests/test_pipeline.py` generuje syntetyczną noc (`tests/synthetic.py`): obracające się niebo,
krajobraz z linią drzew i masztem, dystorsję beczkową, winietę, gorące piksele i satelitę w jednej
klatce. Sprawdza rejestrację, maskę względem prawdziwego horyzontu, ostrość gwiazd w stosie
i odrzucenie satelity.

`tests/test_untrail.py` renderuje zdjęcie ze smugami o znanej geometrii (obiektyw prostoliniowy, biegun
w kadrze, przerywany koniec smug, linia drzew) i sprawdza, że dopasowana geometria prostuje łuki, długość
jądra, powrót gwiazd na środek naświetlania i to, że po smugach nic nie zostaje.
