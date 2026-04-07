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
    @State private var uiVisible = false
    @State private var searchExpanded = false
    @State private var recent: [SavedSpoofLocation] = []
    @State private var searchHistory: [SavedSpoofLocation] = []
    @State private var lastInjectionError: String = ""
    @State private var deviceRefreshTimer: Timer?
    @State private var tunneldNotice: String?
    @State private var selectedCompletionIndex: Int?
    @State private var isGoingToLocation = false
    /// Skips one `queryFragment` onChange so picking a suggestion doesn’t clear the selection.
    @State private var skipNextSearchQueryReaction = false

    private let historyStore = LocationHistoryStore()
    private let searchHistoryStore = LocationHistoryStore(key: "fakeit.searchHistory")

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

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    leftGlassPanel
                        .frame(width: 360)
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
        .frame(minWidth: 920, idealWidth: 1240, minHeight: 580, idealHeight: 800)
        .background(FakeItTheme.background)
        .opacity(uiVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.4), value: uiVisible)
        .onAppear {
            refreshDevices()
            recent = historyStore.load()
            searchHistory = searchHistoryStore.load()
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("FakeIt")
                        .font(FakeItTheme.brandTitleFont(22))
                        .foregroundStyle(FakeItTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Simulated location for development")
                        .font(FakeItTheme.bodyFont(11, weight: .regular))
                        .foregroundStyle(FakeItTheme.textSecondary.opacity(0.85))
                }

                if let banner = deviceBanner {
                    Text(banner)
                        .font(FakeItTheme.bodyFont(12, weight: .medium))
                        .foregroundStyle(Color.orange.opacity(0.92))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.orange.opacity(0.22), lineWidth: 1))
                }

                if let tunnel = tunneldNotice {
                    HStack(alignment: .top, spacing: 10) {
                        Text(tunnel)
                            .font(FakeItTheme.bodyFont(11, weight: .medium))
                            .foregroundStyle(Color(red: 0.95, green: 0.82, blue: 0.45))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            tunneldNotice = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.white.opacity(0.45))
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.yellow.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.yellow.opacity(0.2), lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 8) {
                    panelSectionLabel("Device")
                    Picker(selection: $selectedDevice) {
                        Text("No iPhone selected").tag(Optional<ConnectedDevice>.none)
                        ForEach(devices) { d in
                            Text(d.name).tag(Optional(d))
                        }
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(FakeItTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FakeItTheme.panelStroke, lineWidth: 1))
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    searchSection
                    searchHistorySection
                    coordinateSection
                    recentSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 12) {
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
                        .multilineTextAlignment(.leading)
                        .lineLimit(12)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 14)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FakeItTheme.panelSurface.opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FakeItTheme.panelStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 14)
    }

    private var canClearSearch: Bool {
        let q = search.queryFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        return !q.isEmpty || selectedCompletionIndex != nil || !search.completions.isEmpty
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                panelSectionLabel("Search")
                Spacer(minLength: 8)
                Button("Clear search") {
                    clearSearchQuery()
                }
                .font(FakeItTheme.bodyFont(11, weight: .semibold))
                .foregroundStyle(FakeItTheme.actionBlue)
                .buttonStyle(.plain)
                .disabled(!canClearSearch)
                .opacity(canClearSearch ? 1 : 0.38)
            }

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
                    if canClearSearch {
                        Button {
                            clearSearchQuery()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.black.opacity(0.35))
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
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
                                        .fill(selectedCompletionIndex == index ? FakeItTheme.actionBlue.opacity(0.14) : Color.clear)
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
                .tint(FakeItTheme.actionBlue)
                .disabled(!canGoToLocation || isGoingToLocation)

                Text("Select a suggestion or enter an address, then go to the pin on the map. After that you can simulate on your iPhone.")
                    .font(FakeItTheme.bodyFont(10))
                    .foregroundStyle(FakeItTheme.textSecondary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var coordinateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $coordinateMode.animation(FakeItTheme.spring)) {
                Text("Coordinate input")
                    .font(FakeItTheme.bodyFont(12, weight: .semibold))
                    .foregroundStyle(FakeItTheme.textSecondary)
            }
            .toggleStyle(.switch)
            .tint(FakeItTheme.actionBlue)

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
                .tint(FakeItTheme.actionBlue)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var searchHistorySection: some View {
        if !searchHistory.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    panelSectionLabel("Search History")
                    Spacer(minLength: 8)
                    Button("Clear history") {
                        searchHistoryStore.clearAll()
                        searchHistory = []
                    }
                    .font(FakeItTheme.bodyFont(11, weight: .semibold))
                    .foregroundStyle(FakeItTheme.actionBlue)
                    .buttonStyle(.plain)
                }

                ForEach(searchHistory.prefix(5)) { item in
                    HStack(alignment: .center, spacing: 8) {
                        Button {
                            searchHistoryStore.remove(id: item.id)
                            searchHistory = searchHistoryStore.load()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(FakeItTheme.textSecondary.opacity(0.5))
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from search history")

                        Button {
                            reapplySearchHistory(item)
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
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(FakeItTheme.textSecondary.opacity(0.55))
                            }
                            .padding(.vertical, 10)
                            .padding(.trailing, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 4)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FakeItTheme.panelStroke, lineWidth: 1))
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                panelSectionLabel("Recent")
                Spacer(minLength: 8)
                Button("Clear all") {
                    historyStore.clearAll()
                    recent = []
                }
                .font(FakeItTheme.bodyFont(11, weight: .semibold))
                .foregroundStyle(FakeItTheme.actionBlue)
                .buttonStyle(.plain)
                .disabled(recent.isEmpty)
                .opacity(recent.isEmpty ? 0.38 : 1)
            }
            if recent.isEmpty {
                Text("No spoof history yet.")
                    .font(FakeItTheme.bodyFont(11))
                    .foregroundStyle(FakeItTheme.textSecondary.opacity(0.8))
            } else {
                ForEach(recent.prefix(10)) { item in
                    HStack(alignment: .center, spacing: 8) {
                        Button {
                            historyStore.remove(id: item.id)
                            recent = historyStore.load()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(FakeItTheme.textSecondary.opacity(0.5))
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from history")

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
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(FakeItTheme.textSecondary.opacity(0.55))
                            }
                            .padding(.vertical, 10)
                            .padding(.trailing, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 4)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FakeItTheme.panelStroke, lineWidth: 1))
                }
            }
        }
    }

    private func clearSearchQuery() {
        search.clearSearch()
        searchExpanded = false
        selectedCompletionIndex = nil
        mapState.invalidateSimulationUnlock()
    }

    private func panelSectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(FakeItTheme.textSecondary.opacity(0.75))
    }

    private var bottomCenterHUD: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(FakeItTheme.textSecondary)
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
                .fill(FakeItTheme.panelSurface.opacity(0.95))
                .overlay(Capsule(style: .continuous).stroke(FakeItTheme.panelStroke, lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.2), radius: 14, x: 0, y: 6)
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
        let title = SearchCompleterModel.displayTitle(for: item)
        mapState.addressLine = title
        mapState.setSelectedCoordinate(c, fly: true, dropAnimation: true, unlockSimulation: true)
        searchHistoryStore.prepend(SavedSpoofLocation(name: title, latitude: c.latitude, longitude: c.longitude))
        searchHistory = searchHistoryStore.load()
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

    private func reapplySearchHistory(_ item: SavedSpoofLocation) {
        let c = CLLocationCoordinate2D(latitude: item.latitude, longitude: item.longitude)
        mapState.addressLine = item.name
        mapState.setSelectedCoordinate(c, fly: true, dropAnimation: true, unlockSimulation: true)
        searchHistoryStore.prepend(item)
        searchHistory = searchHistoryStore.load()
        skipNextSearchQueryReaction = true
        search.queryFragment = ""
        searchExpanded = false
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
                        .foregroundStyle(FakeItTheme.actionBlue)
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FakeItTheme.panelSurface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(FakeItTheme.panelStroke, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 6)
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
                return AnyShapeStyle(Color.white.opacity(0.12))
            }
            return AnyShapeStyle(FakeItTheme.actionBlue)
        case .injecting:
            return AnyShapeStyle(Color.primary.opacity(0.35))
        case .success:
            return AnyShapeStyle(Color(red: 0.18, green: 0.62, blue: 0.38))
        case .failure:
            return AnyShapeStyle(Color.red.opacity(0.78))
        }
    }
}
