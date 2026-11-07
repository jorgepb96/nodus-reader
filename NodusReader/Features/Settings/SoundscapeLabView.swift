// SPDX-License-Identifier: AGPL-3.0-only
//
// Developer-only screen for the Soundscape Lab (see SoundscapeLab.swift).
// Compiled only with NODUS_SOUNDSCAPE_LAB; its text is not localized on purpose.
#if NODUS_SOUNDSCAPE_LAB
import StableAudioMLX
import SwiftUI

struct SoundscapeLabView: View {
    @Environment(PlaybackController.self) private var playback
    @State private var lab = SoundscapeLab.shared

    var body: some View {
        Form {
            Section {
                LabeledContent(String("Device"), value: "\(lab.report.device), \(lab.report.system)")
                LabeledContent(String("RAM"), value: SoundscapeLab.bytes(Int64(lab.report.physicalMemoryBytes)))
                LabeledContent(String("Footprint now"), value: SoundscapeLab.bytes(lab.liveFootprint))
                LabeledContent(String("Thermal state"), value: lab.liveThermal)
                Text(verbatim: lab.status)
                    .font(.footnote.monospaced())
                if let progress = lab.downloadProgress {
                    ProgressView(value: progress)
                }
                if let died = lab.previousRunDied {
                    Text(verbatim: "Previous launch ended during \(died).")
                        .foregroundStyle(.red)
                }
                if lab.isBusy {
                    Button(String("Cancel"), role: .destructive) { lab.cancel() }
                }
            } header: {
                Text(verbatim: "Soundscape Lab (feasibility, developer only)")
            }

            Section {
                ForEach(SA3ModelKind.allCases, id: \.self) { kind in
                    HStack {
                        Text(verbatim: kind.displayName)
                        Spacer()
                        if lab.isInstalled(kind) {
                            Button(String("Delete"), role: .destructive) { lab.remove(kind) }
                                .disabled(lab.isBusy)
                        } else {
                            Button(String("Download")) { lab.install(kind) }
                                .disabled(lab.isBusy)
                        }
                    }
                }
                LabeledContent(String("On disk"), value: SoundscapeLab.bytes(lab.bytesOnDisk))
            } header: {
                Text(verbatim: "Models: stabilityai/stable-audio-3-optimized @ 30cb264")
            } footer: {
                Text(verbatim: "Stability AI Community License and Gemma Terms of Use. Powered by Stability AI. About 1.7 GB for one model, 2.6 GB for both.")
            }

            Section {
                Toggle(String("Include 120 s clips"), isOn: $lab.includeLongClips)
                Button(String("Run benchmark suite")) { lab.runSuite() }
                    .disabled(lab.isBusy || !(lab.isInstalled(.music) || lab.isInstalled(.sfx)))
                Stepper(value: $lab.sustainedMinutes, in: 2 ... 30, step: 2) {
                    Text(verbatim: "Sustained test: \(Int(lab.sustainedMinutes)) min")
                }
                Button(String("Run sustained test (unplug for battery)")) { lab.runSustained() }
                    .disabled(lab.isBusy || !(lab.isInstalled(.music) || lab.isInstalled(.sfx)))
            } header: {
                Text(verbatim: "Measurements")
            }

            Section {
                LabeledContent(String("Narration"), value: playback.isPlaying ? (playback.isLoading ? "waiting" : "playing") : "stopped")
                LabeledContent(String("Stalls"), value: "\(lab.narrationStallCount), \(String(format: "%.1f", lab.narrationStallSeconds)) s")
                ForEach(SA3ModelKind.allCases.filter(lab.isInstalled), id: \.self) { kind in
                    Button(String("Generate \(kind.displayName) during narration")) { lab.runCoexistence(kind: kind) }
                        .disabled(lab.isBusy || !playback.isPlaying)
                }
            } header: {
                Text(verbatim: "Narration coexistence")
            } footer: {
                Text(verbatim: "Start narration on a part of a book that is not cached yet, then come back here.")
            }

            Section {
                LabeledContent(String("Now playing"), value: lab.nowPlaying ?? "nothing")
                VStack(alignment: .leading) {
                    Text(verbatim: "Music volume \(Int(lab.musicVolume * 100)) %")
                    Slider(value: $lab.musicVolume, in: 0 ... 1)
                }
                VStack(alignment: .leading) {
                    Text(verbatim: "Ambience volume \(Int(lab.ambienceVolume * 100)) %")
                    Slider(value: $lab.ambienceVolume, in: 0 ... 1)
                }
                ForEach(lab.generatedLoops, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        lab.play(url, layer: url.lastPathComponent.hasPrefix("music") ? .music : .ambience)
                    }
                    .font(.footnote.monospaced())
                }
                Button(String("Stop")) { lab.stopPlayback() }
            } header: {
                Text(verbatim: "Generated loops")
            } footer: {
                Text(verbatim: "Levelled like the catalog (music −20 LUFS, ambience −28 LUFS). Under narration the engine ducks music 10 dB and ambience 4 dB, as Immersive Audio does.")
            }

            Section {
                ForEach(lab.report.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: entry.test).font(.footnote.weight(.semibold))
                        if let m = entry.measurement {
                            Text(verbatim: String(format: "%@ %.0f s, %d steps: total %.1f s (load %.1f, sample %.1f, decode %.1f), %.1f× RT, peak %@, %@→%@",
                                                  m.model, m.seconds, m.steps, m.timings.total, m.timings.loading,
                                                  m.timings.sampling, m.timings.decode, m.realtimeFactor,
                                                  SoundscapeLab.bytes(m.peakFootprintBytes), m.thermalStart, m.thermalEnd))
                                .font(.caption.monospaced())
                        }
                        if let note = entry.note {
                            Text(verbatim: note).font(.caption)
                        }
                    }
                }
                Button(String("Clear report"), role: .destructive) { lab.clearReport() }
                    .disabled(lab.isBusy)
            } header: {
                Text(verbatim: "Report (Documents/SoundscapeLab/report.json)")
            }
        }
        .navigationTitle(Text(verbatim: "Soundscape Lab"))
        .onAppear { lab.playback = playback }
    }
}
#endif
