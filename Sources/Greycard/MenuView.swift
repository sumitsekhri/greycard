import AppKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            WarmthSection()
            Divider()
            presetSection
            Divider()
            profilesSection
            if let notice = model.notice {
                Text(notice.text)
                    .font(.caption)
                    .foregroundStyle(notice.isWarning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.refresh() }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text("Greycard").font(.headline)
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.displays.count > 1 {
                Picker("Display", selection: displayBinding) {
                    ForEach(model.displays) { Text($0.name).tag(Optional($0.uuid)) }
                }
            }

            if model.presets.isEmpty {
                Text("This display doesn't offer Apple presets.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Preset", selection: presetBinding) {
                    ForEach(model.presets) { Text($0.name).tag(Optional($0.id)) }
                }
            }

            if model.brightnessLocked {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Brightness fixed by this preset. True Tone is locked off.")
                        if let reason = model.lockReason {
                            Text(reason).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .font(.caption)
            }

            if model.activePresetID != nil {
                Picker("Brightness lock", selection: lockBinding) {
                    Text("Auto-detect").tag(LockChoice.auto)
                    Text("Always locked").tag(LockChoice.locked)
                    Text("Never locked").tag(LockChoice.unlocked)
                }
                .font(.caption)
                .help("If auto-detect gets a preset wrong, set it here. Remembered per preset.")
            }

            Toggle("True Tone", isOn: trueToneBinding)
                .disabled(!model.trueToneSupported || model.brightnessLocked)

            Toggle("Night Shift", isOn: nightShiftBinding)
                .disabled(!model.nightShiftAvailable || model.warmthBlocked)
            if model.nightShiftOn && !model.warmthBlocked {
                HStack {
                    Text("Less").font(.caption)
                    Slider(value: strengthBinding, in: 0...1, onEditingChanged: { editing in
                        if !editing { model.commitNightShiftStrength() }
                    })
                    Text("More").font(.caption)
                }
            }
        }
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profiles").font(.subheadline.bold())
            if model.profiles.isEmpty {
                Text("Set things up above, then save them as a profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.profiles) { profile in
                ProfileRow(profile: profile, isActive: model.activeProfileID == profile.id)
            }
            HStack {
                TextField("New profile name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save Current", action: save)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Locked presets also block warmth & Night Shift", isOn: blocksWarmthBinding)
                .toggleStyle(.checkbox)
            HStack {
                Toggle("Launch at login", isOn: launchBinding).toggleStyle(.checkbox)
                Spacer()
                Button("Refresh") { model.refresh() }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .font(.caption)
    }

    private func save() {
        model.saveCurrentAsProfile(named: newName)
        newName = ""
    }

    // MARK: Bindings

    enum LockChoice: Hashable { case auto, locked, unlocked }

    private var lockBinding: Binding<LockChoice> {
        Binding(get: {
            switch model.lockOverride {
            case .none: return .auto
            case .some(true): return .locked
            case .some(false): return .unlocked
            }
        }, set: { choice in
            switch choice {
            case .auto: model.setLockOverride(nil)
            case .locked: model.setLockOverride(true)
            case .unlocked: model.setLockOverride(false)
            }
        })
    }
    private var displayBinding: Binding<String?> {
        Binding(get: { model.selectedDisplayUUID }, set: { model.selectDisplay(uuid: $0) })
    }
    private var presetBinding: Binding<String?> {
        Binding(get: { model.activePresetID }, set: { id in
            if let id { Task { await model.selectPreset(id: id) } }
        })
    }
    private var trueToneBinding: Binding<Bool> {
        Binding(get: { model.trueToneOn }, set: { on in Task { await model.setTrueTone(on) } })
    }
    private var nightShiftBinding: Binding<Bool> {
        Binding(get: { model.nightShiftOn }, set: { model.setNightShift($0) })
    }
    private var strengthBinding: Binding<Float> {
        Binding(get: { model.nightShiftStrength }, set: { model.previewNightShiftStrength($0) })
    }
    private var blocksWarmthBinding: Binding<Bool> {
        Binding(get: { model.lockBlocksWarmth }, set: { model.setLockBlocksWarmth($0) })
    }
    private var launchBinding: Binding<Bool> {
        Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
    }
}

/// f.lux-style colour-temperature control. Kelvin, not lumens: lower = warmer.
private struct WarmthSection: View {
    @EnvironmentObject var model: AppModel

    private struct Stop: Hashable { let name: String; let kelvin: Double }

    private let stops = [
        Stop(name: "Candle", kelvin: 1900), Stop(name: "Halogen", kelvin: 3400),
        Stop(name: "Fluorescent", kelvin: 4200), Stop(name: "Daylight", kelvin: 6500),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "sun.max.fill").foregroundStyle(swatch)
                Text("Warmth").font(.subheadline.bold())
                Spacer()
                Text(model.tintEnabled ? "\(Int(model.tintKelvin))K" : "Off")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Toggle("", isOn: Binding(get: { model.tintEnabled }, set: { model.setTintEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            Slider(value: Binding(get: { model.tintKelvin }, set: { model.setTintKelvin($0) }),
                   in: 1900...10000, step: 100) {
                EmptyView()
            } minimumValueLabel: {
                Image(systemName: "flame").font(.caption)
            } maximumValueLabel: {
                Image(systemName: "snowflake").font(.caption)
            }

            HStack(spacing: 4) {
                ForEach(stops, id: \.self) { stop in
                    Button(stop.name) { model.setTintKelvin(stop.kelvin) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Int(model.tintKelvin) == Int(stop.kelvin) && model.tintEnabled ? Color.accentColor : nil)
                }
            }

            if model.warmthBlocked && model.tintEnabled {
                Text("Paused while this preset locks brightness.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(model.warmthBlocked)
    }

    /// Icon colour follows the chosen temperature.
    private var swatch: Color {
        let m = GammaTint.multipliers(kelvin: Int(model.tintKelvin))
        return model.tintEnabled ? Color(red: Double(m.r), green: Double(m.g), blue: Double(m.b)) : .secondary
    }
}

private struct ProfileRow: View {
    @EnvironmentObject var model: AppModel
    let profile: DisplayProfile
    let isActive: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                Text(profile.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if hovering {
                Button { model.delete(profile) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete profile")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { Task { await model.apply(profile) } }
        .contextMenu {
            Button("Apply") { Task { await model.apply(profile) } }
            Button("Overwrite with Current Settings") { model.overwrite(profile) }
            Button("Copy Shortcut URL") {
                let name = profile.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile.name
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("greycard://apply?name=\(name)", forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(profile) }
        }
    }
}
