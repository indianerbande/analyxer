import SwiftUI
import AndroidAnalyxerCore

struct PlayDeviceSetupView: View {
    @EnvironmentObject var model: AnalyxerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Google Play Device").font(.headline)
            Text("A tablet or phone of your own with the Play Store. After starting it, sign in in the Android window and install apps. Installed Apps → Investigate creates the analysis project.").font(.callout).foregroundStyle(.secondary)
            if model.playImages.isEmpty {
                Text("No suitable Google Play image is installed. In Android Studio → SDK Manager → SDK Platforms, install a Google Play ARM64 image (Apple Silicon) or x86_64 image (Intel); then refresh the devices.").font(.caption)
            } else {
                Picker("Form factor", selection: $model.newPlayLayout) {
                    ForEach(PlayDeviceLayout.allCases) { layout in Text(layout.title).tag(layout) }
                }.pickerStyle(.segmented)
                HStack {
                    TextField("Device name", text: $model.newPlayName).textFieldStyle(.roundedBorder)
                    Picker("System", selection: $model.playImageID) {
                        ForEach(model.playImages) { image in Text(image.title).tag(image.id) }
                    }
                    Button("Create Device") { model.createPlayDevice() }.buttonStyle(.borderedProminent)
                }
            }
        }.disabled(model.busy).padding(20).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}
extension AnalyxerModel {
    func createPlayDevice() {
        guard let image = playImages.first(where: { $0.id == playImageID }) else { return }
        let play = playService, name = newPlayName, layout = newPlayLayout
        perform(String(localized: "Creating the Google Play device …")) {
            _ = try await play.create(name: name, image: image, layout: layout)
            self.persistentDevice = true
            await self.refresh()
            self.message = String(localized: "Google Play device created. Start it now; in persistent mode, apps and sign-in are kept.")
        }
    }
}
