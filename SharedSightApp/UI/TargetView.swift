import SwiftUI
import SharedSightCore

/// Register a person -> show their marker -> start acquisition. Three short sections, no dashboard.
struct TargetView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var pendingDelete: PersonProfile?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if let error = model.storeError {
                    Section {
                        Label(model.tr("Saved people could not be read or written: \(error)",
                                       "Impossibile leggere o salvare le persone registrate: \(error)"),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.alert)
                    }
                }
                if let person = model.activeProfile {
                    activeSection(person)
                    trackingSection
                    inViewSection
                }
                peopleSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(model.tr("Target", "Bersaglio"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(model.tr("Done", "Fine")) { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(model.tr("Close keyboard", "Chiudi tastiera")) { nameFocused = false }
                }
            }
            .confirmationDialog(
                model.tr("Delete \(pendingDelete?.userID ?? "")?", "Eliminare \(pendingDelete?.userID ?? "")?"),
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(model.tr("Delete profile and local data", "Elimina profilo e dati locali"), role: .destructive) {
                    if let id = pendingDelete?.id { model.deleteProfile(id) }
                    pendingDelete = nil
                }
                Button(model.tr("Cancel", "Annulla"), role: .cancel) { pendingDelete = nil }
            } message: {
                Text(model.tr("The profile, its marker and its tracking events are erased from this iPhone. Printed markers stop working.",
                              "Il profilo, il suo marcatore e i suoi eventi di tracciamento vengono cancellati da questo iPhone. I marcatori stampati non funzioneranno più."))
            }
        }
    }

    // MARK: Active person

    private func activeSection(_ person: PersonProfile) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(person.displayName).font(.title2.weight(.semibold))
                Text(person.userID).font(.subheadline.monospaced()).foregroundStyle(Theme.accent)
                Text(model.tr("Assisted person · registered \(person.registeredAt.formatted(date: .abbreviated, time: .omitted))",
                              "Persona assistita · registrata il \(person.registeredAt.formatted(date: .abbreviated, time: .omitted))"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            NameField(person: person, focused: $nameFocused)

            NavigationLink {
                MarkerView(profileID: person.id)
            } label: {
                Label(model.tr("Identification marker", "Marcatore di identificazione"), systemImage: "qrcode")
            }

            LabeledContent(model.tr("Persistent UUID", "UUID persistente")) {
                Text(person.id.uuidString).font(.caption2.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
        } header: {
            Text(model.tr("Registered person", "Persona registrata"))
        }
    }

    // MARK: Tracking

    private var trackingSection: some View {
        let p = model.targetPresentation
        let target = model.snapshot.target
        return Section {
            HStack(spacing: 12) {
                Image(systemName: p.symbol).foregroundStyle(Theme.color(p.tone)).frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(.footnote.weight(.bold)).tracking(1).foregroundStyle(Theme.color(p.tone))
                    Text(p.detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.tr("Tracking status", "Stato del tracciamento"))
            .accessibilityValue("\(p.title). \(p.detail)")

            if let track = target.trackID {
                LabeledContent(model.tr("Current track", "Traccia attuale"), value: String(format: "TRACK-%03d", track))
                LabeledContent(model.tr("Confidence", "Confidenza"),
                               value: "\(Int((target.associationConfidence * 100).rounded()))%")
            }

            if model.trackingOn {
                Button(role: .destructive) { model.stopTracking() } label: {
                    Label(model.tr("Stop following", "Ferma inseguimento"), systemImage: "stop.fill")
                }
            } else {
                Button { model.startTracking(); dismiss() } label: {
                    Label(model.tr("Start target acquisition", "Avvia acquisizione bersaglio"), systemImage: "scope")
                }
                .disabled(model.paused)
            }
        } header: {
            Text(model.tr("Tracking", "Tracciamento"))
        } footer: {
            Text(model.tr(
                "Shared Sight follows only the person whose marker it reads. If it cannot tell who is who, it pauses instead of guessing. No face recognition.",
                "Shared Sight segue solo la persona di cui legge il marcatore. Se non riesce a distinguere le persone, si ferma invece di tirare a indovinare. Nessun riconoscimento facciale."))
        }
    }

    /// The accessible way to do what a tap on the camera picture does.
    @ViewBuilder private var inViewSection: some View {
        let people = model.snapshot.entries.filter { $0.track.label == "person" && $0.isCurrentEvidence }
        if !people.isEmpty, !model.paused {
            Section {
                ForEach(people) { entry in
                    let isTarget = entry.id == model.snapshot.target.trackID
                    Button {
                        model.selectTarget(trackID: entry.id)
                    } label: {
                        HStack {
                            Text(entry.track.trackTag).font(.body.monospaced()).foregroundStyle(.white)
                            Spacer()
                            Text(isTarget ? model.tr("Target", "Bersaglio") : model.tr("Set as target", "Imposta come bersaglio"))
                                .foregroundStyle(isTarget ? Theme.accent : .secondary)
                        }
                    }
                    .disabled(isTarget && model.snapshot.target.isLocked)
                }
            } header: {
                Text(model.tr("People in view now", "Persone inquadrate ora"))
            } footer: {
                Text(model.tr(
                    "Track numbers are temporary and say nothing about who a person is. Choose one by hand only when you can see it is the registered person.",
                    "I numeri di traccia sono temporanei e non dicono chi è la persona. Scegline uno a mano solo se vedi che è la persona registrata."))
            }
        }
    }

    // MARK: All people

    private var peopleSection: some View {
        Section {
            ForEach(model.profiles) { person in
                Button { model.selectProfile(person.id) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.displayName).foregroundStyle(.white)
                            Text(person.userID).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if person.id == model.activeProfileID {
                            Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.accent)
                        }
                    }
                }
                .accessibilityValue(person.id == model.activeProfileID ? model.tr("Selected", "Selezionata") : "")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(model.tr("Delete", "Elimina"), role: .destructive) { pendingDelete = person }
                }
                .accessibilityAction(named: model.tr("Delete", "Elimina")) { pendingDelete = person }
            }
            HStack {
                TextField(model.tr("Name (optional)", "Nome (facoltativo)"), text: $newName)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit(register)
                Button(model.tr("Register", "Registra"), action: register)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.storeError != nil && model.profiles.isEmpty)
            }
        } header: {
            Text(model.profiles.isEmpty ? model.tr("Register a person", "Registra una persona") : model.tr("People", "Persone"))
        } footer: {
            Text(model.tr("Each person gets a permanent ID (USER-0001, …) stored only on this iPhone.",
                          "Ogni persona riceve un ID permanente (USER-0001, …) salvato solo su questo iPhone."))
        }
    }

    private func register() {
        model.createProfile(nickname: newName)
        newName = ""
        nameFocused = false
    }
}

/// Inline rename. Commits on return or when the field loses focus; the user ID never changes.
private struct NameField: View {
    @EnvironmentObject var model: AppModel
    let person: PersonProfile
    var focused: FocusState<Bool>.Binding
    @State private var text = ""

    var body: some View {
        LabeledContent(model.tr("Name", "Nome")) {
            TextField(model.tr("Optional", "Facoltativo"), text: $text)
                .multilineTextAlignment(.trailing)
                .focused(focused)
                .submitLabel(.done)
                .onSubmit(commit)
        }
        .onAppear { text = person.nickname }
        .onChange(of: person.id) { _, _ in text = person.nickname }
        .onChange(of: focused.wrappedValue) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != person.nickname { model.renameProfile(person.id, nickname: trimmed) }
    }
}

/// The wearable marker: a QR code holding a random token. Print it (about 15 cm wide works at a few metres)
/// or show it full screen on the assisted person's own phone.
struct MarkerView: View {
    @EnvironmentObject var model: AppModel
    let profileID: UUID
    @State private var image: UIImage?
    @State private var confirmNew = false

    var body: some View {
        let person = model.profiles.first { $0.id == profileID }
        ScrollView {
            VStack(spacing: 18) {
                if let image {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
                        .accessibilityLabel(model.tr("QR marker for \(person?.userID ?? "")", "Marcatore QR di \(person?.userID ?? "")"))
                } else {
                    ContentUnavailableView(model.tr("No marker", "Nessun marcatore"), systemImage: "qrcode")
                }
                Text(person?.userID ?? "").font(.title3.monospaced().weight(.semibold))
                Text(model.tr(
                    "Wear it where the observing camera can see it: on the back, chest or backpack. It contains a random code, not a name. Anyone can copy a visible marker, so this is a prototype way to point out the target, not proof of identity.",
                    "Indossalo dove la fotocamera che osserva può vederlo: schiena, petto o zaino. Contiene un codice casuale, non un nome. Chiunque può copiare un marcatore visibile: è un modo prototipale per indicare il bersaglio, non una prova di identità."))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let image {
                    ShareLink(item: Image(uiImage: image),
                              preview: SharePreview(model.tr("Shared Sight marker", "Marcatore Shared Sight"), image: Image(uiImage: image))) {
                        Label(model.tr("Share or print", "Condividi o stampa"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(role: .destructive) { confirmNew = true } label: {
                    Label(model.tr("Create a new marker", "Crea un nuovo marcatore"), systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
            .padding(22)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(model.tr("Marker", "Marcatore"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: person?.markerToken) {
            image = person?.markerToken.flatMap { MarkerImage.make(token: $0) }
        }
        .confirmationDialog(model.tr("Replace the marker?", "Sostituire il marcatore?"), isPresented: $confirmNew, titleVisibility: .visible) {
            Button(model.tr("Create new marker", "Crea nuovo marcatore"), role: .destructive) { model.regenerateMarker(profileID) }
            Button(model.tr("Cancel", "Annulla"), role: .cancel) {}
        } message: {
            Text(model.tr("Markers already printed or shared for this person will stop working.",
                          "I marcatori già stampati o condivisi per questa persona smetteranno di funzionare."))
        }
    }
}
