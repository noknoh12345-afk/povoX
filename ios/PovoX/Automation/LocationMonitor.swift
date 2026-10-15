import CoreLocation
import Foundation

/// 位置情報で「常に取得」を強くする。
///
/// iOS はアプリを常には動かせないが、位置が大きく動いたとき・ある場所に着いた/出たときは、
/// アプリが閉じていても(必要なら起動し直してでも)知らせてくれる。それを合図に残量チェックを回す。
/// 権限は「常に許可」が要る。位置の値そのものは使わず、povo にも送らない(起こされる合図としてだけ使う)。
/// 追加の署名(権限)は不要なので、無料の Apple ID でも使える。Mac・LiveContainer では動かない。
final class LocationMonitor: NSObject, CLLocationManagerDelegate {
    /// 位置の変化で起こされたときに呼ぶ(自動チェックを回す)。
    var onWake: ((String) async -> Void)?

    private let manager = CLLocationManager()
    private var enabled = false

    override init() {
        super.init()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
        // 街区レベルで十分(細かい位置は要らない。電池も節約)。
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    var authorization: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    /// 「常に許可」を求める。まず「使用中」を聞き、許可されたら「常に」に上げる(iOS の作法)。
    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// 監視を始める/やめる。実機でだけ動く。
    func setEnabled(_ on: Bool) {
        guard !Runtime.onMac, !Runtime.inLiveContainer, CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        enabled = on
        if on {
            requestAuthorization()
            start()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
        }
    }

    private func start() {
        guard enabled else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            // 大きな移動と「立ち寄り」の両方を監視する(どちらも閉じていても起こされる)。
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
        case .authorizedWhenInUse:
            // 「常に」でないと背面では起こされないが、前面にいる間は大きな移動で拾える。
            manager.startMonitoringSignificantLocationChanges()
        default:
            break
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse:
            // 使用中が取れたら、常時へ引き上げを頼む。
            manager.requestAlwaysAuthorization()
            start()
        case .authorizedAlways:
            start()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        wake("location")
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // 到着(departure が未来)か出発かで分ける。
        let trigger = visit.departureDate == Date.distantFuture ? "location-arrive" : "location-leave"
        wake(trigger)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 位置が取れないのは普通に起きる(電波・権限)。黙って見送る。
    }

    private func wake(_ trigger: String) {
        guard let onWake else { return }
        Task { await onWake(trigger) }
    }
}
