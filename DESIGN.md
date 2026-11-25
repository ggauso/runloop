# Runloop · Direzione visiva

25 novembre 2026 · iPhone e Apple Watch

Runloop accompagna tre momenti della corsa. Si prepara il percorso su iPhone, si corre con le metriche essenziali sul Watch e si rilegge il risultato nello storico. La gerarchia cambia con ciò che serve in ciascun momento.

## Ricerca di mercato

Confronto qualitativo delle app rappresentative per pianificazione, avvio, lettura in corsa e analisi. La selezione si basa sulla vicinanza ai flussi di Runloop.

| Riferimento | Modello osservato | Applicazione in Runloop |
| --- | --- | --- |
| Strava | La mappa è il punto d'ingresso per creare o scegliere un percorso. Distanza e dettagli arrivano al momento della scelta. | La geometria reale identifica il percorso nella libreria. Nell'editor la mappa occupa la superficie principale e i controlli restano disponibili in basso. [Strava](https://support.strava.com/en-us/articles/15401756-how-do-community-routes-on-strava-work) |
| Nike Run Club | Avvio della corsa e corse guidate comunicano subito cosa si può fare. Lo storico raccoglie misure e progressi. | Corsa libera è il comando principale del Watch. Nell'iPhone l'ultima corsa si riconosce dalla distanza e dalla data. [Nike](https://www.nike.com/nrc-app) |
| Runna | Le metriche del Watch possono essere ordinate in base a ciò che serve durante l'allenamento. | Il tempo attivo è la misura dominante. Distanza e passo rimangono vicini e visibili anche in pausa. [Runna](https://support.runna.com/en/articles/18489776-runna-labs-how-to-use-your-apple-watch-with-runna) |
| WorkOutDoors | Il percorso e la cartografia offline sono strumenti di orientamento durante l'attività. | La geometria scaricata sul Watch è leggibile prima della partenza. La mappa dettagliata si apre su richiesta. [WorkOutDoors](https://apps.apple.com/us/app/workoutdoors/id1241909999) |
| Apple Allenamento | Le viste durante la corsa raggruppano le metriche per compito. | Timer, stato e comandi condividono la schermata attiva. Le informazioni di riepilogo appartengono allo storico. [Apple](https://support.apple.com/guide/watch/workout-views-and-running-metrics-apd1f24d4d35/watchos) |

## Contrasto e tipografia

- Sfondo antracite `#101114`, superficie `#1A1C21`, bordo `#3C4049`.
- Testo avorio `#F5F6F0`, secondario `#AFB5BF`. Il lime `#D9FF4A` evidenzia comando primario, scelta, traccia in primo piano e successo. Le azioni distruttive usano il corallo `#FF9A93`.
- Le coppie lime su antracite e testo secondario su superficie danno rapporti di contrasto sRGB di circa 16,5:1 e 8,3:1. Lo stato in pausa ha anche etichetta e icona. Le tracce pianificata e registrata hanno rispettivamente ritmi tratteggiato e continuo.
- Titoli con peso alto, cifre tabulari e dimensioni adattabili al testo di sistema. L'anteprima dei percorsi è una proiezione della geometria salvata.
- I comandi Centro mappa e La mia posizione hanno la stessa larghezza e una superficie neutra. Restano affiancati con il testo di accessibilità. Il fondo visibile è alto 30 punti e l’area di tocco almeno 44. Il lime resta sul comando che fa avanzare il flusso.

Le scelte seguono la gerarchia di [Layout](https://impeccable.style/docs/layout/), la leggibilità di [Typeset](https://impeccable.style/docs/typeset/) e l'uso semantico del colore di [Colorize](https://impeccable.style/docs/colorize/).

## Microinterazioni

La pressione abbassa brevemente opacità e scala. Il cambio di modalità, variante o tappa ha un riscontro aptico di selezione. Il successo dell'invio al Watch si riconosce dalla conferma visiva e aptica dopo l'effettiva ricezione. Sul Watch pausa, ripresa e salvataggio hanno riscontri distinti. Con Riduci movimento, restano lo stato, l'etichetta e l'opacità di pressione. [Animate](https://impeccable.style/docs/animate/)

Quando arrivano più proposte, fino a tre rami turchesi si disegnano sulla mappa con partenze sfalsate e un punto chiaro in testa. Il percorso selezionato si disegna in lime mentre i rami sfumano in sequenza. L'animazione completa dura fino a circa 2,6 secondi e riparte quando si sceglie un'altra variante. Se arriva una sola proposta, il disegno dura circa 0,8 secondi. Con Riduci movimento, il percorso selezionato appare subito. [Mapbox, disegno progressivo del percorso](https://www.mapbox.com/blog/building-cinematic-route-animations-with-mapboxgl)
