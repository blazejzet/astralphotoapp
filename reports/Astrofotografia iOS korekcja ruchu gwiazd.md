# Sumuj sekundy, dopasuj biegun, odzyskaj niebo

Aplikację AstralCamera da się zbudować, ale nie w sposób, który podsuwa intuicja. iOS nie pozwala aplikacjom firm trzecich naświetlać pojedynczej klatki dłużej niż **około 1 s**, a Apple wprost potwierdza, że **nie ma wspieranego sposobu**, by odtworzyć 30-sekundowy tryb nocny aparatu systemowego ([Apple DTS, forum 769970](https://developer.apple.com/forums/thread/769970)). „Bardzo długie naświetlanie” musi więc powstać z setek lub tysięcy jednosekundowych klatek RAW, sumowanych na bieżąco z korekcją ruchu nieba. Matematyka tej korekcji jest prosta i dokładna: na statywie niebo to sztywna rotacja wokół osi bieguna z prędkością syderyczną **ω = 7,292115×10⁻⁵ rad/s** ([IERS](https://hpiers.obspm.fr/eop-pc/index.php?index=constants&lang=en)), a w pikselach odpowiada jej homografia **H(Δt) = K·R_p(−ωΔt)·K⁻¹** ([Szeliski, MSR-TR-2004-92](https://www.microsoft.com/en-us/research/wp-content/uploads/2004/10/tr-2004-92.pdf)). Operator M z modelu J = M·I rozpada się na deterministyczne przesunięcie między klatkami S_k i znikomy rozmaz wewnątrz klatki B_k. Przy 1 s i aparacie głównym 12 MP ślad gwiazdy ma tylko ok. **0,2 px**, więc ciężar problemu przesuwa się z dekonwolucji smug na trzy inne zadania: precyzyjne dopasowanie bieguna do gwiazd (kompas iPhone’a myli się o stopnie), odporne sumowanie strumieniowe z odrzucaniem satelitów i gorących pikseli przy ograniczonej pamięci oraz walkę z szumem odczytu, który przy tysiącach krótkich klatek kumuluje się N razy. Rekomendowany potok wygląda tak: Bayer RAW 12 MP z `.speed`, model czysto rotacyjny z biegunem estymowanym globalnie metodą Levenberga–Marquardta, dwa równoległe akumulatory (niebo warpowane, pierwszy plan niewarpowany), maska nieba z wariancji czasowej, a na końcu dekonwolucja **całego stosu** z PSF zmierzoną na gwiazdach, usunięcie gradientu i rozciągnięcie asinh. Żadna recenzowana praca z lat 2020–2026 nie opisuje kompletnego potoku tego typu na smartfonie. Poszczególne klocki są dobrze udokumentowane, ale ich połączenie (zwłaszcza rejestracja czysto rotacyjna z dopasowaniem bieguna) jest propozycją inżynierską, którą trzeba sprawdzić na urządzeniu.

*Legenda tagów weryfikacji (zachowana z notatek badawczych):* **[ZWERYFIKOWANE]** — treść przeczytana w źródle pierwotnym; **[METADANE]** — potwierdzone tylko dane bibliograficzne; **[PODRĘCZNIKOWE]** — standardowa wiedza, źródła nie pobrano w tej sesji; **[WYPROWADZENIE]** — własne wyprowadzenie badaczy, sprawdzone numerycznie skryptem NumPy (φ = 50°, f = 2796 px), bez recenzji; **[PROPOZYCJA]** — rozwiązanie inżynierskie bez walidacji w literaturze; **[DO SPRAWDZENIA NA URZĄDZENIU]** — konwencja Apple, której nie rozstrzyga żadne źródło pierwotne; **[FORUM DEV]**, **[PRODUCENT]**, **[PRASA]** — źródła wtórne o niższej wiarygodności; **[FRAGMENT]** — widziane wyłącznie we fragmencie wyniku wyszukiwania.

## Ruch nieba to jedna rotacja o znanej prędkości i dwóch nieznanych parametrach

### Prędkość syderyczna i oś bieguna w układzie lokalnym

Ziemia obraca się względem gwiazd z prędkością **Ω = 7,292 115 0(1)×10⁻⁵ rad/s**, a doba gwiazdowa trwa 86 164,0989 s ([IERS EOP-PC](https://hpiers.obspm.fr/eop-pc/index.php?index=constants&lang=en)). Daje to **15,04107″/s, czyli 15,041°/h**. Odwrotność 1/ω = 13 713 s to stała, która pojawia się w regule NPF. Różnica między dobą gwiazdową a syderyczną (≈10⁻⁷ względnie) nie ma znaczenia. W lokalnym układzie horyzontalnym cała sfera niebieska obraca się sztywno wokół stałego wektora bieguna. W układzie ENU jest to **p = (0, cos φ, sin φ)**, a w układzie NWU, który odpowiada ramce CoreMotion `xTrueNorthZVertical`, **p = (cos φ, 0, sin φ)**, gdzie φ to szerokość geograficzna. Kierunek gwiazdy ewoluuje jako

```
s(t) = R_p(−ω·(t − t₀)) · s(t₀)
R_p(θ) = I + sin θ·[p]ₓ + (1 − cos θ)·[p]ₓ²          (wzór Rodriguesa)
```

z ujemnym znakiem kąta, bo gwiazdy wschodzą na wschodzie i zachodzą na zachodzie. Wzór ten zgadza się z klasycznym rachunkiem kąta godzinnego z dokładnością 2×10⁻¹⁶ **[WYPROWADZENIE]**. Kluczowe uproszczenie dla stackowania brzmi tak: **ruch względny między klatkami zależy wyłącznie od p i Δt**. Czas absolutny (UT1, czas gwiazdowy) i długość geograficzna są potrzebne tylko do identyfikacji nazwanych gwiazd z katalogu, nie do wyrównania klatek **[WYPROWADZENIE]**. Jeśli jednak aplikacja ma liczyć czas gwiazdowy, notatki wskazują formułę ERA z IERS Conventions 2010, której w tej sesji nie sprawdzono w źródle pierwotnym.

### Od rotacji nieba do pikseli: H = K·R·K⁻¹

Na statywie orientacja telefonu jest stała, więc odwzorowanie między klatkami jest homografią sprzężonej rotacji. Szeliski podaje dla czystej rotacji H₁₀ = K₁R₁R₀⁻¹K₀⁻¹ i zauważa, że estymacja samej rotacji 3D jest „z natury stabilniejsza” niż pełnej 8-parametrowej homografii ([Szeliski, MSR-TR-2004-92](https://www.microsoft.com/en-us/research/wp-content/uploads/2004/10/tr-2004-92.pdf)). Dla AstralCamera cały łańcuch transformacji wygląda tak **[WYPROWADZENIE]**:

```
p_cam = C · A · p_ref                       (biegun w układzie kamery, wektor jednostkowy)
d₀    = K⁻¹ · u₀                            (promień obserwacji piksela u₀ = (x, y, 1)ᵀ)
d(t)  = R_{p_cam}(−ω·Δt) · d₀
H(Δt) = K · R_{p_cam}(−ω·Δt) · K⁻¹ = K · C · A · R_{p_ref}(−ω·Δt) · Aᵀ · Cᵀ · K⁻¹
```

A to orientacja urządzenia z CoreMotion, odwzorowująca ramkę odniesienia na ramkę urządzenia. C to stała permutacja osi urządzenie→kamera tylna. Wyprowadzona z definicji osi ARKit ([Apple: ARCamera.transform](https://developer.apple.com/documentation/arkit/arcamera/transform)) daje **C = [[0,−1,0],[−1,0,0],[0,0,−1]]** przy natywnej, poziomej orientacji bufora sensora. Jeśli `AVCaptureConnection` obraca lub odbija bufor, trzeba ją złożyć z tym obrotem **[DO SPRAWDZENIA NA URZĄDZENIU]**. Punkt stały H to obraz bieguna e = K·p_cam. Może leżeć daleko poza kadrem albo za kamerą (e₃ < 0, wtedy punktem stałym jest antybiegun). Ślady gwiazd są obrazami małych okręgów wokół p, czyli stożkowymi. Okręgami są tylko wtedy, gdy oś optyczna celuje w biegun.

Apple nie dokumentuje, czy `CMAttitude.rotationMatrix` to A (ramka odniesienia→urządzenie) czy Aᵀ. Opis mówi jedynie o „macierzy kosinusów kierunkowych” ([Apple: CMAttitude](https://developer.apple.com/documentation/coremotion/cmattitude), [rotationMatrix](https://developer.apple.com/documentation/coremotion/cmattitude/rotationmatrix)). Rozstrzyga to jednolinijkowy test grawitacji **[DO SPRAWDZENIA NA URZĄDZENIU]**. Jeśli `CMDeviceMotion.gravity` ≈ −(m13, m23, m33), macierz to A. Jeśli ≈ −(m31, m32, m33), macierz to Aᵀ. Ten sam problem odnotowuje PR w otwartoźródłowej aplikacji nieba: zła konwencja odbija wszystkie azymuty, a „rozstrzyga grawitacja” ([GitHub Twilight PR #108](https://github.com/bergeronK/Twilight/pull/108)) **[FRAGMENT]**. Ramka `xTrueNorthZVertical` wymaga magnetometru i usług lokalizacji, a przy nieskalibrowanym magnetometrze CoreMotion prosi o poruszanie urządzeniem ([Apple: xTrueNorthZVertical](https://developer.apple.com/documentation/coremotion/cmattitudereferenceframe/xtruenorthzvertical)).

### Model obrazu J = M·I w postaci dyskretnej

Pod-ekspozycja o długości τ rozpoczęta w chwili t_k jest całką prawdziwego nieba I (wyrażonego w epoce odniesienia t_ref) po trajektorii warpu, splecioną z PSF optyki **[WYPROWADZENIE]**:

```
J_k(u) = (1/τ) ∫_{t_k}^{t_k+τ} I( W_{t−t_ref}⁻¹(u) ) dt  ⊛ PSF_opt(u) + n_k(u)
W_Δt(u) = π( K · R_{p_cam}(−ω·Δt) · K⁻¹ · u ),    w surowych pikselach: W̃ = D ∘ W ∘ D⁻¹
J_k = M_k · I + n_k,    M_k = B_k · S_k
```

S_k to operator przepróbkowania (warp) dla Δt_k = t_k − t_ref, a B_k to przestrzennie zmienny rozmaz ruchowy wewnątrz klatki. B_k jest całką liniową wzdłuż lokalnego łuku o długości L(u) ≈ ω·τ·cos δ(u)·f_px, styczną do małego okręgu wokół bieguna. Estymator stosu to

```
Î = ( Σ_k S_kᵀ W_k J_k ) / ( Σ_k S_kᵀ W_k 1 )
```

czyli odwrotny warp i średnia ważona z maskami W_k. Ważne zastrzeżenie: pierwszy plan nie podlega M, bo ma tożsamościowy warp. Pełny model jest więc dwuwarstwowy, **J = M_sky·I_sky + I_ground**, i każdy krok korekcji ruchu wolno stosować wyłącznie w masce nieba **[WYPROWADZENIE]**.

### Intrinsics, dystorsja i realne ogniskowe w pikselach

K można pobierać per klatka z załącznika `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`. Trzeba wtedy włączyć `isCameraIntrinsicMatrixDeliveryEnabled` przed `startRunning()` ([Apple](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliveryenabled)). Drugie źródło to `AVCameraCalibrationData.intrinsicMatrix`, wyrażone w pikselach z początkiem w lewym górnym rogu i ważne tylko względem `intrinsicMatrixReferenceDimensions` ([Apple: intrinsicMatrix](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata/intrinsicmatrix)). Według nagłówka CoreMedia macierz w CFData jest zapisana kolumnowo. Dystorsję Apple opisuje **jednowymiarową tablicą powiększeń promienia** od `lensDistortionCenter` do narożnika, czyli modelem czysto radialnym ([Apple: lensDistortionLookupTable](https://developer.apple.com/documentation/avfoundation/avcameracalibrationdata/lensdistortionlookuptable)). Referencyjna implementacja z nagłówka SDK liczy r_max = √(max(cx, W−cx)² + max(cy, H−cy)²), interpoluje liniowo mag w indeksie r·(n−1)/r_max i zwraca c + (1 + mag)·(p − c). Do rektyfikacji służy tablica prosta, a do odwzorowania punktu zniekształconego na niezniekształcony tablica odwrotna. Jest tu istotna pułapka: dane kalibracyjne są dostarczane tylko przy **wyłączonej korekcji dystorsji geometrycznej (GDC)**, która domyślnie jest włączona ([Apple: isCameraCalibrationDataDeliverySupported](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/iscameracalibrationdatadeliverysupported), [isGeometricDistortionCorrectionEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isgeometricdistortioncorrectionenabled)). Model H = K·R·K⁻¹ obowiązuje wyłącznie we współrzędnych niezniekształconych, co dla silnie beczkowatego obiektywu ultraszerokokątnego ma kluczowe znaczenie. Awaryjnie f_px = (W/2)/tan(HFOV/2) z `videoFieldOfView` ([Apple](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/videofieldofview)).

Szacunkowe ogniskowe w pikselach dla iPhone 16 Pro, wyliczone z ekwiwalentów 35 mm ([Apple Support: specyfikacja](https://support.apple.com/en-us/121031)), oraz wynikające z nich tempo przesuwu gwiazd na równiku niebieskim **[WYPROWADZENIE]**:

| Aparat | Rozdzielczość | f_px (szac.) | Przesuw gwiazdy przy δ = 0 | Ślad przy τ = 1 s |
|---|---|---|---|---|
| 13 mm ultraszeroki | 4032×3024 | ≈ 1514 px | ≈ 0,11 px/s | ≈ 0,11 px |
| 24 mm główny | 4032×3024 | ≈ 2796 px | ≈ 0,20 px/s | ≈ 0,20 px |
| 24 mm główny | 8064×6048 | ≈ 5591 px | ≈ 0,41 px/s | ≈ 0,41 px |
| 120 mm tele | 4032×3024 | ≈ 13 978 px | ≈ 1,0 px/s | ≈ 1,0 px |

Wartości opierają się na marketingowo zaokrąglonych ekwiwalentach, a w aplikacji należy je zastąpić macierzą intrinsics. Poza osią optyczną przesuw w pikselach rośnie mniej więcej jak 1/cos²θ, więc dla obiektywu ultraszerokokątnego narożniki poruszają się wyraźnie szybciej niż środek.

### Reguła 500, NPF i dlaczego na iPhonie prawie przestają mieć znaczenie

Długość śladu w pikselach to **L_px(τ) = ω·τ·cos δ·f_px**, co sprawdzono numerycznie z dokładnością 0,01 px w sześciu kierunkach celowania **[WYPROWADZENIE]**. Reguła 500 wywodzi się z kręgu rozproszenia 0,029 mm z ery filmu (t ≈ 13713·0,029/(f·crop·cos δ)). Autor reguły NPF, Frédéric Michaud, podaje wersję prostą **t ≈ (35·N + 30·p_µm)/f_mm** i pełną **t ≈ k·(16,9·N + 13,7·p_µm + 0,1·f_mm)/(f_mm·cos δ)**, gdzie k = 1 oznacza gwiazdę okrągłą, a k = 2 lekki ślad. Zastrzega też, że uproszczonej wersji „4-crop” nie wolno stosować do małych sensorów smartfonów ([sahavre.fr: Les coulisses de la règle NPF](https://sahavre.fr/wp/les-coulisses-de-la-regle-npf/)). Dla aparatu głównego (f/1,78, przy założonym, nieopublikowanym przez Apple pikselu 1,22 µm i f ≈ 6,8 mm) pełna NPF daje **7,0 s przy k = 1 i 13,9 s przy k = 2**. Reguła 500 daje 20,8 s, czyli ślad 4,2 px przy 12 MP, a to za dużo na „punktowe” gwiazdy **[WYPROWADZENIE]**. Notatka geometryczna rekomendowała pod-ekspozycje 2–10 s. Notatka o ograniczeniach iOS pokazuje jednak, że **aplikacja firmy trzeciej nie dostanie więcej niż ~1 s** (sekcja o iOS niżej). Wewnątrzklatkowy ślad B_k wynosi więc ok. 0,2 px na aparacie głównym i ok. 1 px na tele, czyli poniżej typowej PSF optyki. NPF przestaje ograniczać projekt, a dekonwolucja smug staje się zadaniem marginalnym poza teleobiektywem.

### Rotacja pola dla nieruchomej kamery to ω·sin δ_c, nie wzór alt-az

Klasyczny wzór na rotację pola **ω_fr = ω·cos φ·cos A / cos h** dotyczy montażu alt-az, który śledzi cel i trzyma „górę” kadru w stronę zenitu ([RASC Calgary: Field Rotation](https://calgary.rasc.ca/field_rotation.htm)). Szczegółowa analiza jest w pracy Freya ([JDSO vol. 7 no. 4](http://www.jdso.org/volume7/number4/Frey_216_226.pdf)) **[METADANE]**. Telefon na statywie nie śledzi nieba. Dekompozycja polarna jakobianu H(t) w środku kadru pokazuje, że lokalny fragment pola **obraca się z prędkością ω·sin δ_c i przesuwa o ω·cos δ_c·f_px**, gdzie δ_c to deklinacja osi optycznej **[WYPROWADZENIE]**. Różnica jest duża. Przy celowaniu na południe na wysokości 30° (φ = 50°) rzeczywista rotacja wynosi 0,044°/min, podczas gdy wzór alt-az daje 0,186°/min. Przy celowaniu w biegun obraz obraca się wokół środka z prędkością 15°/h, więc punkt odległy o 2000 px od środka zakreśla w ciągu godziny łuk ≈ 520 px. Narożniki wychodzą wtedy poza pole, a obszar pełnego pokrycia stosu kurczy się, co trzeba uwzględnić przy kadrowaniu wyniku. Wniosek praktyczny: **nie należy przybliżać ruchu „rotacją wokół punktu w kadrze plus translacją”** w długich sekwencjach. Trzeba stosować pełną homografię 3×3, a dla obiektywu ultraszerokokątnego rotację na sferze **[WYPROWADZENIE]**. Migawka szczelinowa jest pomijalna: przy czasie odczytu rzędu 50 ms ([Horshack RollingShutter](https://github.com/horshack-dpreview/RollingShutter)) skos wynosi ≪ 0,1 px nawet na tele. Wystarczy znacznik czasu środka ekspozycji, zsynchronizowany z zegarem CoreMotion.

## Czujniki dają tylko punkt startowy, biegun trzeba dopasować do gwiazd

Kompas iPhone’a jest zbyt mało dokładny, by sam wyznaczył oś rotacji. `CLHeading.headingAccuracy` podaje maksymalne odchylenie w stopniach, a wartość ujemna oznacza brak kalibracji lub zakłócenia ([Apple: headingAccuracy](https://developer.apple.com/documentation/corelocation/clheading/headingaccuracy)). Badanie błędów kompasu w aplikacjach AR podaje typowe błędy 5–10°, a na iPhonie nawet 9–18° po kalibracji, która utrzymuje się krócej niż godzinę ([Open University ORO](https://oro.open.ac.uk/84729/1/84729AAM.pdf)) **[FRAGMENT, PDF niedostępny]**. Skutek: błąd 5° (0,087 rad) przy f_px = 2796 daje **≈1,1 px błędu przewidywanego przesunięcia na minutę sekwencji**, który narasta do **≈64 px po godzinie** **[WYPROWADZENIE]**. Pochylenie i przechył z grawitacji są znacznie dokładniejsze niż kurs, ale Apple nie publikuje liczb. Metalowe statywy w pobliżu magnetometru pogarszają sytuację. Dlatego model z czujników służy wyłącznie do **zainicjowania okna przeszukiwania** przy dopasowaniu gwiazd, nie do samego warpu.

Rekomendowana estymacja jest globalna i korzysta z tego, że prędkość kątowa jest znana. Niewiadome to kierunek bieguna p_cam (2 stopnie swobody na sferze S²) oraz opcjonalnie skala ogniskowej s, przesunięcie czasu t₀ i radialny współczynnik dystorsji k₁. Rozwiązuje się je metodą Levenberga–Marquardta z odporną funkcją straty (Huber/Cauchy), jednocześnie na wszystkich klatkach **[PROPOZYCJA]**:

```
r_ik = π( K · R_p(−ω·(t_k − t_ref)) · K⁻¹ · u_i,ref ) − u_i,k
min_{p∈S², s, t₀, k₁}  Σ_{i,k} ρ( ‖r_ik‖² )
```

Alternatywa bez więzów to problem Wahby: dla każdej pary klatek liczy się B = Σ wᵢ b′ᵢ bᵢᵀ = UΣVᵀ i R = U·diag(1, 1, det(UVᵀ))·Vᵀ, a potem oś jako wektor własny R dla wartości 1 i kąt θ = acos((tr R − 1)/2) ([Markley & Mortari, NASA NTRS](https://ntrs.nasa.gov/archive/nasa/casi.ntrs.nasa.gov/19990104598.pdf), [arXiv:1309.5679](https://arxiv.org/pdf/1309.5679)). Sprawdzian θ ≈ ω·Δt jest bezpłatnym detektorem błędu ogniskowej, bo zła ogniskowa skaluje promienie nieliniowo. Oś wyznaczona z krótkiej pary klatek jest jednak źle uwarunkowana (0,25° na minutę), dlatego trzeba używać najdłuższej dostępnej bazy albo dopasowania globalnego **[WYPROWADZENIE]**. Efekt uboczny jest cenny: p_cam w połączeniu z wektorem grawitacji wyznacza pełną orientację kamery względem NWU, łącznie z prawdziwą północą. Pozwala to rekalibrować kurs bez magnetometru i liczyć cos δ, a tym samym długość śladu, dla każdego piksela.

Sztywna rotacja nie pochłania refrakcji atmosferycznej. Według wzoru Bennetta R[′] = cot(h_a + 7,31/(h_a + 4,4)) refrakcja wynosi 9,9′ na wysokości 5°, 5,4′ na 10°, 2,7′ na 20° i 1,0′ na 45° ([Hellenica World, mirror](https://www.hellenicaworld.com/Science/Physics/en/AtmosphericRefraction.html), [Özlem 2016](https://astronomycenter.net/pdf/ozlem_2016.pdf)), co przy f_px = 2796 (1 px ≈ 1,23′) oznacza kilka pikseli zmiany w ciągu godziny dla zachodzącej gwiazdy i pionowe ściśnięcie pola przy horyzoncie **[WYPROWADZENIE]**. Do globalnej rotacji trzeba więc dołożyć małe residuum na klatkę: wielomian 2. rzędu albo resztkową homografię. Wchłania ono refrakcję, błąd modelu obiektywu i termiczny dryf ostrości. Wahania odsetka inlierów RANSAC posłużą zarazem do odrzucania klatek z chmurami. Notatki nie znalazły żadnej publikacji o dopasowaniu osi rotacji o nieznanym kierunku z gwiazd dla stackowania na smartfonie. Połączenie Wahby z więzem znanej prędkości jest nowe inżynieryjnie, a nie oparte na literaturze **[PROPOZYCJA]**.

## Rejestracja i stackowanie: astronomia dostarcza klocki, Google dostarcza wzorzec mobilny

### Detekcja i dopasowanie gwiazd

Standardem detekcji jest SExtractor (Bertin & Arnouts 1996) **[METADANE]**. Tło liczy się w siatce kafli z iteracyjnym obcinaniem histogramu do ±3σ wokół mediany i estymatorem **Mode = 2,5·Mediana − 1,5·Średnia**, z powrotem do mediany, gdy oba estymatory różnią się o ponad 30%. Na koniec stosuje się filtr medianowy siatki i interpolację bikubiczną. Zalecany rozmiar kafla to 32–512 px ([SExtractor docs](https://sextractor.readthedocs.io/en/latest/Background.html)) **[ZWERYFIKOWANE]**. Biblioteka SEP udostępnia te algorytmy w czystym C bez zależności spoza biblioteki standardowej ([Barbary 2016, JOSS](https://joss.theoj.org/papers/10.21105/joss.00058)), więc da się ją bezpośrednio skompilować na iOS. Astrometry.net proponuje prostszy estymator szumu: wariancję różnic kilku tysięcy losowych par pikseli odległych o 5 wierszy i 5 kolumn, równą ≈ 2σ² ([Lang i in. 2010](https://arxiv.org/abs/0910.2233)) **[ZWERYFIKOWANE]**. Do rejestracji wystarcza ważony centroid na tle odjętym i lekko wygładzonym filtrem Gaussa (FWHM 2–3 px). Dopasowanie PSF (Gauss/Moffat, jak w Siril, do 2000 gwiazd) ([Siril: Registration](https://siril.readthedocs.io/en/latest/preprocessing/registration.html)) opłaca się głównie przy metrykach jakości FWHM i okrągłości, służących do ważenia klatek **[PODRĘCZNIKOWE]**.

Do dopasowania między klatkami de facto standardem jest dopasowanie trójkątów (Groth 1986 → Valdes i in. 1995 → astroalign). Astroalign bierze 50 najjaśniejszych gwiazd, dla każdej 4 najbliższych sąsiadów, co daje C(5,3) = 10 trójkątów, i używa niezmiennika **M = (L2/L1, L1/L0)** odpornego na translację, rotację, skalę i odbicie. Trójkąty dopasowuje drzewem k-d z tolerancją 0,1, transformację weryfikuje w RANSAC, a działa już od trzech gwiazd. Autorzy zaznaczają, że SIFT, SURF i ORB „na ogół zawodzą” na polach gwiazd ([Beroiz i in. 2020, arXiv:1909.02946](https://arxiv.org/abs/1909.02946)) **[ZWERYFIKOWANE]**. Siril implementuje metodę Valdesa i używa **homografii jako domyślnego modelu dla szerokich pól** ([Siril docs](https://siril.readthedocs.io/en/latest/preprocessing/registration.html)). Haszowanie czwórek gwiazd z astrometry.net, z 99,9% skutecznością bez fałszywych dopasowań, służy ślepemu rozwiązywaniu względem katalogu, więc do wyrównania klatka-do-klatki jest przesadą ([Lang i in. 2010](https://arxiv.org/abs/0910.2233)). Model czysto rotacyjny K·R·K⁻¹ (2–3 stopnie swobody) jest logicznym kolejnym krokiem po podobieństwie z astroalign („źródła w nieskończoności”) i homografii z Siril. Przy małej liczbie gwiazd powinien być odporniejszy, ale nikt nie przetestował go na telefonach **[PROPOZYCJA]**.

### Google Night Sight, HDR+ i Wronski jako mobilny wzorzec scalania

Tryb astrofotografii Google (2019) to najbliższy opublikowany odpowiednik AstralCamera. Rejestruje **do 15 klatek po maks. 16 s** (łącznie ≤ 4 min na Pixel 4), bo dłuższe ekspozycje dają gwiazdy jako „krótkie odcinki”. Gorące piksele wykrywa przez porównanie z sąsiadami w klatce i w sekwencji, a niebo segmentuje siecią CNN uczoną na ponad 100 000 ręcznie oznaczonych zdjęć ([Kainz & Murthy, Google Research](https://research.google/blog/astrophotography-with-night-sight-on-pixel-phones/)) **[ZWERYFIKOWANE]**. Blog nie ujawnia, czy niebo rejestruje się po gwiazdach. Pod spodem działa HDR+ (Hasinoff i in. 2016) ([DOI](https://doi.org/10.1145/2980179.2980254)) **[METADANE]**, opisany szczegółowo w recenzowanej reimplementacji IPOL. Wyrównanie jest kafelkowe na 4-poziomowej piramidzie. Model szumu to **σ²(x) = λ_s·x + λ_r**, z parametrami z tagu DNG `NoiseProfile`. Scalanie odbywa się w dziedzinie Fouriera ([Monod, Delon & Veit 2021, IPOL](https://www.ipol.im/pub/art/2021/336/)) **[ZWERYFIKOWANE]**:

```
T̃₀(ω) = (1/N) Σ_z [ (1 − A_z(ω))·T_z(ω) + A_z(ω)·T₀(ω) ],    A_z = |D_z|² / (|D_z|² + c·σ²)
```

Autorzy IPOL zaznaczają, że wyrównanie jest „wrażliwe na szum”. Na kaflach czystego nieba (szum plus kilka punktów) działa więc słabo, co uzasadnia globalną transformację gwiazdową dla nieba. Liba i in. (2019) dodają przestrzennie zmienną „siłę czasową” z mapy niedopasowania m = d²/(d² + s·σ²) i sami przyznają, że niebo wymaga osobnego tonowania ([arXiv:1910.11336](https://arxiv.org/abs/1910.11336)) **[ZWERYFIKOWANE]**. Najważniejsza dla AstralCamera jest praca Wronskiego i in. (2019). Scala ona surowe klatki Bayera regresją jądrową z wagą odporności **R = s·exp(−d²/σ²) − t**, działa **strumieniowo z pamięcią niezależną od liczby klatek** i kosztuje 15,4 ms + 7,8 ms/MPix na klatkę na GPU Adreno 630 z 2018 r. ([arXiv:1905.03277](https://arxiv.org/abs/1905.03277)) **[ZWERYFIKOWANE]**. Przy tysiącach klatek to dokładnie ta własność, której potrzeba. Z nowszych prac „Lucky HDR” (2026) nie dotyczy astrofotografii ([arXiv:2604.19976](https://arxiv.org/abs/2604.19976)). Mimo celowanych wyszukiwań notatki nie znalazły **żadnej recenzowanej pracy z lat 2020–2026 o stackowaniu astro na smartfonie** (rejestracja gwiazd plus scalanie). To luka w literaturze, a nie brak praktyki.

### Odrzucanie odstających wartości przy ograniczonej pamięci

Siril oferuje drabinę estymatorów: clipping percentylowy dla ≤ 6 klatek, sigma/MAD/winsorized dla średnich stosów, liniowy fit dla dużych stosów z gradientami i GESD dla ponad 50 klatek. Mapy odrzuceń pokazują przy tym usuwanie śladów satelitów ([Siril: Stacking](https://siril.readthedocs.io/en/latest/preprocessing/stacking.html)) **[ZWERYFIKOWANE]**. Dokładne wersje wymagają całego stosu per piksel, a przy 3600 klatkach na godzinę to niewykonalne. Mediana ma przy tym efektywność tylko 2/π ≈ 0,64 względem średniej **[PODRĘCZNIKOWE]**. Pozostają trzy warianty. Pierwszy to jednoprzebiegowy clipping względem referencji: bieżąca średnia ważona plus algorytm Welforda, gdzie δ = x − μ, μ ← μ + δ/n, M2 ← M2 + δ(x − μ), a z-score liczy się z modelu szumu sensora **[PODRĘCZNIKOWE]**. Drugi to dwa przebiegi z ponownym odczytem klatek z dysku. Trzeci to dokładny clipping kafelkowy dla małych N. Model szumu σ²(x) = λ_s x + λ_r zamiast wariancji próbkowej sprawia, że odrzucanie działa już przy małym N, i tak właśnie postępuje HDR+ ([IPOL](https://doi.org/10.5201/ipol.2021.336)). Pierwsze 2–3 klatki są słabo chronione, dlatego referencję inicjuje się medianą kilku pierwszych klatek trzymanych w pamięci **[PROPOZYCJA]**.

### Drizzle i ślady satelitów

Drizzle (Fruchter & Hook 2002) rekonstruuje obraz na gęstszej siatce z niedopróbkowanych, przesuniętych klatek. Aktualizacje mają postać **W′ = a·w + W** oraz **I′ = (d·a·w·s² + I·W)/W′**. Metoda jest z natury strumieniowa („po każdej klatce jest użyteczny obraz i waga”), ale wprowadza korelację szumu sąsiednich pikseli ([arXiv:astro-ph/9808087](https://arxiv.org/abs/astro-ph/9808087)) **[ZWERYFIKOWANE]**. Pamięć rośnie z kwadratem skali ([Siril](https://siril.readthedocs.io/en/latest/preprocessing/registration.html)). Na iPhonie największą korzyścią jest **drizzle CFA (Bayera) przy skali 1**, który zastępuje demozaikowanie i poprawia kolor gwiazd. Rotacja nieba zapewnia przy tym darmowy dithering subpikselowy **[PROPOZYCJA]**. Ślady satelitów i samolotów zajmują dany piksel zwykle tylko w jednej klatce, więc przy dużym N usuwa je zwykłe odrzucanie per piksel. Dla małego N pomaga detekcja linii na obrazie różnicowym klatka − referencja: Hough, LSD albo U-Net + Hough w ASTA ([Stoppa i in. 2024, A&A 692, A199](https://doi.org/10.1051/0004-6361/202451663)) **[ZWERYFIKOWANE abstrakt]**. Najnowszy STARLINC (ECCV 2026 według arXiv) formalizuje tę samą ideę map różnicowych z sąsiednich ekspozycji ([arXiv:2608.29145](https://arxiv.org/abs/2608.29145)) **[ZWERYFIKOWANE abstrakt; konferencja niepotwierdzona]**. Detekcja śladów musi działać **po** rejestracji i w masce nieba, bo inaczej ruch gwiazd i niedopasowanie pierwszego planu generują fałszywe linie.

## Odwracanie J = M·I: dekonwolucja stosu, kalibracja, maska nieba i rozciąganie

### Znane jądro, ale prawie zerowe: dekonwolucja zmienia cel

Dla telefonu na statywie operator M jest **nieślepy**, bo wyznaczają go ω, τ, K i p_cam. Naturalnym solwerem jest Richardson–Lucy, czyli algorytm EM dla wiarygodności Poissona Σ[J log(MI) − MI], w postaci operatorowej ważnej dla dowolnego nieujemnego M:

```
Î^{t+1} = Î^t ⊙ Mᵀ( J ⊘ (M Î^t + b) ) ⊘ Mᵀ1
```

Wzór pochodzi z prac Richardsona 1972 ([DOI](https://doi.org/10.1364/JOSA.62.000055)) i Lucy’ego 1974 ([ADS](https://ui.adsabs.harvard.edu/abs/1974AJ.....79..745L)) **[PODRĘCZNIKOWE]**. Wczesne iteracje odtwarzają niskie częstości, a późne dopasowują szum i wywołują dzwonienie wokół jasnych gwiazd. Potrzebne jest więc wczesne zatrzymanie (10–50 iteracji), tłumienie (damped RL, White 1994) lub regularyzacja TV z λ ≈ 0,001–0,01 (Dey 2006). Przyspieszenie Biggsa–Andrewsa daje 2–5× **[PODRĘCZNIKOWE; równania z pamięci, do weryfikacji]**. Filtr Wienera, Î = F⁻¹{K*J/(|K|² + NSR)}, to jeden przebieg FFT, ale tylko dla PSF niezmiennej przestrzennie. Prostokątny ślad ruchu ma widmo sinc z zerami, co według teorii coded exposure czyni odwrócenie źle postawionym ([Raskar i in. 2006](https://doi.org/10.1145/1141911.1141957)) **[PODRĘCZNIKOWE]**. Dla przestrzennie zmiennego rozmazu rotacyjnego są dwie gotowe rodziny metod. Pierwsza to model sumy homografii Whyte’a i in., czyli g = Σ_θ w_θ·K_θ f z H_θ = K R_θ K⁻¹. Rozmaz od rotacji kamery parametryzuje się tam prędkością kątową ([Whyte i in. 2010](https://www.di.ens.fr/~josef/publications/whyte10.pdf), [IJCV 2012](https://link.springer.com/article/10.1007/s11263-011-0502-7)), a wariant z 2014 r. modeluje nasycenie wewnątrz RL ([ACM DL](https://dl.acm.org/doi/10.1007/s11263-014-0727-3)). Pokrewne są funkcje gęstości ruchu Gupty i in. ([ECCV 2010](https://link.springer.com/chapter/10.1007/978-3-642-15549-9_13)). Druga rodzina to Efficient Filter Flow, czyli PSF per nakładający się kafel z FFT ([Hirsch i in., CVPR 2010](https://is.mpg.de/publications/6335)). Najbliższy realny precedens to trackery gwiazd: Wang i in. (2018) budują trajektorię gwiazdy z prędkości kątowej z żyroskopu MEMS (x′ = x + y·ω_z·Δt + f·ω_y·Δt, y′ = y − x·ω_z·Δt − f·ω_x·Δt) i odtwarzają obraz metodą skalowanego rzutu gradientowego, ok. 3× szybszą od przyspieszonego RL ([Sensors 18(8):2662](https://pmc.ncbi.nlm.nih.gov/articles/PMC6111557/)) **[ZWERYFIKOWANE]**.

Ograniczenie iOS do 1 s rozstrzyga, jak to zastosować. Ponieważ B_k ≈ 0,2 px, analityczne jądro smugi jest prawie deltą. Efektywna PSF finalnego stosu to splot **P_eff = PSF_opt ⊛ B̄ ⊛ jitter rejestracji ⊛ jądro interpolacji**, w którym dominuje optyka i resztkowy błąd wyrównania, a nie smuga **[WYPROWADZENIE]**. Sensowna dekonwolucja działa więc na **całym stosie**: ma on to samo M co pojedyncza klatka, ale szum mniejszy o √N. Jądro najlepiej estymować empirycznie z izolowanych, nienasyconych gwiazd per kafel w stylu EFF („gwiazda jako PSF”). Analityczny model Whyte’a z kilkoma warpami K·R(ωt_j)·K⁻¹ ma sens tylko dla teleobiektywu albo przyszłych formatów z dłuższą ekspozycją. Pomysł zmiennych długości pod-ekspozycji, by zera widma wypadały w różnych miejscach (Agrawal i in. 2009) **[PODRĘCZNIKOWE, niezweryfikowane]**, przy śladach < 1 px ma niski priorytet. Ślepa dekonwolucja wieloklatkowa (OBD, Hirsch i in. 2011) przetwarza jedną klatkę naraz i koryguje nasycenie ([A&A 531, A9](https://www.aanda.org/articles/aa/pdf/2011/07/aa13955-09.pdf), [MPI](https://is.mpg.de/ei/publications/6793)). Jest potrzebna dopiero przy nieznanej trajektorii, np. drganiach od wiatru, a jej dokładne równania pozostają **niezweryfikowane** (PDF zwrócił 403).

Odszumianie uczone ma dwie podstawy. Noise2Noise pozwala trenować na parach niezależnych, zaszumionych obserwacji tej samej sceny ([arXiv:1803.04189](https://arxiv.org/abs/1803.04189)) **[METADANE]**, a wyrównane podstosy nieba, np. klatki parzyste i nieparzyste, są dokładnie takimi parami. ASTRO U-Net daje średni zysk SNR ×1,63, „równoważny stackowaniu co najmniej 3 obrazów”, i odzyskuje 95,9% gwiazd ([Vojtekova i in. 2021, MNRAS](https://ui.adsabs.harvard.edu/abs/2021MNRAS.503.3204V/abstract)) **[ZWERYFIKOWANE]**. Był jednak trenowany na HST i nie przeniesie się wprost na sensory Bayera w telefonach. ASTERIS (2026), transformer samonadzorowany na skorelowanym szumie kolejnych ekspozycji, zyskuje ok. 1 mag głębi ([arXiv:2602.17205](https://arxiv.org/abs/2602.17205)) **[ZWERYFIKOWANE arXiv; publikacja w Science niepotwierdzona]**. Koncepcyjnie jest najbliższy „wielu klatkom z telefonu”, ale jego wykonalność na urządzeniu jest nieznana.

### Kalibracja: gorące piksele bez darków, bo niebo samo dithuje

Klasyczna redukcja to **calibrated = (light − master_dark) / master_flat**, z biasem zawartym w darku o tej samej ekspozycji, ISO i temperaturze **[PODRĘCZNIKOWE]**. Prąd ciemny rośnie liniowo z czasem i wykładniczo z temperaturą, podwajając się co ~6–10 °C zależnie od procesu ([US 7,787,033](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/7787033)) **[FRAGMENT]**. iOS nie udostępnia publicznego API temperatury sensora, a jedynie zgrubny `ProcessInfo.thermalState`. Google pokazuje, że da się obejść bez darków, wykrywając gorące piksele przez porównanie sąsiadów w klatce i w sekwencji, a następnie ukrywając je interpolacją ([Kainz & Murthy](https://research.google/blog/astrophotography-with-night-sight-on-pixel-phones/)). Rotacja nieba daje przy tym darmowy dithering: po wyrównaniu nieba nieruchome gorące piksele zamieniają się w ruchome smugi i są odrzucane statystycznie. Nie dotyczy to pierwszego planu, którego stos jest niewarpowany i gdzie gorące piksele trzeba usunąć mapą **[PROPOZYCJA]**. Bias na telefonie to poziom czerni z tagów DNG BlackLevel. Winietowanie w Bayer RAW nie jest skorygowane, więc flaty z opkodów DNG albo jednorazowy pomiar na urządzenie są **konieczne przed usunięciem gradientu**, bo inaczej winieta zostanie odczytana jako łuna **[PODRĘCZNIKOWE]**. Roger Clark argumentuje, że nowoczesne sensory z tłumieniem prądu ciemnego czynią darki mniej potrzebnymi, a ich odejmowanie dodaje szumu ([Clarkvision](https://clarkvision.com/articles/dark-current-suppression-technology/)) **[opinia praktyka, treść niepobrana]**.

### Maska nieba: Apple jej nie da, więc fizyka stosu musi

Warpowany stos rozmywa krajobraz, a niewarpowany zostawia smugi gwiazd. Rozwiązaniem jest maska nieba i dwa osobne stosy. Apple ma `CIRAWFilter.semanticSegmentationSkyMatte` ([Apple](https://developer.apple.com/documentation/coreimage/cirawfilter/semanticsegmentationskymatte)), ale przez AVCapture typy matów to tylko włosy, skóra, zęby i okulary. Na forum deweloperów usłyszano, że matu nieba „nie da się uzyskać bez prywatnych bibliotek”, a inżynier Apple nie odpowiedział ([forum 735020](https://developer.apple.com/forums/thread/735020)) **[FORUM DEV]**. Aplikacja potrzebuje więc własnego segmentera Core ML albo heurystyki z danych. Tę drugą daje fizyka stosu **[PROPOZYCJA]**: w stosie niewarpowanym piksele nieba fluktuują w czasie, bo przechodzą przez nie gwiazdy, a w stosie warpowanym fluktuuje pierwszy plan. Klasyfikator **sky(x) = [var_warped(x) < var_unwarped(x)]**, wygładzony filtrem prowadzonym i zamieniony na linię horyzontu (najniższy piksel nieba w kolumnie), działa bez sieci neuronowej. Zawodzi na bezgwiezdnych fragmentach nieba, np. pod chmurami, gdzie trzeba go połączyć z priorytetem jasności lub CNN. Mieszanie to final = α·sky_warped + (1 − α)·fg_unwarped z rozmytym α. Dekonwolucja, odszumianie nieba i rozciąganie działają tylko tam, gdzie α > 0.

### Gradient i rozciąganie asinh

GraXpert dopasowuje do próbek tła RBF, splajny lub kriging i ma też model AI ([GitHub](https://github.com/Steffenhir/GraXpert/)), ale nie ma recenzowanej publikacji. Na urządzeniu wystarczy prostsza procedura. Usuwa się gwiazdy, liczy medianę z clippingiem w siatce 16×12, odrzuca kafle z Drogą Mleczną i dopasowuje wielomian 2.–3. stopnia per kanał, wyłącznie w masce nieba. Zbyt agresywne dopasowanie usunie Drogę Mleczną, bo ona też jest strukturą wielkoskalową **[PROPOZYCJA]**. Rozciąganie wyświetlania to asinh Luptona i in. (2004), F(x) = arcsinh(x/β), stosowane do wspólnej jasności I = (R+G+B)/3 i skalujące wszystkie kanały tym samym czynnikiem, co zachowuje kolor gwiazd ([PASP 116:133](https://iopscience.iop.org/article/10.1086/382245), [arXiv:astro-ph/0312483](https://arxiv.org/abs/astro-ph/0312483)) **[ZWERYFIKOWANE]**. Kolejność jest nienegocjowalna: kalibracja → stos → dekonwolucja → gradient → balans bieli → asinh. Dekonwolucja i dopasowanie tła mają sens tylko w danych liniowych.

## iOS tnie pojedynczą klatkę do sekundy, więc AstralCamera musi sumować tysiące

### Twarde limity ekspozycji i ścieżki przechwytywania

`exposureDuration` musi leżeć w zakresie `minExposureDuration`–`maxExposureDuration` aktywnego formatu i ustawia się go tylko przez `setExposureModeCustom` ([Apple](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration)). Halide podaje, że najnowsze iPhone’y mają sprzętowy limit **1 s**, a starsze 1/2 lub 1/3 s ([Lux Optics support](https://luxoptics.zendesk.com/hc/en-us/articles/360000998412-Why-is-the-maximum-shutter-speed-limited-to-one-second)) **[PRODUCENT, FRAGMENT]**, co potwierdza Cocologics ([pomoc LowLight Plus](https://cocologicshelp.zendesk.com/hc/en-us/articles/360012889357-How-can-I-set-exposure-to-more-than-1-second-LowLight-Plus)) **[PRODUCENT, FRAGMENT]**. Żadne źródło nie wskazuje formatu z lat 2024–2026 przekraczającego 1,0 s. Kluczowa i łatwa do przeoczenia jest dokumentacja: przy domyślnym `photoQualityPrioritization = .balanced` system **może po cichu nadpisać ręczny czas i ISO fuzją wielu klatek**, a jedynym sposobem, by to wymusić, jest `.speed` ([Apple: setExposureModeCustom](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))). Każda zmiana ekspozycji, ISO czy ostrości kosztuje 2–3 okresy klatki, bo handler wraca po ~3× czasu ekspozycji na iPhonie 14 Pro ([forum 751112](https://developer.apple.com/forums/thread/751112)) **[FORUM DEV]**. Przykładowy format iPhone’a 15 Pro ma ISO 55–12 320 ([VisionCamera #2640](https://github.com/margelo/react-native-vision-camera/issues/2640)) **[FORUM DEV]**.

Są dwie ścieżki przechwytywania. **Bayer RAW przez `AVCapturePhotoOutput`** to pojedyncze, nieprzetworzone ujęcie DNG bez fuzji. **ProRAW nie nadaje się**, bo powstaje „z wielu zdemozaikowanych ekspozycji z fuzją obrazu” ([WWDC21 10160](https://developer.apple.com/videos/play/wwdc2021/10160/)). Tryb 48 MP działa tylko przy `.balanced`/`.quality` ([WWDC26 304](https://developer.apple.com/videos/play/wwdc2026/304/)), co koliduje z wymogiem `.speed`, więc pod-klatki muszą mieć 12 MP. Druga ścieżka, `AVCaptureVideoDataOutput`, daje ciągły strumień i intrinsics per klatka, ale klatki przechodzą przez ISP (temporalne odszumianie, tonowanie), co psuje liniowość stosu. ProRes RAW (`AVVideoCodecType.proResRAW`, iOS 26; iPhone 17 Pro+ „z API dla deweloperów”) ([Apple](https://developer.apple.com/documentation/avfoundation/avvideocodectype/proresraw), [Newsroom iPhone 17 Pro](https://www.apple.com/newsroom/2025/09/apple-unveils-iphone-17-pro-and-iphone-17-pro-max/)) mógłby stać się najlepszym ciągłym źródłem surowych danych. Nikt jednak nie potwierdził, że pozwala na czasy klatki ≥ 1/2 s.

### Ostrość, stabilizacja, czujniki, pamięć i termika

`lensPosition` = 1,0 **nie oznacza nieskończoności** ([Apple: lensPosition](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lensposition)). Deweloper zmierzył optimum ≈ 0,808 dla obiektywu szerokiego i tele oraz ≈ 0,84 dla ultraszerokiego, dryfujące w czasie, prawdopodobnie z temperaturą ([forum 706755](https://developer.apple.com/forums/thread/706755)) **[FORUM DEV]**. Ostrość trzeba więc ustawiać skanem FWHM na jasnej gwieździe i okresowo sprawdzać. Należy wyłączyć stabilizację obiektywu (`isLensStabilizationEnabled`), stabilizację wideo i GDC, zablokować balans bieli i używać konkretnego fizycznego `builtInWideAngleCamera` zamiast urządzenia wirtualnego, które może przełączać obiektywy. Czy OIS „pływa” na statywie mimo wyłączenia, nie zweryfikowano. Żyroskop z usuniętym biasem, `CMDeviceMotion.rotationRate` ([Apple](https://developer.apple.com/documentation/coremotion/cmdevicemotion/rotationrate)) jest właściwym sygnałem wykrywania statywu i odrzucania klatek z dotknięciem lub wiatrem. Akumulator 12 MP RGBA float32 zajmuje ≈ 192 MB, a 48 MP ≈ 768 MB. Limity pamięci sprawdza się przez `os_proc_available_memory()` i `MTLDevice.recommendedMaxWorkingSetSize`, a uprawnienie `increased-memory-limit` działa tylko na niektórych modelach ([Apple](https://developer.apple.com/documentation/os/os_proc_available_memory), [Apple](https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize)). Przechwytywanie nie działa w tle, więc ekran musi pozostać włączony (`isIdleTimerDisabled`). Dopiero końcowe przetwarzanie może dokończyć `BGContinuedProcessingTask` z iOS 26 ([Apple](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)). Przy `.critical` stanie termicznym Apple zaleca zaprzestać używania kamery ([Apple](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/critical)). iPhone 18 Pro ma przysłonę zmienną f/1,48–f/4 z API dla deweloperów ([Apple Newsroom](https://www.apple.com/newsroom/2026/09/apple-debuts-iphone-18-pro-and-iphone-18-pro-max/)). Nazwy tego API nie zweryfikowano.

### Istniejące aplikacje syntetyzują długi czas z krótkich klatek

| Aplikacja | Jak uzyskuje „długi czas” | Ograniczenie istotne dla AstralCamera |
|---|---|---|
| Apple Camera (Night mode) | Prywatna fuzja wielu klatek, 1–30 s na statywie, wykrywanie statywu żyroskopem ([Apple Support](https://support.apple.com/en-us/102519), [MacRumors](https://www.macrumors.com/guide/night-mode/)) **[PRASA]** | Niedostępna dla firm trzecich ([DTS](https://developer.apple.com/forums/thread/769970)); wynik 12 MP |
| NightCap | Tryb Stars 10 s, „ISO Boost” do 4×, ślady gwiazd przez łączenie klatek w czasie rzeczywistym, meteory co 5 s ([NightCap](https://www.nightcapcamera.com/photograph-stars-meteors-satellites-even-nebulas-iphone-nightcap-camera/), [App Store](https://apps.apple.com/us/app/nightcap-camera/id754105884)) **[PRODUCENT]** | Brak publicznego opisu wyrównania; wyjście TIFF z przetworzonych klatek (wg recenzji) |
| Spectre (Lux) | „Setki klatek w czasie ekspozycji”, AI-stabilizacja, do 9 s z ręki ([DPReview](https://www.dpreview.com/news/5372004032/halide-s-spectre-is-an-ai-powered-long-exposure-app-for-the-iphone)) **[PRASA]** | Cel artystyczny (Live Photo), nie astro |
| Halide | Maks. 1 s, Process Zero = pojedynczy RAW, bez trybu nocnego ([Lux](https://www.lux.camera/introducing-process-zero-for-iphone/)) **[PRODUCENT]** | Brak stackowania astro |
| ProCamera | Bracketing RAW ([ProCamera](https://procamera-app.com/en/blog/raw-exposure-bracketing-in-procamera/)) **[PRODUCENT]** | Brak korekcji ruchu nieba |

Najważniejsza przestroga pochodzi od dewelopera, który zestackował 30 klatek RAW po 1 s i uznał wynik za **„znacznie gorszy”** od 30-sekundowego trybu nocnego Apple ([forum 769970](https://developer.apple.com/forums/thread/769970)). Przyczyna jest fizyczna. Przy sygnale S, tle nieba B i prądzie ciemnym D (e⁻/s) oraz szumie odczytu σ_r stos N klatek po τ sekund ma **SNR_N = N·S·τ / √(N·[(S + B + D)·τ + σ_r²])**. Szum odczytu płaci się N razy, więc przy τ = 1 s i ciemnym niebie składnik σ_r² może dominować **[PODRĘCZNIKOWE]**. Przewaga Apple to dostrojona fuzja i odszumianie, a nie ukryta długa ekspozycja, choć wewnętrzne czasy klatek Apple są nieznane. Wyróżniki AstralCamera wobec konkurencji to liniowe pod-klatki RAW, rejestracja świadoma rotacji syderycznej z dopasowaniem bieguna (minuty do godzin integracji bez smug), odrzucanie satelitów i wyjście liniowe DNG/TIFF.

## Rekomendowany potok AstralCamera krok po kroku

Decyzje projektowe wynikają bezpośrednio z powyższych ograniczeń. Tabela zbiera je z uzasadnieniem, a kroki poniżej podają równania.

| Decyzja | Wybór | Uzasadnienie |
|---|---|---|
| Długość pod-ekspozycji | `activeFormat.maxExposureDuration` (≈ 1 s), stałe ISO przez całą sesję | Limit iOS; ślad 0,1–0,4 px ≪ PSF; każda zmiana parametrów traci 2–3 klatki |
| Ścieżka przechwytywania | Bayer RAW 12 MP, `.speed`, pętla pojedynczych ujęć z prealokowanymi ustawieniami; wideo tylko jako awaryjny podgląd | Dane liniowe bez fuzji ISP; 48 MP wymaga `.balanced`, ProRAW jest fuzją |
| Kamera | Fizyczna szeroka (główna) domyślnie, ultraszeroka dla Drogi Mlecznej; OIS, stabilizacja i GDC wyłączone | Największa apertura; spójność z LUT dystorsji i modelem K·R·K⁻¹ |
| Model ruchu | Czysta rotacja K·R_p(−ωΔt)·K⁻¹ z globalnie dopasowanym p_cam (+ s, k₁) i małym residuum na klatkę | 2–4 parametry zamiast 8; znane ω to silny więz; czujniki tylko inicjalizują |
| Scalanie | Strumieniowa średnia ważona z wagą odporności względem modelu szumu, float32 | Pamięć O(1) w N; tysiące klatek nie zmieszczą się w RAM |
| Niebo / pierwszy plan | Dwa równoległe akumulatory (warpowany i niewarpowany) + maska z wariancji czasowej | Brak publicznego matu nieba; fizyka stosu daje sygnał |
| Dekonwolucja | Na końcowym stosie nieba, PSF z gwiazd per kafel, tłumiony RL | SNR √N lepszy niż per klatka; smuga 1 s jest pomijalna |
| Wyjście | Liniowy DNG/TIFF + rozciągnięty HEIF/JPEG | Dalsza obróbka w Siril/PixInsight |

### Krok 0 — konfiguracja sesji

Aplikacja wybiera fizyczny `builtInWideAngleCamera` i format z największym `maxExposureDuration` przy 12 MP Bayer RAW. Ustawia `setExposureModeCustom(duration: max, iso: ISO*)` i `photoQualityPrioritization = .speed`, wyłącza GDC, OIS i stabilizację oraz blokuje balans bieli. Przy iPhonie 18 Pro dodatkowo otwiera przysłonę do f/1,48. Ostrość ustawia skan `lensPosition` wokół 0,8, minimalizujący FWHM jasnej gwiazdy. ISO* to wartość minimalizująca stosunek σ_r² do sygnału tła przy 1 s. Wyznacza się ją z λ_s i λ_r odczytanych z DNG `NoiseProfile` dla kilku ISO, co jest zadaniem pomiarowym, a nie wartością z literatury **[DO SPRAWDZENIA NA URZĄDZENIU]**. Interfejs działa w trybie czerwone-na-czarnym przy `isIdleTimerDisabled = true`. Statyw wykrywa się progiem |rotationRate| w oknie czasowym.

### Krok 1 — priorytety geometryczne

Ze startowego `CMDeviceMotion` w ramce `xTrueNorthZVertical` i z `CLLocation` aplikacja liczy p_ref = (cos φ, 0, sin φ), rozstrzyga testem grawitacji konwencję A/Aᵀ i wyznacza p_cam⁰ = C·A·p_ref. K pobiera z intrinsics (przeskalowanych do rozmiaru bufora) albo, awaryjnie, z f_px = (W/2)/tan(HFOV/2). LUT dystorsji pobiera z `AVCameraCalibrationData`, jeśli jest dostępny dla pojedynczej kamery, a w przeciwnym razie k₁ dopasowuje się w kroku 4. Niepewność kursu z `headingAccuracy` wyznacza promień bramkowania przy dopasowaniu gwiazd.

### Krok 2 — wstępna obróbka klatki k (GPU)

Z czasu prezentacji klatki liczy się t_k (środek ekspozycji). Następnie odejmuje się poziom czerni, dzieli przez flat (opkody DNG lub kalibracja urządzenia) i maskuje gorące piksele mapą z kroku 7. Do detekcji powstaje luminancja o połowie rozdzielczości z kwadratów Bayera 2×2, jak u Wronskiego.

### Krok 3 — detekcja i centroidy

Na luminancji, w poprzedniej masce nieba, liczy się tło i mapę σ metodą siatki SExtractor (kafel ~64 px, Mode = 2,5·med − 1,5·mean), a potem splot z Gaussem o FWHM ≈ 2–3 px, próg 3–5σ, maksima lokalne i minimalną powierzchnię kilku pikseli. Centroid jest ważony: x̄ = Σ(I − B)x / Σ(I − B). Zostaje ~50–200 najjaśniejszych gwiazd. Każdą rektyfikuje się przez LUT i zamienia na promień **b = normalize(K⁻¹u)**.

### Krok 4 — dopasowanie i estymacja bieguna

Pozycje gwiazd z referencji przewiduje się do chwili t_k przez H(t_k − t_ref) z aktualnym p_cam i paruje z detekcjami w promieniu bramkowania. Jeśli parowanie się nie uda (początek sesji, duża niepewność kursu), awaryjnie stosuje się trójkąty astroalign + RANSAC. Co ~10–30 klatek, a zawsze przy najdłuższej dostępnej bazie, aktualizuje się globalne dopasowanie LM:

```
min_{p∈S², s, k₁, t₀}  Σ_{i,k} ρ( ‖ π(K_s · R_p(−ω(t_k − t_ref)) · K_s⁻¹ · u_i,ref) − u_i,k ‖² )
```

Na koniec dopasowuje się residuum na klatkę (wielomian 2. rzędu albo mała homografia) dla refrakcji i dryfu ostrości. Klatki z niskim odsetkiem inlierów (chmury, samolot, wstrząs) są odrzucane **[PROPOZYCJA]**.

### Krok 5 — warp i scalanie strumieniowe nieba

Każdy piksel wyjściowy na siatce epoki t_ref jest mapowany odwrotnie, u_k = D(W_{t_k−t_ref}(D⁻¹(u))), i próbkowany per kanał CFA. Najprościej robi to „drizzle CFA” w postaci gather z jądrem Gaussa po próbkach tego samego koloru, co zastępuje demozaikowanie. Waga odporności względem bieżącej referencji μ ma postać wzorowaną na Wronskim:

```
σ²_pred(x) = λ_s·μ(x) + λ_r
z = (x_k − μ) / σ_pred
w_rob = clamp( s·exp(−z²/κ²) − t, 0, 1 )
w_k = w_rob · w_frame,k                     (w_frame ∝ 1/σ²_bg,k · f(FWHM_k))
A ← A + w_k·x_k,   W ← W + w_k,   μ = A/W;   Welford: M2 dla wariancji
```

Akumulatory są dwa, parzysty i nieparzysty (A_e/W_e, A_o/W_o). Kosztują 2× pamięć, ale dają mapę szumu z różnicy (A_e/W_e − A_o/W_o) i pary do samonadzorowanego odszumiania w stylu Noise2Noise. Referencję μ inicjuje mediana pierwszych 3–5 klatek trzymanych w RAM. Przy 12 MP i float32 każda płaszczyzna zajmuje ≈ 48 MB, więc zestaw sumy, wagi i M2 dla dwóch połówek plus akumulator pierwszego planu mieści się w ~400–500 MB, choć trzeba to zmierzyć `os_proc_available_memory` **[PROPOZYCJA]**. Płaszczyzna W pełni też rolę mapy pokrycia: końcowe kadrowanie obejmuje obszar, w którym W ≥ ułamek maksimum, co uwzględnia rotację narożników.

### Krok 6 — satelity i samoloty

Dla klatki k liczy się Δ = x_k − μ w masce nieba, progowo przy k·σ_pred. Przez pierwsze ~10–20 klatek, gdy statystyka jest słaba, na obrazie binarnym uruchamia się Hough albo LSD. Wykrytą linię poszerza się o kilka pikseli i zeruje tam w_k. Przy dużym N waga odporności z kroku 5 wystarcza sama.

### Krok 7 — akumulator pierwszego planu, mapa gorących pikseli i maska nieba

Równolegle aplikacja sumuje klatki **bez warpu**: U ← U + x_k, z wariancją Welforda na luminancji o połowie rozdzielczości. Mapę gorących pikseli daje warunek U(x) − median_{ten sam kolor}(U)(x) > 5·σ_U, który oddziela pojedyncze piksele od rozciągłych świateł krajobrazu i jest aktualizowany co kilkadziesiąt klatek. Opcjonalnie na końcu można wykonać 10–20 darków z zakrytym obiektywem **[PROPOZYCJA]**. Maska nieba to α(x) = smooth(var_warped < var_unwarped), regularyzowana linią horyzontu. Opcjonalnie łączy się ją z małym segmenterem Core ML trenowanym na zbiorach typu ADE20K „sky”.

### Krok 8 — podgląd na żywo

Po każdej klatce aplikacja wyświetla α·asinh(μ_sky/β) + (1 − α)·asinh(U/N/β) w niskiej rozdzielczości. Budżet na klatkę to detekcja (dziesiątki ms), dopasowanie (≈ 1 ms) i warp ze scalaniem. Ekstrapolacja z 7,8 ms/MPix na Adreno 630 daje ~100 ms przy 12 MP, czyli mniej niż 1 s ekspozycji. Pomiaru na Metal nie wykonano **[DO SPRAWDZENIA NA URZĄDZENIU]**.

### Krok 9 — przetwarzanie końcowe (liniowe)

Krok zaczyna się od złożenia Î_sky = (A_e + A_o)/(W_e + W_o) i Î_fg = U/N. Następnie aplikacja szacuje PSF per kafel EFF (np. 8×6 z 50% nakładką) z uśrednionych, izolowanych, nienasyconych gwiazd Î_sky. Dekonwolucja nieba to tłumiony RL przez 10–30 iteracji, z tłem b, zamaskowanymi nasyconymi rdzeniami i wyłącznie w α > 0:

```
Î^{t+1} = Î^t ⊙ Σ_r C_rᵀ[ w_r ⊙ ( ã_r ⊛ ( J ⊘ (a_r ⊛ Î^t + b) ) ) ] ⊘ Mᵀ1
```

Dla teleobiektywu jądro a_r można złożyć z PSF gwiazdy i analitycznego łuku (1/N_s)·Σ_j warp(K·R_p(ωτ·j/N_s)·K⁻¹). Potem usuwa się gradient: siatka 16×12 median z clippingiem po usunięciu gwiazd i wielomian stopnia 2–3 per kanał, tylko w masce nieba, z ochroną Drogi Mlecznej. Opcjonalnie odszumia się sieć trenowaną na parach parzysty/nieparzysty.

### Krok 10 — kolor, rozciągnięcie i eksport

Balans bieli wynika z zablokowanych wzmocnień albo z kalibracji na średnim kolorze gwiazd. Rozciągnięcie Luptona to **(R,G,B)·asinh(I/β)/I** z I = (R+G+B)/3 i β równym kilku σ tła, z obcinaniem po max(R,G,B). Pierwszy plan dostaje osobne, łagodniejsze tonowanie. Mieszanie to final = α·sky + (1 − α)·fg z rozmyciem odległościowym kilku pikseli. Eksport obejmuje liniowy DNG/TIFF oraz HEIF/JPEG, a dokończenie może przejąć `BGContinuedProcessingTask`.

### Ryzyka do sprawdzenia na urządzeniu przed implementacją pełną

| Ryzyko | Dlaczego krytyczne | Test na urządzeniu |
|---|---|---|
| Rzeczywisty `maxExposureDuration` i ISO per format (iPhone 15–18) | Czy któryś format daje > 1 s? Od tego zależy budżet szumu odczytu | Zrzut `device.formats` |
| Przerwa między kolejnymi ujęciami Bayer RAW 1 s (`.speed`) | Wypełnienie czasu (duty cycle) decyduje o efektywnej integracji; brak danych | Pętla 600 ujęć, histogram odstępów znaczników czasu |
| Czy 12 MP Bayer RAW z sensora 48 MP to binning i jaki ma szum | Wpływa na λ_r i wybór ISO | Pomiar `NoiseProfile` i wariancji darków |
| Konwencja `CMAttitude` (A vs Aᵀ) i macierz C dla bufora AVCapture | Zła konwencja odbija biegun | Test grawitacji; dopasowanie bieguna z gwiazd vs prior |
| Dokładność kursu i jego dryf przez 30–60 min | Rozmiar okna bramkowania | Logowanie `headingAccuracy`; porównanie z p_cam z gwiazd |
| Dostępność `AVCameraCalibrationData` dla pojedynczej kamery przy RAW | Bez LUT trzeba estymować k₁ z gwiazd | Próba z `isCameraCalibrationDataDeliverySupported` |
| Czy intrinsics per klatka odzwierciedlają `lensPosition` i dryf termiczny ostrości | Błąd skali f fałszuje warp na brzegach | Sprawdzian θ vs ω·Δt w czasie sesji |
| OIS „pływający” na statywie mimo wyłączenia | Losowe mikroprzesunięcia klatek | Residua rejestracji przy zablokowanym telefonie |
| Walidacja modelu czysto rotacyjnego vs homografia | Brak literatury dla telefonów | Residua RMS obu modeli na tej samej sekwencji |
| Refrakcja i residuum przy horyzoncie | Nieliniowe odchyłki rzędu kilku px/h | Residua w funkcji wysokości |
| Wydajność Metal, pamięć i termika przez 60 min | `.critical` wymusza przerwanie kamery | Sesja godzinna z logami `thermalState` i baterii |
| Jakość względem Night mode Apple | Raport „znacznie gorszy” dla 30×1 s | Ślepe porównanie przy tej samej scenie i czasie |
| Maska nieba przy chmurach i wietrze w drzewach | Sygnał wariancji zanika | Zestaw testowy scen z ręcznymi maskami |
| Ciągły surowy strumień ProRes RAW z długą klatką (iPhone 17 Pro+) | Mógłby zastąpić pętlę RAW i usunąć przerwy | `videoSupportedFrameRateRanges` formatów ProRes RAW |

## Wnioski

Pytanie „jak skorygować naświetlenie zgodnie z ruchem gwiazd” na iPhonie rozstrzyga głównie platforma, a nie fizyka. Fizyka jest tu przyjazna: niebo to sztywna rotacja o znanej prędkości, więc cały ruch opisują dwa kąty kierunku bieguna, a operator M = B·S jest znany co do tych dwóch kątów. Limit 1 s sprawia jednak, że B jest praktycznie tożsamością. Zadanie „odwrócenia J = M·I” sprowadza się więc do bardzo precyzyjnego S, czyli rejestracji nieba na poziomie ułamka piksela przez godzinę mimo kompasu mylącego się o stopnie. Do tego dochodzi statystycznie odporne scalanie tysięcy klatek przy stałej pamięci oraz dekonwolucja efektywnej PSF stosu, a nie smugi. Wynika z tego nieoczywista kolejność inwestycji: najpierw pomiar przerw między ujęciami i szumu odczytu, bo one wyznaczają sufit jakości, potem dopasowanie bieguna i scalanie strumieniowe, a dekonwolucja i uczone odszumianie na końcu.

Najbardziej wartościowe i zarazem najbardziej ryzykowne jest połączenie, którego literatura nie opisuje: rejestracja czysto rotacyjna z globalnie dopasowanym biegunem, inicjowana czujnikami telefonu. To jednocześnie kalibrator kompasu (p_cam plus grawitacja dają prawdziwą północ bez magnetometru) i fundament dla wszystkiego innego: mapy pokrycia, długości śladu per piksel, analitycznego jądra dla teleobiektywu i maski nieba z wariancji. Jeśli prototyp na urządzeniu pokaże residua poniżej ~0,3 px w godzinnej sekwencji, AstralCamera dostanie przewagę, której nie da się skopiować samą fuzją klatek. Bez tego pomiaru projekt pozostaje elegancką hipotezą.
