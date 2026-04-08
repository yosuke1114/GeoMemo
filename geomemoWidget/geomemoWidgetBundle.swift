import WidgetKit
import SwiftUI

@main
struct geomemoWidgetBundle: WidgetBundle {
    var body: some Widget {
        geomemoWidget()
        GeoMemoLiveActivity()
    }
}
