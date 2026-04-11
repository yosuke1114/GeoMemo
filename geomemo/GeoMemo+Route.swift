import Foundation

extension GeoMemo {
    var routeWaypoints: [RouteWaypoint] {
        guard let data = waypointData else { return [] }
        return (try? JSONDecoder().decode([RouteWaypoint].self, from: data)) ?? []
    }
}
