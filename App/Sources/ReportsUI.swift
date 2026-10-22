import MapLibre
import SwiftUI

extension ReportType {
    /// The Theme colour for `colorToken`; each dark enough for a white icon (>= 3:1).
    var color: Color {
        Theme.reportColors[colorToken] ?? Theme.accentFill
    }
}

/// Words for a failed post or vote, for the toast.
func reportProblem(_ error: Error) -> String {
    switch error as? ReportsError {
    case .rateLimited: String(localized: "You've sent a lot of reports this hour. Try again later.")
    case .notConfigured: String(localized: "Reports aren't available in this build.")
    case .noDeviceID: String(localized: "Unlock your phone to send reports.")
    case .conflict: String(localized: "You've already voted on this report.")
    case .notFound: String(localized: "That report has already cleared.")
    default: String(localized: "Couldn't send the report. Check your connection.")
    }
}

/// "Reported 5 minutes ago · 3 still there · 1 gone", for the map callout.
func reportDetail(_ report: Report, now: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    let age = formatter.localizedString(for: min(report.createdAt, now), relativeTo: now)
    return String(localized: "Reported \(age) · \(report.upvotes) still there · \(report.downvotes) gone")
}

/// Short message at the top of the map that clears itself.
struct Toast: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Space.large)
            .padding(.vertical, Theme.Space.medium)
            .background(Theme.danger, in: Capsule())
            .shadow(color: Theme.shadow, radius: 10, y: 4)
            .padding(.horizontal, Theme.Space.large)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// "Police still there?" while driving towards a crowd report.
struct StillThereCard: View {
    let report: Report
    let onAnswer: (Bool) -> Void
    @Scaled private var disc: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.medium) {
            HStack(spacing: Theme.Space.medium) {
                Image(systemName: report.type.symbol)
                    .font(.system(size: disc * 0.44, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: disc, height: disc)
                    .background(report.type.color, in: Circle())
                    .accessibilityHidden(true)
                Text("\(report.type.title) still there?")
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: Theme.Space.medium) {
                Button { onAnswer(false) } label: { Text("Gone") }
                    .buttonStyle(PrimaryButtonStyle(fill: Theme.neutralFill))
                Button { onAnswer(true) } label: { Text("Still there") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(Theme.Space.large)
        .card()
        .padding(.horizontal, Theme.Space.medium)
    }
}

/// A report on the map; the callout shows its type, age and votes.
final class ReportAnnotation: MLNPointAnnotation {
    var report: Report

    init(_ report: Report) {
        self.report = report
        super.init()
        coordinate = report.coordinate
        title = report.type.title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }
}

extension MapView.Coordinator {
    func sync(reports: [Report], onRegion: @escaping (BBox) -> Void, on map: MLNMapView) {
        self.onRegion = onRegion
        guard reports != self.reports else { return }
        self.reports = reports
        showReports(reports, on: map)
    }

    /// Adds, updates and removes report annotations to match `reports`.
    func showReports(_ reports: [Report], on map: MLNMapView) {
        let wanted = Dictionary(reports.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = (map.annotations ?? []).compactMap { $0 as? ReportAnnotation }
        var seen: Set<String> = []
        for annotation in current {
            if let report = wanted[annotation.report.id] {
                annotation.report = report
                seen.insert(report.id)
            } else {
                map.removeAnnotation(annotation)
            }
        }
        map.addAnnotations(reports.filter { !seen.contains($0.id) }.map(ReportAnnotation.init))
    }

    func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
        guard let annotation = annotation as? ReportAnnotation else { return nil }
        let type = annotation.report.type
        let id = "report.\(type.rawValue)"
        if let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
            return view
        }
        let view = MLNAnnotationView(reuseIdentifier: id)
        let size: CGFloat = 36
        view.frame = CGRect(x: 0, y: 0, width: size, height: size)
        view.backgroundColor = UIColor(type.color)
        view.layer.cornerRadius = size / 2
        view.layer.borderColor = UIColor.white.cgColor
        view.layer.borderWidth = 2
        let icon = UIImageView(image: UIImage(
            systemName: type.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        ))
        icon.tintColor = .white
        icon.frame = view.bounds.insetBy(dx: 7, dy: 7)
        icon.contentMode = .scaleAspectFit
        view.addSubview(icon)
        view.isAccessibilityElement = true
        view.accessibilityLabel = type.title
        return view
    }

    func mapView(_: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
        guard let annotation = annotation as? ReportAnnotation else { return false }
        annotation.subtitle = reportDetail(annotation.report) // age as of the tap
        return true
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated _: Bool) {
        let bounds = mapView.visibleCoordinateBounds
        onRegion(BBox(minLat: bounds.sw.latitude, minLng: bounds.sw.longitude,
                      maxLat: bounds.ne.latitude, maxLng: bounds.ne.longitude))
    }
}
