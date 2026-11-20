//
//  AppDelegate.swift
//
//  Foreground-only by design.
//
//  iOS kills background sockets, and keeping one alive would need either a VoIP
//  push abuse or a relay server with an APNs certificate. Neither fits "no
//  server, under 1 MB/hr". So the socket is open while the app is open, and
//  closed the moment it is not.
//
//  That is also the cheapest possible policy: a backgrounded app costs zero
//  bytes per hour.
//

import UIKit

@UIApplicationMain
public final class AppDelegate: UIResponder, UIApplicationDelegate {

    public var window: UIWindow?

    private let meter = ByteMeter()
    private let popGestureDelegate = PopGestureDelegate()
    private var persistence: Persistence!
    private var store: DMStore!
    private var navigation: UINavigationController!

    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions:
                            [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        persistence = Persistence()
        store = DMStore(persistence: persistence, meter: meter)

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = TermTheme.background

        navigation = UINavigationController()
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.view.backgroundColor = TermTheme.background
        // Hiding the navigation bar also disables the swipe-back gesture, so
        // it has to be re-enabled by hand. ConversationVC also draws a
        // tappable "< dms" row, because a gesture alone is not discoverable.
        navigation.interactivePopGestureRecognizer?.delegate = popGestureDelegate
        navigation.interactivePopGestureRecognizer?.isEnabled = true

        if store.isSignedIn {
            navigation.viewControllers = [ChannelListVC(store: store, meter: meter)]
            store.connect()
        } else {
            let login = LoginVC(store: store)
            login.onSignedIn = { [weak self] in self?.showList() }
            navigation.viewControllers = [login]
        }

        popGestureDelegate.navigation = navigation
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    /// Lets the swipe-back gesture fire only when there is something to go
    /// back to. Without a delegate, a hidden navigation bar leaves the
    /// recogniser disabled; with one that always returns true, a swipe on the
    /// root screen can wedge the navigation stack.
    private final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
        weak var navigation: UINavigationController?

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let navigation = navigation else { return false }
            return navigation.viewControllers.count > 1
        }
    }

    private func showList() {
        navigation.setViewControllers([ChannelListVC(store: store, meter: meter)],
                                      animated: false)
    }

    // MARK: - Lifecycle

    public func applicationDidEnterBackground(_ application: UIApplication) {
        // Close the socket but keep the session. A backgrounded smolcord uses
        // nothing, and the kept session means coming back costs a RESUME
        // rather than a fresh IDENTIFY and the whole of READY.
        store.pause()
        store.flush()
    }

    public func applicationWillEnterForeground(_ application: UIApplication) {
        guard store.isSignedIn else { return }
        // Reconnect. The kept session id lets this RESUME rather than IDENTIFY,
        // which skips the whole of READY. Discord holds a session open for only
        // a few minutes, so a long absence falls back to IDENTIFY on op 9.
        store.connect()
    }

    public func applicationWillTerminate(_ application: UIApplication) {
        store.flush()
    }
}
