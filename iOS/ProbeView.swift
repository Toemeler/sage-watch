import SwiftUI
import Charts

/// One point of a probe chart.
struct ProbePoint: Identifiable {
    let id: Int
    let t: Date
    let v: Double
}

/// The data lab (test build): everything the watch's probe sends, live and recorded.
struct ProbeView: View {
    @ObservedObject private var store = ProbeStore.shared
    @ObservedObject private var receiver = Receiver.shared

    var body: some View {
        NavigationStack {
            List {
                controlSection
                if !store.wave.isEmpty { waveSection }
                ForEach(store.groups, id: \.self) { g in
                    groupSection(g)
                }
                filesSection
            }
            .navigationTitle("Data lab")
            .refreshable { receiver.reload() }
            .onAppear { receiver.reload() }
        }
    }

    // MARK: control

    private var controlSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                liveRow(now: tl.date)
            }
            if !receiver.watchPaired || !receiver.watchAppInstalled {
                Text(receiver.watchPaired ? "The watch app is not installed (Watch app › Available Apps)." : "No paired watch found yet.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Button("Open on the watch and start") { store.startOnWatch() }
            HStack {
                Button("Start") { store.send(ProbeLink.start) }.buttonStyle(.bordered)
                Button("Stop") { store.send(ProbeLink.stop) }.buttonStyle(.bordered)
                Button("Send files") { store.send(ProbeLink.ship) }.buttonStyle(.bordered)
                Button("Status") { store.send(ProbeLink.status) }.buttonStyle(.bordered)
            }
            .font(.footnote)
            if let s = store.status {
                Text(s).font(.footnote).foregroundStyle(Theme.muted)
            }
            if let url = store.logFile {
                ShareLink(item: url) {
                    Label("Live log · \(ByteCountFormatter.string(fromByteCount: store.logBytes, countStyle: .file))",
                          systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Watch probe")
        } footer: {
            Text("The probe records every sensor and Health type the watch has. Live values arrive once a second while the watch is near and are logged on this iPhone; the files arrive every 2 minutes and are listed below (also in Files › On My iPhone › Sage).")
        }
    }

    private func liveRow(now: Date) -> some View {
        let age: Double? = store.lastSnapshot.map { now.timeIntervalSince($0) }
        let live: Bool = (age ?? 99) < 3
        let text: String
        if let age {
            text = live ? "Live · \(store.snapshots) snapshots" : "Last snapshot \(Int(age)) s ago"
        } else {
            text = "No live data yet"
        }
        return HStack {
            Circle().fill(live ? Theme.sage : Theme.muted).frame(width: 8, height: 8)
            Text(text).foregroundStyle(Theme.ivory)
            Spacer()
            if let since = store.watchSince {
                Text("since \(since.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: live values

    private var waveSection: some View {
        Section {
            let points: [ProbePoint] = store.wave.enumerated().map { ProbePoint(id: $0.offset, t: Date(timeIntervalSince1970: Double($0.offset) / 50), v: Double($0.element)) }
            Chart(points) { p in
                LineMark(x: .value("Sample", p.id), y: .value("g", p.v))
                    .foregroundStyle(Theme.sage)
            }
            .chartXAxis(.hidden)
            .frame(height: 140)
        } header: {
            Text("Wrist acceleration |a| · last 10 s at 50 Hz")
        }
    }

    private func groupSection(_ g: String) -> some View {
        Section {
            ForEach(store.keys(in: g), id: \.self) { key in
                valueRow(key)
            }
        } header: {
            Text(ProbeStore.groupTitle(g))
        }
    }

    @ViewBuilder private func valueRow(_ key: String) -> some View {
        let value: ProbeValue? = store.latest[key]
        let unit: String = store.units[key] ?? ""
        let shown: String = unit.isEmpty ? (value?.display ?? "–") : "\(value?.display ?? "–") \(unit)"
        let label = HStack {
            Text(ProbeStore.label(of: key)).foregroundStyle(Theme.ivory)
            Spacer()
            Text(shown)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.muted)
        }
        if value?.number != nil {
            NavigationLink { ProbeKeyChart(key: key) } label: { label }
        } else {
            label
        }
    }

    // MARK: recorded files

    private var filesSection: some View {
        let probes: [Segment] = receiver.segments.filter { $0.id.hasPrefix(ProbeFormat.segmentPrefix) }
        return Section {
            if probes.isEmpty {
                Text("No probe files yet. They arrive every 2 minutes while the probe runs, or tap Send files.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            ForEach(probes) { seg in
                NavigationLink {
                    ProbeSegmentView(segment: seg)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(seg.title).foregroundStyle(Theme.ivory)
                        Text(seg.detail).font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { receiver.delete(seg) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        } header: {
            Text("Recorded on this iPhone")
        } footer: {
            if let t = receiver.lastReceived {
                Text("Last file \(t.formatted(date: .omitted, time: .standard))")
            }
        }
    }
}

/// The live history of one value (up to 15 min, one point a second).
struct ProbeKeyChart: View {
    let key: String
    @ObservedObject private var store = ProbeStore.shared

    var body: some View {
        let history: [(Date, Double)] = store.history[key] ?? []
        let points: [ProbePoint] = history.enumerated().map { ProbePoint(id: $0.offset, t: $0.element.0, v: $0.element.1) }
        let unit: String = store.units[key] ?? ""
        List {
            Section {
                Chart(points) { p in
                    LineMark(x: .value("Time", p.t), y: .value(unit.isEmpty ? "Value" : unit, p.v))
                        .foregroundStyle(Theme.sage)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 260)
            } footer: {
                Text("\(points.count) points since the Lab tab started receiving (refreshes every second).")
            }
            if let last = points.last {
                Section {
                    row("Now", String(format: "%.4f", last.v))
                    row("Min", String(format: "%.4f", points.map(\.v).min() ?? 0))
                    row("Max", String(format: "%.4f", points.map(\.v).max() ?? 0))
                }
            }
        }
        .navigationTitle(ProbeStore.label(of: key))
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a); Spacer(); Text(b).font(.system(.body, design: .monospaced)).foregroundStyle(Theme.muted) }
    }
}

/// One probe run as recorded on the iPhone: its streams and the watch's description of itself.
struct ProbeSegmentView: View {
    struct StreamInfo: Identifiable {
        let id: String
        let files: Int
        let bytes: Int64
    }

    struct MetaRow: Identifiable {
        let id: String
        let value: String
    }

    let segment: Segment
    @State private var streams: [StreamInfo] = []
    @State private var metaRows: [MetaRow] = []
    @State private var zipURL: URL?
    @State private var zipError: String?

    private var dir: URL { Receiver.root.appendingPathComponent(segment.id, isDirectory: true) }

    var body: some View {
        List {
            Section {
                if let url = zipURL {
                    ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") }
                } else {
                    Button("Zip this run to share") {
                        do { zipURL = try Receiver.zip(segment) } catch { zipError = error.localizedDescription }
                    }
                }
                if let e = zipError { Text(e).font(.footnote).foregroundStyle(.red) }
            }
            Section("Streams") {
                if streams.isEmpty { Text("No CSV files yet.").foregroundStyle(Theme.muted) }
                ForEach(streams) { s in
                    NavigationLink {
                        ProbeStreamView(dir: dir, stream: s.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ProbeFormat.title(of: s.id)).foregroundStyle(Theme.ivory)
                            Text("\(s.files) files · \(ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file))")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            Section("Watch") {
                ForEach(metaRows) { r in
                    HStack {
                        Text(r.id).font(.footnote)
                        Spacer()
                        Text(r.value).font(.footnote).foregroundStyle(Theme.muted).multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .navigationTitle(segment.title)
        .onAppear(perform: load)
    }

    private static func rows(of meta: [String: Any]) -> [MetaRow] {
        var rows: [MetaRow] = []
        for key in meta.keys.sorted() {
            let v = meta[key]
            if let d = v as? [String: Any] {
                for k in d.keys.sorted() {
                    let on: Bool = (d[k] as? Bool) ?? ((d[k] as? NSNumber)?.boolValue ?? false)
                    rows.append(MetaRow(id: "sensor \(k)", value: on ? "yes" : "no"))
                }
            } else if let list = v as? [String] {
                rows.append(MetaRow(id: key, value: list.isEmpty ? "none" : list.joined(separator: "\n")))
            } else if let v {
                rows.append(MetaRow(id: key, value: "\(v)"))
            }
        }
        return rows
    }

    private func load() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var files: [String: Int] = [:]
        var bytes: [String: Int64] = [:]
        for n in names {
            guard let s = RecordingFormat.stream(ofFile: n) else { continue }
            files[s, default: 0] += 1
            let size = ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent(n).path))?[.size] as? NSNumber)?.int64Value ?? 0
            bytes[s, default: 0] += size
        }
        let order = ProbeFormat.all
        let sortedKeys = files.keys.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
        streams = sortedKeys.map { StreamInfo(id: $0, files: files[$0] ?? 0, bytes: bytes[$0] ?? 0) }
        metaRows = Self.rows(of: Receiver.meta(in: dir))
    }
}

/// One stream: a chart of any column and the newest rows.
struct ProbeStreamView: View {
    let dir: URL
    let stream: String
    @State private var data: ProbeStreamData?
    @State private var column = 1

    var body: some View {
        List {
            if let d = data {
                summary(d)
                if stream == ProbeFormat.health {
                    healthTypes(d)
                } else if !d.numericColumns.isEmpty {
                    chart(d)
                }
                newest(d)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(ProbeFormat.title(of: stream))
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        let dir = self.dir, stream = self.stream
        let loaded = await Task.detached(priority: .userInitiated) { ProbeStreamData.load(segment: dir, stream: stream) }.value
        data = loaded
        if let first = loaded.numericColumns.first, !loaded.numericColumns.contains(column) { column = first }
    }

    private static func time(_ row: [String]?) -> Double? {
        guard let s = row?.first else { return nil }
        return Double(s)
    }

    private func summary(_ d: ProbeStreamData) -> some View {
        Section {
            HStack { Text("Lines read"); Spacer(); Text(d.totalLines.formatted()).foregroundStyle(Theme.muted) }
            HStack { Text("On disk"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: d.bytes, countStyle: .file)).foregroundStyle(Theme.muted) }
            if let first = Self.time(d.rows.first), let last = Self.time(d.rows.last) {
                let span: Double = last - first
                let rate: Double = span > 0 ? Double(d.rows.count) / span : 0
                HStack { Text("Rate"); Spacer(); Text(String(format: "%.1f lines/s over %.0f s", rate, span)).foregroundStyle(Theme.muted) }
            }
        } footer: {
            Text("Large streams: only the newest ~12 MB are read here. Every line is in the files and the Data tab's export.")
        }
    }

    private func chart(_ d: ProbeStreamData) -> some View {
        let series = d.series(column: column)
        let points: [ProbePoint] = series.enumerated().map { ProbePoint(id: $0.offset, t: $0.element.0, v: $0.element.1) }
        let name = column < d.columns.count ? d.columns[column] : "value"
        return Section {
            Picker("Column", selection: $column) {
                ForEach(d.numericColumns, id: \.self) { i in
                    Text(i < d.columns.count ? d.columns[i] : "col \(i)").tag(i)
                }
            }
            Chart(points) { p in
                LineMark(x: .value("Time", p.t), y: .value(name, p.v))
                    .foregroundStyle(Theme.sage)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 240)
        } footer: {
            Text("\(points.count) of \(d.rows.count) rows drawn")
        }
    }

    /// the Health stream holds many types: one row per type with its count and newest value
    private func healthTypes(_ d: ProbeStreamData) -> some View {
        var byType: [String: (count: Int, last: String, unit: String)] = [:]
        for r in d.rows where r.count >= 5 {
            let prev = byType[r[2]]
            byType[r[2]] = ((prev?.count ?? 0) + 1, r[3], r[4])
        }
        let types = byType.keys.sorted()
        return Section("Types (\(types.count))") {
            ForEach(types, id: \.self) { t in
                let e = byType[t]
                HStack {
                    Text(t).font(.footnote)
                    Spacer()
                    Text("\(e?.count ?? 0) · \(e?.last ?? "") \(e?.unit ?? "")")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func newest(_ d: ProbeStreamData) -> some View {
        let rows = Array(d.rows.suffix(40).reversed())
        return Section {
            Text(d.columns.joined(separator: ", "))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.sage)
            ForEach(Array(rows.enumerated()), id: \.offset) { item in
                Text(item.element.joined(separator: ", "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.ivory)
            }
        } header: {
            Text("Newest rows")
        }
    }
}
