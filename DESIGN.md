# Runloop · Direzione visiva

25 novembre 2026 · iPhone e Apple Watch

Runloop accompagna tre momenti della corsa. Si prepara il percorso su iPhone o Watch, si corre con le metriche essenziali sul dispositivo che si porta con sé e si rilegge il risultato nello storico. La gerarchia cambia con ciò che serve in ciascun momento.

## Ricerca di mercato

Confronto qualitativo delle app rappresentative per pianificazione, avvio, lettura in corsa e analisi. La selezione si basa sulla vicinanza ai flussi di Runloop.

| Riferimento | Modello osservato | Applicazione in Runloop |
| --- | --- | --- |
| Strava | La mappa è il punto d'ingresso per creare o scegliere un percorso. Distanza e dettagli arrivano al momento della scelta. | La geometria reale identifica il percorso nella libreria. Nell'editor la mappa occupa la superficie principale e i controlli restano disponibili in basso. [Strava](https://support.strava.com/en-us/articles/15401756-how-do-community-routes-on-strava-work) |
| Nike Run Club | Avvio della corsa e corse guidate comunicano subito cosa si può fare. Lo storico raccoglie misure e progressi. | Corsa libera è il comando principale del Watch. Nell'iPhone l'ultima corsa si riconosce dalla distanza e dalla data. [Nike](https://www.nike.com/nrc-app) |
| Runna | Le metriche del Watch possono essere ordinate in base a ciò che serve durante l'allenamento. | Il tempo attivo è la misura dominante. Distanza e passo rimangono vicini e visibili anche in pausa. [Runna](https://support.runna.com/en/articles/18489776-runna-labs-how-to-use-your-apple-watch-with-runna) |
| WorkOutDoors | Il percorso e la cartografia offline sono strumenti di orientamento durante l'attività. | La geometria scaricata sul Watch è leggibile prima della partenza. La mappa dettagliata si apre su richiesta. [WorkOutDoors](https://apps.apple.com/us/app/workoutdoors/id1241909999) |
| Apple Allenamento | Le viste durante la corsa raggruppano le metriche per compito. | Timer, stato e comandi condividono la schermata attiva. Le informazioni di riepilogo appartengono allo storico. [Apple](https://support.apple.com/guide/watch/workout-views-and-running-metrics-apd1f24d4d35/watchos) |

## Corsa su due schermi

«Corsa libera» è raggiungibile dalla libreria su entrambi e da «Allenamenti» su iPhone. «Inizia corsa» appartiene al dettaglio del percorso. Durante la registrazione il tempo attivo domina su entrambi gli schermi, seguito da distanza e passo medio. Il secondo schermo identifica il dispositivo che registra. «Termina» richiede una conferma. Sul polso la lista delle corse recenti privilegia data e distanza.

## Colori e tipografia

| Token | Valore | Uso |
| --- | --- | --- |
| `canvas`, `panel`, `raised` | `#141610`, `#1C2019`, `#2B3127` | Fondo, schede e superfici selezionate |
| `border` | `#3B4537` | Separatori e contorni |
| `text`, `muted` | `#F3F2E8`, `#B0BBAA` | Testo principale e dettagli secondari |
| `accent` | `#F7F348`, `#48BFF7`, `#F74B40`, `#76F748` | Giallo, azzurro, rosso o verde fluo per azione principale, selezione, percorso attivo e riuscita |
| `branch` | `#A8AAB5` | Grigio ardesia per i percorsi alternativi in esplorazione |
| `paused` | `#FFC480` | Tempo e stato della corsa in pausa |
| `danger` | `#FF9D91` | Errori e azioni distruttive |

Il colore fluo si sceglie in Account › Preferenze. Il giallo è il valore iniziale. La scelta è salvata sul dispositivo e trasmessa all'Apple Watch associato. Il testo primario sul fondo ha contrasto 16,2:1 e il testo secondario sulla superficie selezionata 6,7:1. Lo stato di pausa è indicato anche da testo e icona. Le tracce pianificata e registrata hanno rispettivamente linea tratteggiata e continua.

Barlow Condensed Bold identifica titoli, distanze e tempo attivo. SF mantiene leggibili testo e comandi. SF Mono distingue letture compatte come distanze delle varianti, passo e obiettivo. Le dimensioni seguono Dynamic Type. [Barlow e licenza del font](https://github.com/jpt/barlow)

I comandi Centro mappa e La mia posizione condividono una superficie di 30 punti e hanno aree di tocco di almeno 44. La distanza effettiva prende il posto del messaggio di partenza quando il percorso è pronto. In libreria Nuovo percorso usa l'accento fluo e la traccia del percorso più recente ha distanza e tipo sotto l'anteprima. Lo strumento Modifica percorso è accessibile direttamente dalla barra del dettaglio. Bandiera e numeri distinguono la partenza e le tappe sulla mappa. [Unslop](https://github.com/heydamir/unslop)

Sul Watch «Corsa libera» è la prima azione nella schermata dei percorsi. Il comando «+ Nuovo» accanto a «Percorsi» apre l'editor con mappa, partenza e tappe. Distanze e varianti compaiono dopo il calcolo, con «Altri anelli» e «Salva percorso» separati. Il dettaglio presenta «Mappa» e «Variante» sotto «Inizia corsa». Mappa e traccia occupano la stessa altezza. In entrambe le librerie il nome precede distanza e tipo, anche nelle righe successive alla prima. I vecchi percorsi ricevuti senza tipo mostrano solo la distanza.

Il permesso di posizione viene chiesto alla prima apertura su iPhone e Watch. Se l’utente lo nega, può scegliere la partenza sulla mappa. Su iPhone «La mia posizione» permette anche di aprire le impostazioni dell’app.

## Microinterazioni

La pressione dei comandi dà un riscontro breve di 140 ms. La linea della barra inferiore e l'indicatore della modalità scorrono verso l'opzione attiva. Nell'editor il suggerimento manuale e l'obiettivo dell'anello occupano la stessa riga. Distanza e varianti dell'anteprima uscente sfumano durante il cambio di modalità, con una transizione di 220 ms. Il cambio di scheda, modalità, punto o percorso ha un riscontro aptico di selezione. L'obiettivo e la distanza cambiano con una transizione numerica legata al nuovo valore.

Dopo una ricerca, fino a cinque rami grigio ardesia si disegnano con partenze sfalsate e sfumano in sequenza. La traccia nel colore fluo scelto resta visibile. Anche una singola proposta e un cambio di variante si disegnano dalla partenza, con un'animazione di circa 0,8 secondi. La variante attiva è sottolineata. Da cinque proposte, o con testo di accessibilità, il selettore scorre in orizzontale. [Mapbox, disegno progressivo del percorso](https://www.mapbox.com/blog/building-cinematic-route-animations-with-mapboxgl)

Manuale usa una traccia aperta con due estremi, Ad anello il profilo di un isolato con un punto che indica la partenza. Aggiungendo una tappa o spostando la partenza compare un cerchio di 340 ms nel punto scelto. Pan e annullamento lasciano la mappa ferma. Il selettore delle varianti abbina il numero cerchiato alla distanza, con una sottolineatura che segue la scelta su iPhone e Watch. Sul Watch una nuova ricerca riporta alla mappa, mentre il cambio di variante mantiene la posizione di lettura. Con Riduci movimento il punto, la selezione e il tracciato definitivo sono immediati.

La conferma di invio al Watch segue la ricezione effettiva. Sul Watch pausa e ripresa hanno un riscontro aptico di selezione, il salvataggio riuscito una conferma e gli errori un riscontro distinto. L'ambra accompagna il timer e l'etichetta di pausa. Con Riduci movimento, le selezioni e la geometria appaiono subito. Restano stati, etichette, riscontro aptico e opacità di pressione.

### Cruscotto della corsa

Sul Watch lo scorrimento lascia libera la zona dell’ora. «Pausa» o «Riprendi» affiancano «Termina» quando entrambe le etichette entrano per intero. Negli spazi più stretti i comandi passano su due righe, uno per riga.

Tempo attivo, distanza, passo e intensità sono componenti condivisi da iPhone e Watch. La posizione dell’indicatore identifica una delle cinque zone, il testo esplicita numero e confronto con l’obiettivo e l’accento riprende la preferenza del profilo. La schermata riserva spazio al sensore anche mentre attende il primo dato. La pressione dà un feedback breve, il passaggio alla pausa modifica lo stato nello stesso spazio. Con Riduci movimento gli indicatori cambiano direttamente. L’uscita offre salvataggio e scarto, con conferma dedicata allo scarto.
