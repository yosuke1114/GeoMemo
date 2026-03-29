import SwiftUI
import MapKit
import SwiftData
// Phosphor icons loaded from local Assets.xcassets

// MARK: - Brand Colors
private enum Brand {
    static let white = Color.white
    static let black = Color(hex: "1A1A1A")
    static let blue = Color(hex: "3D3BF3")
    static let lightGray = Color(hex: "F5F5F5")
    static let textGray = Color.black.opacity(0.5)
}

// MARK: - Color Extension
private extension Color {
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hexSanitized.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 255, 255, 255)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

struct MemoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let memo: GeoMemo
    
    @State private var showingEditSheet = false
    @State private var cameraPosition: MapCameraPosition
    
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
                            .foregroundStyle(
                                Color(red: 0.24, green: 0.23, blue: 0.95)
                                    .opacity(0.08)
                            )
                            .stroke(
                                Color(red: 0.24, green: 0.23, blue: 0.95),
                                lineWidth: 1.5
                            )
                        
                        // Center marker
                        Annotation("", coordinate: memo.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(Brand.black)
                                    .frame(width: 12, height: 12)
                                Circle()
                                    .stroke(Brand.white, lineWidth: 2)
                                    .frame(width: 12, height: 12)
                            }
                        }
                    }
                    .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
                    .grayscale(1.0)
                    .frame(height: 160)
                    
                    // Location Badge (Pill-shaped)
                    HStack(spacing: 4) {
                        Image("ph-map-pin-fill")
                            .resizable()
                            .frame(width: 14, height: 14)
                            .foregroundColor(Brand.blue)
                        Text(memo.locationName.isEmpty ? "Unknown Location" : memo.locationName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Brand.black)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Brand.white)
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                    .padding(.leading, 16)
                    .padding(.bottom, 12)
                }
                
                // Content Section
                VStack(alignment: .leading, spacing: 16) {
                    // Title
                    Text(memo.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Brand.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Note
                    if !memo.note.isEmpty {
                        Text(memo.note)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(Brand.black)
                            .lineSpacing(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    // Attached Image (if exists)
                    if let imageData = memo.imageData, let uiImage = UIImage(data: imageData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                
                // Divider
                Rectangle()
                    .fill(Brand.black.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                
                // Settings Section
                VStack(spacing: 0) {
                    // RADIUS Row
                    HStack {
                        Text("RADIUS")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Brand.textGray)
                            .tracking(0.5)
                        
                        Spacer()
                        
                        Text(formatRadius(memo.radius))
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(Brand.textGray)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    
                    // ON ENTRY Row
                    HStack {
                        Text("ON ENTRY")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Brand.black)
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
                            .foregroundColor(Brand.black)
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
                        .fill(Brand.black.opacity(0.1))
                        .frame(height: 1)
                        .padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        HStack {
                            Text("TRIGGER CONDITIONS")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Brand.textGray)
                                .tracking(0.5)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        // 期限
                        if let deadline = memo.deadline {
                            HStack {
                                Text("期限 (EXPIRY)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Brand.black)
                                    .tracking(0.5)
                                Spacer()
                                Text(deadline, style: .date)
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundColor(Brand.textGray)
                                    .environment(\.locale, Locale(identifier: "ja_JP"))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        // 時間帯
                        if let start = memo.timeWindowStart, let end = memo.timeWindowEnd {
                            HStack {
                                Text("時間帯 (TIME)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Brand.black)
                                    .tracking(0.5)
                                Spacer()
                                Text("\(String(format: "%02d:%02d", start / 60, start % 60)) 〜 \(String(format: "%02d:%02d", end / 60, end % 60))")
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundColor(Brand.textGray)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        // 曜日
                        if let days = memo.activeDays {
                            HStack {
                                Text("曜日 (DAYS)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Brand.black)
                                    .tracking(0.5)
                                Spacer()
                                HStack(spacing: 6) {
                                    ForEach([
                                        (1, "月"), (2, "火"), (3, "水"),
                                        (4, "木"), (5, "金"), (6, "土"), (0, "日")
                                    ], id: \.0) { day, label in
                                        Text(label)
                                            .font(.system(size: 12, weight: .medium))
                                            .frame(width: 28, height: 28)
                                            .background(
                                                days.contains(day)
                                                    ? Brand.blue
                                                    : Brand.lightGray
                                            )
                                            .foregroundColor(
                                                days.contains(day)
                                                    ? .white
                                                    : Brand.black.opacity(0.4)
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
                        .foregroundColor(Brand.black)
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingEditSheet = true }) {
                    Text("EDIT")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Brand.blue)
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
