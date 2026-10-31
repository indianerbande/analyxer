import SwiftUI
import AndroidAnalyxerCore

struct PlayDeviceSetupView: View {
    @EnvironmentObject var model: AnalyxerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Google-Play-Gerät anlegen").font(.headline)
            Text("Ein eigenes Tablet oder Telefon mit Play Store. Nach dem Start im Android-Fenster anmelden und Apps installieren. Unter Installierte Apps → Untersuchen entsteht das Analyseprojekt.").font(.callout).foregroundStyle(.secondary)
            if model.playImages.isEmpty {
                Text("Kein passendes Google-Play-Image installiert. In Android Studio → SDK Manager → SDK Platforms ein Google Play ARM64-Image (Apple Silicon) bzw. x86_64-Image (Intel) installieren; danach Geräte aktualisieren.").font(.caption)
            } else {
                Picker("Geräteformat", selection: $model.newPlayLayout) {
                    ForEach(PlayDeviceLayout.allCases) { layout in Text(layout.title).tag(layout) }
                }.pickerStyle(.segmented)
                HStack {
                    TextField("Gerätename", text: $model.newPlayName).textFieldStyle(.roundedBorder)
                    Picker("System", selection: $model.playImageID) {
                        ForEach(model.playImages) { image in Text(image.title).tag(image.id) }
                    }
                    Button("Gerät anlegen") { model.createPlayDevice() }.buttonStyle(.borderedProminent)
                }
            }
        }.disabled(model.busy).padding(20).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
extension AnalyxerModel {
    func createPlayDevice() {
        guard let image = playImages.first(where: { $0.id == playImageID }) else { return }
        let play = playService, name = newPlayName, layout = newPlayLayout
        perform("Google-Play-Gerät wird angelegt …") {
            _ = try await play.create(name: name, image: image, layout: layout)
            self.persistentDevice = true
            await self.refresh()
            self.message = "Google-Play-Gerät angelegt. Jetzt starten; Apps und Anmeldung bleiben im dauerhaften Modus erhalten."
        }
    }
}
