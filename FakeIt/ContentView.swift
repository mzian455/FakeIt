import CoreLocation
import MapKit
import SwiftUI

struct ContentView: View {
    @StateObject private var mapState = MapViewState()
    @StateObject private var search = SearchCompleterModel()

    @State private var devices: [ConnectedDevice] = []
    @State private var selectedDevice: ConnectedDevice?
    @State private var deviceBanner: String?
    @State private var coordinateMode = false
    @State private var latText = ""
    @State private var lonText = ""
    @State private var spoofPhase: SpoofButtonPhase = .idle
    @State private var showParticles = false
    @State private var uiVisible = false
    @State private var searchExpanded = false
    @State private var recent: [SavedSpoofLocation] = []
    @State private var lastInjectionError: String = ""
    @State private var deviceRefreshTimer: Timer?
    @State private var tunneldNotice: String?
    @State private var selectedCompletionIndex: Int?
    @State private var isGoingToLocation = false
    /// Skips one `queryFragment` onChange so picking a suggestion doesn’t clear the selection.
    @State private var skipNextSearchQueryReaction = false

    private let historyStore = LocationHistoryStore()

    private var canGoToLocation: Bool {
        let q = search.queryFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = selectedCompletionIndex, search.completions.indices.contains(idx) { return true }
        return !q.isEmpty
    }

    private var canSimulateOnDevice: Bool {
        mapState.allowSimulateAtPin && selectedDevice != nil && mapState.selectedCoordinate != nil
    }

    var body: some View {
        ZStack {
            FakeItMapNSView(state: mapState, allowsMapSelection: !coordinateMode)
                .ignoresSafeArea()

            if let p = mapState.pinOverlayScreenPoint {
                PinInfoFloatingCard(mapState: mapState)
                    .position(x: p.x, y: max(72, p.y - 76))
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .bottom)), removal: .opacity))
                    .animation(FakeItTheme.spring, value: mapState.pinOverlayScreenPoint)
            }

            ParticleBurstView(isActive: showParticles)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    leftGlassPanel
                        .frame(width: 388)
                        .frame(maxHeight: .infinity, alignment: .top)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)

                bottomCenterHUD
                    .padding(.bottom, 22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        }
        .background(FakeItTheme.background)
        .opacity(uiVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: uiVisible)
        .onAppear {
            refreshDevices()
            recent = historyStore.load()
            uiVisible = true
            search.updateMapRegion(mapState.visibleMapRegion)
            DeviceService.ensureTunneldRunningForIOS17Support()
            deviceRefreshTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { _ in
                refreshDevices()
            }
            RunLoop.main.add(deviceRefreshTimer!, forMode: .common)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fakeItTunneldFailed)) { output in
            if let reason = output.userInfo?["reason"] as? String {
                tunneldNotice = reason
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                    if tunneldNotice == reason { tunneldNotice = nil }
                }
            }
        }
        .onChange(of: mapState.visibleMapRegion) { _, region in
            search.updateMapRegion(region)
        }
        .onChange(of: search.queryFragment) { _, _ in
            if skipNextSearchQueryReaction {
                skipNextSearchQueryReaction = false
                return
            }
            mapState.invalidateSimulationUnlock()
            selectedCompletionIndex = nil
        }
        .onDisappear {
            deviceRefreshTimer?.invalidate()
            deviceRefreshTimer = nil
        }
    }

    private var leftGlassPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FakeIt")
                .font(FakeItTheme.brandTitleFont(28))
                .foregroundStyle(FakeItTheme.textPrimary)
                .tracking(1.2)
                .accessibilityAddTraits(.isHeader)

            if let banner = deviceBanner {
                Text(banner)
                    .font(FakeItTheme.bodyFont(12, weight: .medium))
                    .foregroundStyle(Color.orange.opacity(0.95))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
            }

            if let tunnel = tunneldNotice {
                Text(tunnel)
                    .font(FakeItTheme.bodyFont(11, weight: .medium))
                    .foregroundStyle(Color.yellow.opacity(0.92))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.1)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Device")
                    .font(FakeItTheme.bodyFont(11, weight: .semibold))
                    .foregroundStyle(FakeItTheme.textSecondary)
                Picker("Device", selection: $selectedDevice) {
                    Text("Select iPhone…").tag(Optional<ConnectedDevice>.none)
                    ForEach(devices) { d in
                        Text(d.name).tag(Optional(d))
                    }
                }
                .pickerStyle(.menu)
                .tint(FakeItTheme.accent)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Search")
                    .font(FakeItTheme.bodyFont(11, weight: .semibold))
                    .foregroundStyle(FakeItTheme.textSecondary)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.secondary)
                    TextField("", text: $search.queryFragment, prompt: Text("Places and addresses").foregroundStyle(.tertiary))
                        .textFieldStyle(.plain)
                        .font(FakeItTheme.bodyFont(15))
                        .foregroundStyle(Color.black.opacity(0.88))
                        .onTapGesture { searchExpanded = true }
                        .onSubmit { goToLocation() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(white: 0.97))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )

                if searchExpanded && !search.completions.isEmpty && !search.queryFragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(search.completions.enumerated()), id: \.offset) { index, item in
                            Button {
                                selectSearchCompletion(at: index)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, alignment: .center)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                            .font(FakeItTheme.bodyFont(14, weight: .medium))
                                            .foregroundStyle(FakeItTheme.textPrimary)
                                            .multilineTextAlignment(.leading)
                                        if !item.subtitle.isEmpty {
                                            Text(item.subtitle)
                                                .font(FakeItTheme.bodyFont(12))
                                                .foregroundStyle(FakeItTheme.textSecondary)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(selectedCompletionIndex == index ? FakeItTheme.accent.opacity(0.12) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            if index < search.completions.count - 1 {
                                Divider()
                                    .padding(.leading, 50)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(white: 0.99))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(FakeItTheme.spring, value: search.completions.count)
                }

                Button(action: goToLocation) {
                    HStack(spacing: 8) {
                        if isGoingToLocation {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        Text("Go to location")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.0, green: 0.48, blue: 1.0))
                .disabled(!canGoToLocation || isGoingToLocation)

                Text("Select a suggestion or enter an address, then go to the pin on the map. After that you can simulate on your iPhone.")
                    .font(FakeItTheme.bodyFont(10))
                    .foregroundStyle(FakeItTheme.textSecondary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $coordinateMode.animation(FakeItTheme.spring)) {
                    Text("Coordinate input")
                        .font(FakeItTheme.bodyFont(12, weight: .semibold))
                        .foregroundStyle(FakeItTheme.textSecondary)
                }
                .toggleStyle(.switch)
                .tint(FakeItTheme.accent)

                if coordinateMode {
                    HStack(spacing: 8) {
                        TextField("Latitude", text: $latText)
                            .textFieldStyle(.roundedBorder)
                        TextField("Longitude", text: $lonText)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("Go to coordinates") {
                        applyManualCoordinates()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FakeItTheme.secondaryAccent)
                    .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent")
                    .font(FakeItTheme.bodyFont(11, weight: .semibold))
                    .foregroundStyle(FakeItTheme.textSecondary)
                if recent.isEmpty {
                    Text("No spoof history yet.")
                        .font(FakeItTheme.bodyFont(11))
                        .foregroundStyle(FakeItTheme.textSecondary.opacity(0.8))
                } else {
                    ForEach(recent.prefix(10)) { item in
                        Button {
                            reapplyRecent(item)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(FakeItTheme.bodyFont(12, weight: .medium))
                                        .foregroundStyle(FakeItTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(String(format: "%.5f, %.5f", item.latitude, item.longitude))
                                        .font(FakeItTheme.bodyFont(10))
                                        .foregroundStyle(FakeItTheme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(FakeItTheme.accent.opacity(0.85))
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 0)

            SpoofActionButton(
                phase: $spoofPhase,
                canSimulate: canSimulateOnDevice,
                onSpoof: { performSpoof() },
                onResetIdle: {
                    spoofPhase = .idle
                    mapState.pinSuccessGlow = false
                    lastInjectionError = ""
                }
            )

            Button("Reset Location") {
                runReset()
            }
            .buttonStyle(.bordered)
            .tint(FakeItTheme.textSecondary)
            .foregroundStyle(FakeItTheme.textPrimary)
            .controlSize(.large)
            .frame(maxWidth: .infinity)

            if !lastInjectionError.isEmpty, case .failure = spoofPhase {
                Text(lastInjectionError)
                    .font(FakeItTheme.bodyFont(10))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(FakeItTheme.card.opacity(0.55))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [FakeItTheme.accent.opacity(0.35), FakeItTheme.secondaryAccent.opacity(0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 22, x: 0, y: 12)
    }

    private var bottomCenterHUD: some View {
        HStack(spacing: 14) {
            Text("📍")
            VStack(alignment: .leading, spacing: 2) {
                Text(mapState.spoofHUDTitle)
                    .font(FakeItTheme.bodyFont(13, weight: .semibold))
                    .foregroundStyle(FakeItTheme.textPrimary)
                Text(mapState.coordinatePairString())
                    .font(FakeItTheme.bodyFont(11).monospacedDigit())
                    .foregroundStyle(FakeItTheme.textSecondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(
            Capsule(style: .continuous)
                .fill(FakeItTheme.card.opacity(0.92))
                .overlay(Capsule(style: .continuous).stroke(FakeItTheme.accent.opacity(0.22), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
        .frame(maxWidth: .infinity)
    }

    private func refreshDevices() {
        let result = DeviceService.listPhysicalDevices()
        devices = result.devices
        if devices.isEmpty {
            deviceBanner = "Connect your iPhone via USB and enable Developer Mode."
            selectedDevice = nil
        } else {
            deviceBanner = nil
            if selectedDevice == nil || !devices.contains(where: { $0.udid == selectedDevice?.udid }) {
                selectedDevice = devices.first
            }
            if devices.contains(where: { $0.prefersDVTLocationCLI }) {
                DeviceService.ensureTunneldRunningForIOS17Support()
            }
        }
    }

    private func selectSearchCompletion(at index: Int) {
        guard search.completions.indices.contains(index) else { return }
        selectedCompletionIndex = index
        let item = search.completions[index]
        let combined = [item.title, item.subtitle].filter { !$0.isEmpty }.joined(separator: " ")
        skipNextSearchQueryReaction = true
        search.queryFragment = combined.isEmpty ? item.title : combined
        searchExpanded = false
        mapState.invalidateSimulationUnlock()
    }

    private func goToLocation() {
        let q = search.queryFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty || (selectedCompletionIndex != nil && search.completions.indices.contains(selectedCompletionIndex!)) else { return }

        isGoingToLocation = true
        searchExpanded = false

        func finishFly(_ item: MKMapItem) {
            flyToPlacemark(item)
            selectedCompletionIndex = nil
            isGoingToLocation = false
        }

        func failFly() {
            isGoingToLocation = false
            searchExpanded = true
        }

        if let idx = selectedCompletionIndex, search.completions.indices.contains(idx) {
            let completion = search.completions[idx]
            search.resolve(completion) { res in
                DispatchQueue.main.async {
                    switch res {
                    case let .success(item):
                        finishFly(item)
                    case .failure:
                        let joined = [completion.title, completion.subtitle].filter { !$0.isEmpty }.joined(separator: " ")
                        if !joined.isEmpty {
                            search.searchNaturalLanguage(query: joined, biasRegion: mapState.visibleMapRegion) { nl in
                                DispatchQueue.main.async {
                                    if case let .success(item) = nl {
                                        finishFly(item)
                                    } else {
                                        failFly()
                                    }
                                }
                            }
                        } else {
                            failFly()
                        }
                    }
                }
            }
        } else if !q.isEmpty {
            search.searchNaturalLanguage(query: q, biasRegion: mapState.visibleMapRegion) { res in
                DispatchQueue.main.async {
                    switch res {
                    case let .success(item):
                        finishFly(item)
                    case .failure:
                        failFly()
                    }
                }
            }
        } else {
            isGoingToLocation = false
        }
    }

    private func flyToPlacemark(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(c) else { return }
        mapState.addressLine = SearchCompleterModel.displayTitle(for: item)
        mapState.setSelectedCoordinate(c, fly: true, dropAnimation: true, unlockSimulation: true)
        skipNextSearchQueryReaction = true
        search.queryFragment = ""
        searchExpanded = false
    }

    private func applyManualCoordinates() {
        guard let lat = Double(latText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(lonText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (-90 ... 90).contains(lat), (-180 ... 180).contains(lon) else { return }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        mapState.setSelectedCoordinate(c, fly: true, dropAnimation: true, unlockSimulation: true)
    }

    private func reapplyRecent(_ item: SavedSpoofLocation) {
        let c = CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude)
        mapState.addressLine = item.name
        mapState.setSelectedCoordinate(c, fly: true, dropAnimation: true, unlockSimulation: true)
        skipNextSearchQueryReaction = true
        search.queryFragment = ""
        selectedCompletionIndex = nil
    }

    private func performSpoof(using deviceOverride: ConnectedDevice? = nil) {
        let dev = deviceOverride ?? selectedDevice
        guard let coord = mapState.selectedCoordinate, let dev else {
            spoofPhase = .failure("Select a device and a map pin.")
            lastInjectionError = "Select a device and a map pin."
            return
        }
        guard mapState.allowSimulateAtPin else {
            spoofPhase = .failure("Go to location first")
            lastInjectionError = "Use “Go to location”, coordinates, or tap the map to place the pin, then simulate."
            return
        }

        spoofPhase = .injecting
        lastInjectionError = ""

        Task.detached(priority: .userInitiated) {
            let r = DeviceService.injectLocation(latitude: coord.latitude, longitude: coord.longitude, device: dev)
            await MainActor.run {
                if r.exitCode == 0 {
                    spoofPhase = .success
                    mapState.isSpoofActive = true
                    mapState.spoofHUDTitle = mapState.addressLine == "—" ? "Spoofed location" : mapState.addressLine
                    mapState.pinSuccessGlow = true
                    showParticles = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        showParticles = false
                    }
                    let entry = SavedSpoofLocation(
                        name: mapState.spoofHUDTitle,
                        latitude: coord.latitude,
                        longitude: coord.longitude
                    )
                    historyStore.prepend(entry)
                    recent = historyStore.load()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        spoofPhase = .idle
                        mapState.pinSuccessGlow = false
                    }
                } else {
                    let msg = r.stderr.isEmpty ? r.stdout : r.stderr
                    lastInjectionError = String(msg.prefix(900))
                    spoofPhase = .failure("Injection failed")
                }
            }
        }
    }

    private func runReset() {
        guard let dev = selectedDevice else { return }
        spoofPhase = .injecting
        Task.detached(priority: .userInitiated) {
            let r = DeviceService.resetLocation(device: dev)
            await MainActor.run {
                if r.exitCode == 0 {
                    mapState.isSpoofActive = false
                    mapState.spoofHUDTitle = "Real Location"
                    mapState.pinSuccessGlow = false
                    spoofPhase = .idle
                } else {
                    let msg = r.stderr.isEmpty ? r.stdout : r.stderr
                    lastInjectionError = String(msg.prefix(900))
                    spoofPhase = .failure("Reset failed")
                }
            }
        }
    }
}

// MARK: - Pin card

private struct PinInfoFloatingCard: View {
    @ObservedObject var mapState: MapViewState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(mapState.addressLine)
                .font(FakeItTheme.bodyFont(12, weight: .semibold))
                .foregroundStyle(FakeItTheme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: 240, alignment: .leading)

            HStack(spacing: 8) {
                Text(mapState.coordinatePairString())
                    .font(FakeItTheme.bodyFont(11).monospacedDigit())
                    .foregroundStyle(FakeItTheme.textSecondary)
                Button {
                    mapState.copyCoordinatesToPasteboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FakeItTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Copy coordinates")
            }

            HStack(spacing: 6) {
                Text("Elevation")
                    .font(FakeItTheme.bodyFont(10))
                    .foregroundStyle(FakeItTheme.textSecondary)
                Text(mapState.elevationText)
                    .font(FakeItTheme.bodyFont(10).monospacedDigit())
                    .foregroundStyle(FakeItTheme.textPrimary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FakeItTheme.card.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(FakeItTheme.accent.opacity(0.35), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 8)
    }
}

// MARK: - Spoof button

private struct SpoofActionButton: View {
    @Binding var phase: SpoofButtonPhase
    var canSimulate: Bool
    var onSpoof: () -> Void
    var onResetIdle: () -> Void

    private var isInjecting: Bool {
        if case .injecting = phase { return true }
        return false
    }

    private var idleDisabled: Bool {
        if case .idle = phase { return !canSimulate }
        return false
    }

    var body: some View {
        Button(action: {
            if case .failure = phase {
                onResetIdle()
            } else {
                onSpoof()
            }
        }) {
            HStack(spacing: 8) {
                switch phase {
                case .injecting:
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.85)
                        .tint(.white)
                    Text("Applying…")
                        .font(.system(size: 13, weight: .semibold))
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Active")
                        .font(.system(size: 13, weight: .semibold))
                case .failure:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Failed")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Tap to dismiss")
                            .font(.system(size: 10, weight: .medium))
                            .opacity(0.85)
                    }
                case .idle:
                    Image(systemName: idleDisabled ? "iphone.slash" : "iphone")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Simulate on device")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .opacity(idleDisabled ? 0.5 : 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(phaseBackgroundStyle)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isInjecting || idleDisabled)
    }

    private var phaseBackgroundStyle: AnyShapeStyle {
        switch phase {
        case .idle:
            if idleDisabled {
                return AnyShapeStyle(Color.primary.opacity(0.28))
            }
            return AnyShapeStyle(
                LinearGradient(
                    colors: [FakeItTheme.accent, FakeItTheme.accent.opacity(0.82)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .injecting:
            return AnyShapeStyle(Color.primary.opacity(0.35))
        case .success:
            return AnyShapeStyle(Color(red: 0.18, green: 0.62, blue: 0.38))
        case .failure:
            return AnyShapeStyle(Color.red.opacity(0.78))
        }
    }
}

// MARK: - Particles

private struct ParticleBurstView: View {
    var isActive: Bool

    var body: some View {
        ZStack {
            if isActive {
                ForEach(0..<14, id: \.self) { i in
                    let angle = Double(i) / 14.0 * Double.pi * 2
                    Circle()
                        .fill(i % 2 == 0 ? FakeItTheme.accent : FakeItTheme.secondaryAccent)
                        .frame(width: 4, height: 4)
                        .offset(x: cos(angle) * 52, y: sin(angle) * 52 - 24)
                        .opacity(0.95)
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.45), value: isActive)
    }
}
