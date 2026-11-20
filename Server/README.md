# Shared Sight · hub locale e stanza 3D

Il server raccoglie ciò che vedono gli iPhone, lo fonde in un unico modello della stanza e fa due cose:

1. **risponde a ogni iPhone** con ciò che quel telefono *non* può vedere ma che un altro vede (la zona d'ombra di
   uno è la zona in luce di un altro), oppure, se non lo vede nessuno, con una stima dichiarata come stima;
2. **mostra la stanza in 3D** nel browser, in tempo reale.

## Avvio

Node.js 22 o successivo.

```sh
npm --prefix Server ci
npm --prefix Server start        # dati reali dagli iPhone
npm --prefix Server run demo     # simulazione: 3 iPhone virtuali (vedi sotto)
```

Il terminale stampa l'indirizzo della dashboard già completo di chiave (`http://localhost:8080/#token=…&session=1234`),
l'URL LAN da inserire sugli iPhone e la chiave. Opzioni: `PORT`, `HOST`, `SHAREDSIGHT_TOKEN`.
HTTP su rete locale fidata: la chiave limita l'accesso, non cifra il traffico. Nessun dato su disco.

## Demo simulata (dati SINTETICI, sessione `DEMO`)

```sh
npm --prefix Server run demo         # 3 iPhone: una persona esce dalla porta, l'iPhone in corridoio continua a vederla
npm --prefix Server run demo:1       # 1 iPhone: nessuno può aiutare, la posizione è stimata e l'incertezza cresce
npm --prefix Server run demo -- --port=8081
```

Apri l'indirizzo stampato. Soggiorno e corridoio uniti da una porta, mobili, due persone e un cane. Ogni iPhone
virtuale "rileva" solo ciò che il suo campo visivo e la geometria reale gli consentono (pareti, porta, mobili e
persone nascondono), con rumore e rilevamenti mancati, e invia esattamente i messaggi che invia l'app. Il terminale
scrive ciò che il server comunica all'iPhone dell'utente. Per alimentare un server già avviato:
`SERVER_URL=http://… SHAREDSIGHT_TOKEN=… npm --prefix Server run demo`.

## Collegare gli iPhone

1. Installa l'app da `SharedSight.xcodeproj` (iOS 17+), stessa Wi-Fi del Mac, consenti la rete locale.
2. **Impostazioni → Stanza 3D · Server locale**: URL LAN (non `localhost`) e chiave, poi **Connetti al server**.
3. Stesso codice sessione su tutti gli iPhone e nella dashboard.
4. Più iPhone: stampa `Docs/AnchorMarker.png`, imposta la larghezza reale, posalo a terra e inquadralo con tutti.
   Chi ha inquadrato il marcatore entra nello *spazio condiviso*; gli altri restano ciascuno nel proprio spazio.
   Re-inquadra il marcatore almeno ogni 30 secondi.
5. Un solo iPhone: non serve il marcatore. Funziona nel proprio spazio e stima da solo ciò che esce dalla vista.

## Che cosa calcola il server (`world.mjs`)

- **Fusione**: ogni telefono invia posizioni sul pavimento misurate (raycast ARKit) con la loro incertezza. Le misure
  dello stesso oggetto da telefoni diversi sono associate con una soglia statistica e fuse in un filtro di Kalman a
  velocità costante. Due persone a un metro restano due oggetti; un telefono che le vede entrambe impedisce la fusione.
- **Chi vede che cosa**: per ogni oggetto e ogni telefono si calcola la linea di vista sulla pianta (campo visivo,
  pareti e porte misurate da ARKit, mobili alti, altre persone). Le finestre non nascondono.
- **Zona d'ombra coperta da un altro**: se A non vede una persona (dietro una porta) e B la misura, la persona resta
  «osservata» e A lo riceve nella risposta: `kind: "seen"`, con posizione, incertezza e motivo (`occluder`).
- **Nessuno la vede**: la posizione è **predetta** (velocità costante smorzata, non attraversa le pareti),
  l'incertezza cresce e dopo 8 secondi o 2 metri di incertezza la stima viene abbandonata. `kind: "estimated"`.
- **Assenza come informazione**: una stima che cade in piena vista di una camera e non viene rilevata non può essere
  lì: viene spostata nel punto nascosto più vicino che avrebbe potuto raggiungere, oppure eliminata.
- **Oggetti vicini con i piedi fuori inquadratura** (nessun punto a terra): confermati dalla sola direzione.
- I mobili fuori vista sono ricordati dove erano; spariscono se una camera guarda quel punto e non li trova.

Non c'è riconoscimento di identità o di aspetto: solo continuità nello spazio.

## Fluidità e latenza

- Gli iPhone inviano 10 messaggi al secondo su una connessione sempre aperta; superfici e anteprima viaggiano solo
  quando cambiano (prima: tutto, 5 volte al secondo).
- Il browser non interroga più il server ogni 400 ms: riceve il modello **in push a 30 Hz** (`GET /api/stream`), con il
  movimento predetto tra un messaggio e l'altro. Se un client è lento salta gli stati vecchi, non li accoda.
- La scena non viene mai ricostruita: gli oggetti restano e vengono mossi a ogni fotogramma con la loro velocità;
  solo l'errore residuo viene assorbito gradualmente, così il rumore di misura non diventa tremolio.
- Misure (su questa macchina, `npm test`): accettare un messaggio e preparare il push costa in media 0,03 ms (p99 0,1 ms);
  il push pesa circa 7 KB; il disegno di un fotogramma costa circa 0,2 ms di JavaScript, 170 chiamate di disegno.
  La dashboard mostra in alto «cattura→server» e «agg/s · fps» misurati dal vivo.

## Dashboard

Trascina per ruotare, rotella per lo zoom, **Dall'alto**, **Visuale** per tornare alla vista iniziale. **Zone d'ombra**
scurisce il pavimento che nessun iPhone sta vedendo. Oggetti pieni = misurati ora; traslucidi con cerchio =
stima (il cerchio è l'incertezza, la linea tratteggiata il percorso previsto). I pallini accanto al nome dicono quali
iPhone lo vedono. Le sagome illustrano la classe (80 classi del modello), non la forma reale.

## Protocollo v2

`POST /api/frames`, JSON, `Authorization: Bearer <chiave>`. Risposta `200`:
`{v:2, advisories:[{id, kind:"seen"|"estimated", label, position, velocity, sigma, relation:"occluded"|"outOfView",
occluder:"wall"|"door"|"object"|null, seenBy, localID, moving, ageMs}], devices}`. Le posizioni sono nello stesso
riferimento in cui il telefono invia (marcatore se allineato, altrimenti il suo mondo ARKit).

Campi inviati: `version:2, deviceID, name, session, epoch, sequence, tracking, anchorID?, camera?:{m:[16]}, fov?, t?, sent?,
planes?:[{id, vertical, kind?, vertices, triangles}]` (assente = invariate), `objects:[{id,label,confidence,box,position?,sigma?,size?}]`,
`jpeg?`. I client v1 (snapshot completo, risposta `204`) restano accettati.

`GET /api/stream?session=` push NDJSON · `GET /api/preview?session=&device=` JPEG · `GET /api/state?session=` stato completo.

## Test

```sh
npm --prefix Server test      # 23 test: geometria, fusione, zone d'ombra, predizione, HTTP, demo end-to-end, latenza
npm --prefix Server run record   # rigenera le registrazioni usate dai test Swift "solo ascolto"
```

Tutto ciò che riguarda la demo è verificato su dati simulati. Acquisizione e allineamento con iPhone reali restano da
validare sul campo.
