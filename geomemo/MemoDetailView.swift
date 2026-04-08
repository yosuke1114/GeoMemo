import SwiftUI
import MapKit
import SwiftData
// Phosphor icons loaded from local Assets.xcassets

// Brand colors and Color(hex:) are defined in Theme.swift

struct MemoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let memo: GeoMemo
    
    @AppStorage("mapStyle") private var mapStyleRaw: String = GeoMapStyle.mono.rawValue
    @State private var showingEditSheet = false
    @State private var cameraPosition: MapCameraPosition

    private var currentMapStyle: GeoMapStyle {
        GeoMapStyle(rawValue: mapStyleRaw) ?? .mono
    }

    private var memoColor: Color {
        MemoColor(rawValue: memo.colorIndex)?.color ?? Brand.blue
    }
    
    init(memo: GeoMemo) {
        self.memo = memo
        _cameraPosition = State(initialValue: .camera(
            MapCamera(centerCoordinate: memo.coordinate, distance: 1000)
        ))
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Map Section (160px height)
                ZStack(alignment: .bottomLeading) {
                    Map(position: $cameraPosition, interactionModes: []) {
                        // Radius circle
                        MapCircle(center: CLLocationCoordinate2D(
                            latitude: memo.latitude,
                            longitude: memo.longitude),
                            radius: memo.radius)
                            .foregroundStyle(memoColor.opacity(0.08))
                            .stroke(memoColor, lineWidth: 1.5)
                        
                        // Center marker
                        Annotation("", coordinate: memo.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(memoColor)
                                    .frame(width: 12, height: 12)
                                Circle()
                                    .stroke(Brand.background, lineWidth: 2)
                                    .frame(width: 12, height: 12)
                            }
                        }
                    }
                    .mapStyle(currentMapStyle == .satellite
                        ? .imagery
                        : .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
                    .grayscale(currentMapStyle == .mono && colorScheme != .dark ? 1.0 : 0)
                    .id(mapStyleRaw)
                    .frame(height: 160)
                    
                    // Location Badge (Pill-shaped)
                    HStack(spacing: 4) {
                        Image("ph-map-pin-fill")
                            .resizable()
                            .frame(width: 14, height: 14)
                            .foregroundColor(Brand.blue)
                        Text(memo.locationName.isEmpty ? String(localized: "Unknown Location") : memo.locationName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Brand.primaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Brand.surface)
                    .cornerRadius(12)
                    .shadow(color: Brand.primaryText.opacity(0.1), radius: 4, x: 0, y: 2)
                    .padding(.leading, 16)
                    .padding(.bottom, 12)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(memo.locationName.isEmpty ? String(localized: "Unknown Location") : memo.locationName) map")
                
                // Content Section
                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    HStack(spacing: 8) {
                        if memo.colorIndex != 0 {
                            Circle()
                                .fill(memoColor)
                                .frame(width: 10, height: 10)
                        }
                        if memo.isFavorite {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Color(hex: "E5484D"))
                        }
                        Text(memo.title)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Brand.primaryText)
                        Spacer()
                    }
                    
                    // Note
                    if !memo.note.isEmpty {
                        Text(memo.note)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(Brand.primaryText)
                            .lineSpacing(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    // Attached Image (if exists)
                    if memo.imageData != nil {
                        AsyncImageView(imageData: memo.imageData, maxWidth: 800)
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Attached image")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                
                // Divider
                Rectangle()
                    .fill(Brand.primaryText.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                
                // Settings Section
                VStack(spacing: 0) {
                    // RADIUS Row
                    HStack {
                        Text("RADIUS")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Brand.tertiaryText)
                            .tracking(0.5)
                        
                        Spacer()
                        
                        Text(formatRadius(memo.radius))
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(Brand.tertiaryText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    
                    // ON ENTRY Row
                    HStack {
                        Text("ON ENTRY")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Brand.primaryText)
                            .tracking(0.5)
                        
                        Spacer()
                        
                        if memo.notifyOnEntry {
                            Image("ph-check-bold")
                                .resizable()
                                .frame(width: 18, height: 18)
                                .foregroundColor(Brand.blue)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    
                    // ON EXIT Row
                    HStack {
                        Text("ON EXIT")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Brand.primaryText)
                            .tracking(0.5)
                        
                        Spacer()
                        
                        if memo.notifyOnExit {
                            Image("ph-check-bold")
                                .resizable()
                                .frame(width: 18, height: 18)
                                .foregroundColor(Brand.blue)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                .padding(.top, 8)

                // Trigger Conditions Section
                if memo.deadline != nil || memo.timeWindowStart != nil || memo.activeDays != nil {
                    Rectangle()
                        .fill(Brand.primaryText.opacity(0.1))
                        .frame(height: 1)
                        .padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        HStack {
                            Text("TRIGGER CONDITIONS")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Brand.tertiaryText)
                                .tracking(0.5)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        // 期限
                        if let deadline = memo.deadline {
                            HStack {
                                Text("EXPIRY")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Brand.primaryText)
                                    .tracking(0.5)
                                Spacer()
                                Text(deadline, style: .date)
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundColor(Brand.tertiaryText)
                                    .environment(\.locale, .autoupdatingCurrent)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        // 時間帯
                        if let start = memo.timeWindowStart, let end = memo.timeWindowEnd {
                            HStack {
                                Text("TIME WINDOW")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Brand.primaryText)
                                    .tracking(0.5)
                                Spacer()
                                Text("\(String(format: "%02d:%02d", start / 60, start % 60)) 〜 \(String(format: "%02d:%02d", end / 60, end % 60))")
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundColor(Brand.tertiaryText)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        // 曜日
                        if let days = memo.activeDays {
                            HStack {
                                Text("DAYS")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Brand.primaryText)
                                    .tracking(0.5)
                                Spacer()
                                HStack(spacing: 6) {
                                    ForEach([
                                        (1, String(localized: "Mon")), (2, String(localized: "Tue")), (3, String(localized: "Wed")),
                                        (4, String(localized: "Thu")), (5, String(localized: "Fri")), (6, String(localized: "Sat")), (0, String(localized: "Sun"))
                                    ], id: \.0) { day, label in
                                        Text(label)
                                            .font(.system(size: 12, weight: .medium))
                                            .frame(width: 28, height: 28)
                                            .background(
                                                days.contains(day)
                                                    ? Brand.blue
                                                    : Brand.secondaryBackground
                                            )
                                            .foregroundColor(
                                                days.contains(day)
                                                    ? .white
                                                    : Brand.primaryText.opacity(0.4)
                                            )
                                            .cornerRadius(6)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                    }
                }
                
                Spacer(minLength: 40)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) {
                    Image("ph-arrow-left")
                        .resizable()
                        .frame(width: 18, height: 18)
                        .foregroundColor(Brand.primaryText)
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Button(action: {
                        HapticManager.impact(.light)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                            memo.isFavorite.toggle()
                        }
                    }) {
                        Image(systemName: memo.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 18))
                            .foregroundColor(memo.isFavorite ? Color(hex: "E5484D") : Brand.primaryText)
                            .scaleEffect(memo.isFavorite ? 1.15 : 1.0)
                    }
                    .accessibilityLabel(memo.isFavorite ? "Remove from favorites" : "Add to favorites")
                    Button(action: { showingEditSheet = true }) {
                        Text("EDIT")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Brand.blue)
                    }
                }
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            MemoEditorView(mode: MemoEditorMode.edit(memo), onDelete: {
                dismiss()
            })
        }
    }
    
    private func formatRadius(_ radius: Double) -> String {
        if radius >= 1000 {
            let km = radius / 1000
            return String(format: "%.1fKM", km)
        } else {
            return "\(Int(radius))M"
        }
    }
}

// MARK: - Async Image View (downsampled)

private struct AsyncImageView: View {
    let imageData: Data?
    let maxWidth: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Brand.subtleFill)
                    .overlay(ProgressView())
            }
        }
        .task {
            guard let data = imageData else { return }
            image = await downsample(data: data, maxWidth: maxWidth)
        }
    }

    private func downsample(data: Data, maxWidth: CGFloat) async -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return UIImage(data: data)
        }
        let scale = UIScreen.main.scale
        let maxPixelSize = maxWidth * scale
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        MemoDetailView(memo: GeoMemo(
            title: "Corner Coffee Thoughts",
            note: "The way the light hits the brick wall at 8:45am is something else. It creates these long, rhythmic shadows that make the alley feel twice as deep.",
            latitude: 35.6585,
            longitude: 139.7454,
            radius: 100,
            locationName: "SHIBUYA, TOKYO",
            deadline: Calendar.current.date(byAdding: .day, value: 7, to: Date()),
            timeWindowStart: 600,
            timeWindowEnd: 1200,
            activeDays: [1, 2, 3, 4, 5]
        ))
    }
}
