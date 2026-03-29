import SwiftUI

struct GeoMemoIconView: View {
    let size: CGFloat

    var body: some View {
        Image("AppIconSymbol")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}
